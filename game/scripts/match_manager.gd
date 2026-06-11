class_name MatchManager
extends Node
## Server-side rules engine and AI services. Owns the ball and all 22 players,
## runs the match phase machine (kickoff → play → restarts → halves), tracks
## possession, detects goals/out-of-play, and offers spatial query helpers to
## the AI brains. Never exists on clients.

signal sfx_kick(strength: float)
signal sfx_bounce(strength: float)
signal sfx_whistle(kind: int)
signal goal_scored(team: int, scorer_name: String)
signal restart_set(kind: int, team: int)

var ball: Ball
var players: Array[Player] = []

var phase: int = C.Phase.KICKOFF
var phase_t := 0.0
var half := 1
var clock := 0.0
var score := [0, 0]
var possession_idx := -1
var possession_team := -1
var last_scoring_team := -1
var first_kickoff_team := 0
var kicking_off_team := 0

var restart_kind: int = C.Restart.NONE
var restart_taker := -1
var restart_team := -1
var restart_spot := Vector3.ZERO

var stats := { "kicks": 0, "shots": 0, "passes": 0, "saves": 0, "goals": 0,
	"throw_ins": 0, "corners": 0, "goal_kicks": 0 }

var _poss_sticky := 0.0
var _chasers: Array[int] = []
var _chaser_t := 0.0
var _bounce_sfx_cd := 0.0


func setup(parent: Node3D) -> void:
	WorldBuilder.build_collision_world(parent)
	ball = Ball.create()
	parent.add_child(ball)
	ball.kicked.connect(func(s: float) -> void:
		stats["kicks"] += 1
		_on_ball_kicked()
		sfx_kick.emit(s))
	ball.bounced.connect(func(s: float) -> void:
		if _bounce_sfx_cd <= 0.0:
			_bounce_sfx_cd = 0.2
			sfx_bounce.emit(s))
	for team in 2:
		for i in C.FORMATION.size():
			var p := Player.create(team * 11 + i, team, C.FORMATION[i], self)
			if p.is_keeper:
				p.brain = KeeperAi.new(p, self)
			else:
				p.brain = AiBrain.new(p, self)
			players.append(p)
			parent.add_child(p)
	first_kickoff_team = randi() % 2
	setup_kickoff(first_kickoff_team)


func attack_dir(team: int) -> float:
	var d := 1.0 if team == 0 else -1.0
	return d if half == 1 else -d


func _physics_process(delta: float) -> void:
	phase_t += delta
	_bounce_sfx_cd = maxf(0.0, _bounce_sfx_cd - delta)
	_update_possession(delta)
	match phase:
		C.Phase.KICKOFF:
			if phase_t >= C.KICKOFF_COUNTDOWN:
				_set_phase(C.Phase.PLAY)
				ball.unfreeze_rules()
				sfx_whistle.emit(0)
		C.Phase.PLAY:
			clock += delta
			_chaser_t -= delta
			if _chaser_t <= 0.0:
				_chaser_t = 0.25
				_designate_chasers()
			_check_ball_out()
			_check_half_end()
		C.Phase.RESTART:
			if phase_t > C.RESTART_AUTO_TIMEOUT:
				_force_restart_take()
		C.Phase.GOAL_CELEBRATION:
			if phase_t >= C.GOAL_CELEBRATION_TIME:
				setup_kickoff(1 - last_scoring_team)
		C.Phase.HALF_TIME:
			if phase_t >= C.HALF_TIME_PAUSE:
				half = 2
				clock = 0.0
				setup_kickoff(1 - first_kickoff_team)
				MatchState.server_message("SECOND HALF", 2.5)
		C.Phase.FULL_TIME:
			if phase_t >= C.FULL_TIME_PAUSE:
				score = [0, 0]
				half = 1
				clock = 0.0
				MatchState.server_set_score(0, 0)
				MatchState.server_message("NEW MATCH", 2.5)
				first_kickoff_team = randi() % 2
				setup_kickoff(first_kickoff_team)


# ---------------------------------------------------------------- phases

func setup_kickoff(kicking_team: int) -> void:
	kicking_off_team = kicking_team
	restart_kind = C.Restart.NONE
	restart_taker = -1
	ball.place(Vector3(0.0, C.BALL_RADIUS + 0.005, 0.0), true)
	for p in players:
		var d := attack_dir(p.team)
		var e: Dictionary = C.FORMATION[p.idx % 11]
		var x: float = e["x"]
		var z: float = e["z"]
		if p.team == kicking_team and e["num"] == 9:
			p.teleport(Vector3(-d * 1.1, 0.0, 0.35), Vector3(d, 0, 0))
			continue
		if p.team == kicking_team and e["num"] == 10:
			x = -4.0
			z = 5.0
		else:
			x = minf(x, -3.0)
			# Non-kicking team stays outside the center circle.
			if p.team != kicking_team and absf(x) < C.CENTER_CIRCLE_R + 1.0 \
					and absf(z) < C.CENTER_CIRCLE_R + 1.0:
				x = -(C.CENTER_CIRCLE_R + 2.0)
		p.teleport(Vector3(x * d, 0.0, z), Vector3(d, 0, 0))
	_set_phase(C.Phase.KICKOFF)


func _set_phase(p_phase: int) -> void:
	phase = p_phase
	phase_t = 0.0
	MatchState.server_set_phase(p_phase, half)


func _check_half_end() -> void:
	if clock < C.HALF_LENGTH_SECONDS:
		return
	if half == 1:
		_set_phase(C.Phase.HALF_TIME)
		sfx_whistle.emit(1)
		MatchState.server_message("HALF TIME", 3.0)
	else:
		_set_phase(C.Phase.FULL_TIME)
		sfx_whistle.emit(2)
		MatchState.server_message("FULL TIME  %d - %d" % [score[0], score[1]], 5.0)


## Any human may request a fresh match (score reset + kickoff).
func request_reset(by_name: String) -> void:
	score = [0, 0]
	half = 1
	clock = 0.0
	MatchState.server_set_score(0, 0)
	MatchState.server_message("MATCH RESTARTED (%s)" % by_name, 2.5)
	first_kickoff_team = randi() % 2
	setup_kickoff(first_kickoff_team)


# ---------------------------------------------------------------- ball out

func _check_ball_out() -> void:
	if ball.rules_frozen or ball.holder != null:
		return
	var bp := ball.global_position
	var r := C.BALL_RADIUS
	# Goal or behind the goal line?
	if absf(bp.x) > C.HALF_LEN + r:
		var side := signf(bp.x)
		var attacker := 0 if attack_dir(0) == side else 1
		if absf(bp.z) < C.GOAL_WIDTH * 0.5 and bp.y < C.GOAL_HEIGHT + 0.1:
			_goal(attacker)
			return
		var defender := 1 - attacker
		if ball.last_touch_team == defender:
			stats["corners"] += 1
			var spot := Vector3(side * (C.HALF_LEN - 0.2), r,
				signf(bp.z if absf(bp.z) > 0.1 else 1.0) * (C.HALF_WID - 0.2))
			_set_restart(C.Restart.CORNER, attacker, spot)
		else:
			stats["goal_kicks"] += 1
			var spot_gk := Vector3(side * (C.HALF_LEN - C.SIX_BOX_DEPTH), r, 0.0)
			_set_restart(C.Restart.GOAL_KICK, defender, spot_gk)
		return
	# Touchline?
	if absf(bp.z) > C.HALF_WID + r:
		var to_team := 1 - ball.last_touch_team if ball.last_touch_team >= 0 else 0
		stats["throw_ins"] += 1
		var spot_t := Vector3(clampf(bp.x, -C.HALF_LEN + 1.0, C.HALF_LEN - 1.0),
			r, signf(bp.z) * (C.HALF_WID - 0.15))
		_set_restart(C.Restart.THROW_IN, to_team, spot_t)


func _goal(team: int) -> void:
	score[team] += 1
	stats["goals"] += 1
	last_scoring_team = team
	var scorer := ""
	if ball.last_toucher >= 0 and players[ball.last_toucher].team == team:
		scorer = players[ball.last_toucher].pname
	_set_phase(C.Phase.GOAL_CELEBRATION)
	ball.place(ball.global_position, false)   # leave it in the net, unfrozen
	MatchState.server_set_score(score[0], score[1])
	var txt := "GOAL!  %s" % scorer if scorer != "" else "GOAL!"
	MatchState.server_message(txt, 3.5)
	sfx_whistle.emit(0)
	goal_scored.emit(team, scorer)


func _set_restart(kind: int, team: int, spot: Vector3) -> void:
	restart_kind = kind
	restart_team = team
	restart_spot = spot
	ball.place(spot, true)
	restart_taker = _pick_taker(kind, team, spot)
	_set_phase(C.Phase.RESTART)
	restart_set.emit(kind, team)
	var kind_txt: String = ["", "THROW-IN", "CORNER", "GOAL KICK"][kind]
	MatchState.server_message("%s — %s" % [kind_txt, C.TEAM_NAMES[team]], 2.0)
	# Hand control of the taker to a human on that team (corners/throw-ins).
	if kind != C.Restart.GOAL_KICK:
		Net.maybe_control_taker(team, restart_taker)


func _pick_taker(kind: int, team: int, spot: Vector3) -> int:
	if kind == C.Restart.GOAL_KICK:
		return team * 11   # keeper
	var best := -1
	var best_d := INF
	for p in players:
		if p.team != team or p.is_keeper:
			continue
		var d := p.global_position.distance_to(spot)
		if d < best_d:
			best_d = d
			best = p.idx
	return best


func restart_elapsed() -> float:
	return phase_t if phase == C.Phase.RESTART else 0.0


func _force_restart_take() -> void:
	if restart_taker < 0:
		_set_phase(C.Phase.PLAY)
		return
	var taker := players[restart_taker]
	taker.teleport(restart_spot + Vector3(-attack_dir(taker.team) * 0.8, 0, 0.3),
		Vector3(attack_dir(taker.team), 0, 0))
	var dir := attack_dir(taker.team)
	taker.queue_action(C.Action.LOB if restart_kind != C.Restart.THROW_IN
		else C.Action.PASS, 0.7, Vector2(dir, 0.0))


func can_touch_ball(p: Player) -> bool:
	match phase:
		C.Phase.PLAY:
			return true
		C.Phase.RESTART:
			return p.idx == restart_taker and phase_t > 0.8
		_:
			return false


# ---------------------------------------------------------------- possession

func _update_possession(delta: float) -> void:
	if ball.holder != null and ball.holder is Player:
		possession_idx = (ball.holder as Player).idx
		possession_team = (ball.holder as Player).team
		return
	var best := -1
	var best_d := C.CONTROL_RADIUS * 1.15
	var bp := ball.global_position
	for p in players:
		var d := Vector2(p.global_position.x - bp.x, p.global_position.z - bp.z).length()
		if d < best_d:
			best_d = d
			best = p.idx
	if best >= 0:
		possession_idx = best
		possession_team = players[best].team
		_poss_sticky = 0.35
	else:
		_poss_sticky -= delta
		if _poss_sticky <= 0.0:
			possession_idx = -1
			possession_team = -1


func _designate_chasers() -> void:
	_chasers.clear()
	if possession_team >= 0 and ball.linear_velocity.length() < 4.0:
		# Carrier's opponents press with their nearest player.
		var presser := _nearest_ai_of_team(1 - possession_team)
		if presser >= 0:
			_chasers.append(presser)
		return
	for team in 2:
		var c := _nearest_ai_of_team(team)
		if c >= 0:
			_chasers.append(c)
			var c2 := _nearest_ai_of_team_excluding(team, c)
			if c2 >= 0:
				_chasers.append(c2)


func _nearest_ai_of_team(team: int) -> int:
	var bp := ball.global_position
	var best := -1
	var best_d := INF
	for p in players:
		if p.team != team or p.is_keeper or p.is_human():
			continue
		var d := p.global_position.distance_to(bp)
		if d < best_d:
			best_d = d
			best = p.idx
	return best


func _nearest_ai_of_team_excluding(team: int, exclude: int) -> int:
	var bp := ball.global_position
	var best := -1
	var best_d := INF
	for p in players:
		if p.team != team or p.is_keeper or p.is_human() or p.idx == exclude:
			continue
		var d := p.global_position.distance_to(bp)
		if d < best_d:
			best_d = d
			best = p.idx
	return best


func is_designated_chaser(p: Player) -> bool:
	return _chasers.has(p.idx)


# ---------------------------------------------------------------- AI helpers

func pick_pass_target(passer: Player, dir3: Vector3) -> Player:
	var best: Player = null
	var best_score := 0.3
	var from := passer.global_position
	var d2 := Vector2(dir3.x, dir3.z).normalized()
	var adir := attack_dir(passer.team)
	for mate in players:
		if mate.team != passer.team or mate == passer:
			continue
		var to_m := Vector2(mate.global_position.x - from.x,
			mate.global_position.z - from.z)
		var dist := to_m.length()
		if dist < 4.0 or dist > 42.0:
			continue
		var align := d2.dot(to_m.normalized())
		if align < -0.1:
			continue
		var openness := _lane_clearance(from, mate.global_position, passer.team)
		var progress := (mate.global_position.x - from.x) * adir
		var s := align * 2.0 + clampf(openness, 0.0, 6.0) * 0.28 \
			+ progress * 0.13 - dist * 0.015
		if mate.is_keeper:
			s -= 1.5
		if s > best_score:
			best_score = s
			best = mate
	return best


## Smallest opponent distance to the pass lane.
func _lane_clearance(from: Vector3, to: Vector3, team: int) -> float:
	var a := Vector2(from.x, from.z)
	var b := Vector2(to.x, to.z)
	var ab := b - a
	var len2 := ab.length_squared()
	var clearance := INF
	for opp in players:
		if opp.team == team:
			continue
		var o := Vector2(opp.global_position.x, opp.global_position.z)
		var t := clampf((o - a).dot(ab) / maxf(len2, 0.01), 0.0, 1.0)
		clearance = minf(clearance, o.distance_to(a + ab * t))
	return clearance


func pick_open_teammate(p: Player) -> Player:
	var best: Player = null
	var best_s := -INF
	for mate in players:
		if mate.team != p.team or mate == p or mate.is_keeper:
			continue
		var d := p.global_position.distance_to(mate.global_position)
		if d > 30.0:
			continue
		var open := nearest_opponent_dist(mate)
		var s := open - d * 0.15 + (3.0 if mate.role == C.Role.DEF else 0.0)
		if s > best_s:
			best_s = s
			best = mate
	return best


func nearest_opponent(p: Player) -> Player:
	var best: Player = null
	var best_d := INF
	for opp in players:
		if opp.team == p.team:
			continue
		var d := p.global_position.distance_to(opp.global_position)
		if d < best_d:
			best_d = d
			best = opp
	return best


func nearest_opponent_dist(p: Player) -> float:
	var opp := nearest_opponent(p)
	return p.global_position.distance_to(opp.global_position) if opp else INF


func nearest_opponent_dist_to_ball(my_team: int) -> float:
	var bp := ball.global_position
	var best := INF
	for p in players:
		if p.team == my_team:
			continue
		best = minf(best, p.global_position.distance_to(bp))
	return best


func count_opponents_in_cone(p: Player, dir3: Vector3, max_range: float,
		half_angle_deg: float) -> int:
	var n := 0
	var d2 := Vector2(dir3.x, dir3.z).normalized()
	var cos_a := cos(deg_to_rad(half_angle_deg))
	for opp in players:
		if opp.team == p.team or opp.is_keeper:
			continue
		var to_o := Vector2(opp.global_position.x - p.global_position.x,
			opp.global_position.z - p.global_position.z)
		var dist := to_o.length()
		if dist > max_range or dist < 0.5:
			continue
		if d2.dot(to_o / dist) > cos_a:
			n += 1
	return n


func keeper_far_corner(shooter_team: int) -> float:
	var keeper := players[(1 - shooter_team) * 11]
	var kz := keeper.global_position.z
	if absf(kz) < 0.3:
		return (1.0 if randf() < 0.5 else -1.0) * 2.9
	return -signf(kz) * 2.9


# ---------------------------------------------------------------- notifies

func _on_ball_kicked() -> void:
	if phase == C.Phase.RESTART:
		_set_phase(C.Phase.PLAY)


func note_intent(kind: int, what: String) -> void:
	note_key("%s_%d" % [what, kind])


func note_key(key: String) -> void:
	stats[key] = int(stats.get(key, 0)) + 1


func notify_kick(_p: Player) -> void:
	pass


func notify_pass(passer: Player, receiver: Player) -> void:
	stats["passes"] += 1
	if receiver != null:
		note_key("recv_role%d" % receiver.role)
	if passer.is_human() and receiver != null and not receiver.is_human() \
			and not receiver.is_keeper:
		Net.assign_control(passer.control_peer, receiver.idx)


func notify_shot(_p: Player, _power: float) -> void:
	stats["shots"] += 1


func notify_slide(_p: Player) -> void:
	pass


func notify_save(_p: Player) -> void:
	stats["saves"] += 1


func notify_keeper_catch(_p: Player) -> void:
	stats["saves"] += 1

class_name AiBrain
extends RefCounted
## Outfield player AI (server only). Cheap reactive brain: formation-anchored
## positioning warped by ball location, designated-chaser pressing, and a
## with-ball attacking layer (dribble / pass / cross / shoot).

var p: Player
var mgr: Node

var _decide_t := 0.0
var _target := Vector2.ZERO
var _sprint := false
var _wiggle := 0.0
var _hold_urge := 0.0      # accumulates while carrying; raises pass likelihood
var _rng_bias: float       # per-player personality (-1..1)


func _init(player: Player, manager: Node) -> void:
	p = player
	mgr = manager
	_rng_bias = fmod(float(player.idx) * 0.6180339887, 1.0) * 2.0 - 1.0


func tick(delta: float) -> void:
	_decide_t -= delta
	if _decide_t <= 0.0:
		_decide_t = randf_range(0.12, 0.22)
		_decide()
	var my2 := Vector2(p.global_position.x, p.global_position.z)
	var to_t := _target - my2
	if to_t.length() < 0.6:
		p.ai_move = Vector2.ZERO
	else:
		p.ai_move = to_t.normalized()
	p.ai_sprint = _sprint


func _decide() -> void:
	var ball: Ball = mgr.ball
	var my2 := Vector2(p.global_position.x, p.global_position.z)
	var ball2 := Vector2(ball.global_position.x, ball.global_position.z)
	var dir: float = p.attack_dir()

	if mgr.phase == C.Phase.RESTART:
		if mgr.restart_taker == p.idx:
			_behave_restart_taker(ball2)
		else:
			_target = _position_target(ball2, dir)
			# Keep the mandated distance from the spot.
			if _target.distance_to(ball2) < 4.0:
				_target = ball2 + (_target - ball2).normalized() * 4.0
			_sprint = false
		return

	if mgr.phase != C.Phase.PLAY:
		p.ai_move = Vector2.ZERO
		_target = my2
		_sprint = false
		return

	if p.has_ball():
		_behave_with_ball(my2, ball2, dir)
		return
	_hold_urge = 0.0

	if mgr.is_designated_chaser(p):
		_target = _intercept_point(my2, ball)
		_sprint = true
		return

	_target = _position_target(ball2, dir)
	var dist := my2.distance_to(_target)
	_sprint = dist > 7.0


# Where do I stand? Formation anchor warped toward the ball + attacking push.
func _position_target(ball2: Vector2, dir: float) -> Vector2:
	var pull_x := 0.45
	var pull_z := 0.22
	var push := 6.0
	match p.role:
		C.Role.DEF:
			pull_x = 0.42; pull_z = 0.18; push = 6.0
		C.Role.MID:
			pull_x = 0.55; pull_z = 0.34; push = 13.0
		C.Role.FWD:
			pull_x = 0.48; pull_z = 0.30; push = 19.0
	var x := p.anchor.x * dir + ball2.x * pull_x
	var z := p.anchor.y + ball2.y * pull_z
	if mgr.possession_team == p.team:
		x += dir * push
		if p.role == C.Role.FWD:
			# Pin strikers high, on the shoulder of the last defender.
			x = dir * maxf(x * dir, 19.0)
	x = clampf(x, -C.HALF_LEN + 2.0, C.HALF_LEN - 2.0)
	z = clampf(z, -C.HALF_WID + 1.5, C.HALF_WID - 1.5)
	return Vector2(x, z)


func _intercept_point(my2: Vector2, ball: Ball) -> Vector2:
	var b2 := Vector2(ball.global_position.x, ball.global_position.z)
	var bv2 := Vector2(ball.linear_velocity.x, ball.linear_velocity.z)
	var t := my2.distance_to(b2) / C.SPRINT_SPEED
	t = minf(t, 1.2)
	var pred := b2 + bv2 * t * 0.8
	# Refine once.
	t = minf(my2.distance_to(pred) / C.SPRINT_SPEED, 1.2)
	pred = b2 + bv2 * t * 0.8
	pred.x = clampf(pred.x, -C.HALF_LEN, C.HALF_LEN)
	pred.y = clampf(pred.y, -C.HALF_WID, C.HALF_WID)
	return pred


func _behave_with_ball(my2: Vector2, ball2: Vector2, dir: float) -> void:
	mgr.note_key("wb_role%d" % p.role)
	mgr.note_key("wbx_%d" % int(floor(my2.x * dir / 10.0) * 10.0))
	var in_attack_third := my2.x * dir > C.HALF_LEN - 35.0
	_hold_urge += 0.16 * (0.55 if in_attack_third else 1.0)
	var goal2 := Vector2(dir * C.HALF_LEN, 0.0)
	var dist_goal := my2.distance_to(goal2)
	var pressed_dist: float = mgr.nearest_opponent_dist(p)
	var to_goal3 := Vector3(goal2.x - my2.x, 0.0, -my2.y).normalized()

	# 1) Shoot when it's on (close + clear-ish; occasional long strike).
	if dist_goal < 28.0 and absf(my2.y) < 19.0:
		var blockers: int = mgr.count_opponents_in_cone(p, to_goal3, dist_goal * 0.8, 8.0)
		var eager := dist_goal < 22.0 or blockers <= 1
		var prob := 0.9 if dist_goal < 22.0 else 0.5
		if eager and randf() < prob:
			var power := clampf(0.55 + dist_goal / 45.0 + _rng_bias * 0.08, 0.5, 1.0)
			p.queue_action(C.Action.SHOOT, power, Vector2(to_goal3.x, to_goal3.z))
			_hold_urge = 0.0
			return

	# 2) Cross from the wing once past midfield-ish.
	if absf(my2.y) > 17.0 and my2.x * dir > 22.0:
		var box := Vector2(dir * (C.HALF_LEN - C.PENALTY_SPOT), -signf(my2.y) * 4.0)
		var aim := (box - my2).normalized()
		p.queue_action(C.Action.LOB, 0.8, aim)
		_hold_urge = 0.0
		return

	# 3) Pass when pressed or when we've held it long enough.
	# In the attacking third, drive at goal instead of recycling.
	var want_pass: bool
	if in_attack_third:
		want_pass = pressed_dist < 2.0 or _hold_urge > randf_range(2.6, 4.4)
	else:
		want_pass = pressed_dist < 3.0 or _hold_urge > randf_range(1.6, 3.2)
	if want_pass:
		var fwd := Vector3(dir, 0.0, signf(_rng_bias) * 0.4).normalized()
		var mate: Player = mgr.pick_pass_target(p, fwd)
		if mate == null:
			mate = mgr.pick_pass_target(p, -Vector3(dir, 0.0, 0.0))   # recycle backwards
		if mate != null:
			var aim2 := Vector2(mate.global_position.x - my2.x,
				mate.global_position.z - my2.y).normalized()
			var lane_blocked: bool = mgr.count_opponents_in_cone(p,
				Vector3(aim2.x, 0.0, aim2.y),
				my2.distance_to(Vector2(mate.global_position.x, mate.global_position.z)),
				7.0) > 0
			var far := my2.distance_to(
				Vector2(mate.global_position.x, mate.global_position.z)) > 26.0
			p.queue_action(C.Action.LOB if (lane_blocked or far) else C.Action.PASS,
				0.6, aim2)
			_hold_urge = 0.0
			return

	# 4) Dribble toward goal, veering away from the nearest opponent.
	_wiggle = lerpf(_wiggle, randf_range(-1.0, 1.0), 0.3)
	var run_dir := (goal2 - my2).normalized()
	var opp: Player = mgr.nearest_opponent(p)
	if opp != null:
		var to_opp := Vector2(opp.global_position.x, opp.global_position.z) - my2
		if to_opp.length() < 4.0:
			var side := Vector2(-run_dir.y, run_dir.x)
			run_dir = (run_dir + side * (1.2 * signf(side.dot(-to_opp)) + _wiggle * 0.3)).normalized()
	_target = my2 + run_dir * 8.0
	_target.x = clampf(_target.x, -C.HALF_LEN + 1.0, C.HALF_LEN - 1.0)
	_target.y = clampf(_target.y, -C.HALF_WID + 1.0, C.HALF_WID - 1.0)
	_sprint = pressed_dist > 4.0


func _behave_restart_taker(ball2: Vector2) -> void:
	_target = ball2
	_sprint = true
	var my2 := Vector2(p.global_position.x, p.global_position.z)
	if my2.distance_to(ball2) < 1.6 and mgr.restart_elapsed() > 1.6:
		var dir: float = p.attack_dir()
		match mgr.restart_kind:
			C.Restart.THROW_IN:
				var infield := Vector2(dir * 0.4, -signf(ball2.y)).normalized()
				p.queue_action(C.Action.PASS, 0.5, infield)
			C.Restart.CORNER:
				var box := Vector2(dir * (C.HALF_LEN - C.PENALTY_SPOT), 0.0)
				p.queue_action(C.Action.LOB, 0.85, (box - my2).normalized())
			C.Restart.GOAL_KICK:
				p.queue_action(C.Action.LOB, 1.0, Vector2(dir, randf_range(-0.4, 0.4)).normalized())
			_:
				p.queue_action(C.Action.PASS, 0.5, Vector2(dir, 0.0))

class_name Player
extends CharacterBody3D
## Server-side player body. Humans drive it with replicated input; everyone
## else is driven by an AI brain. Handles locomotion, dribble touches, kicks
## (pass/lob/shot with ballistic lead targeting + Magnus curve), slide tackles
## and keeper dives. Never instanced on clients.

var idx: int = -1
var team: int = 0
var role: int = C.Role.MID
var number: int = 0
var pname: String = ""
var is_keeper: bool = false
var anchor: Vector2 = Vector2.ZERO       # formation anchor for a +x attacking basis
var mgr: Node = null                     # MatchManager
var brain: RefCounted = null             # AiBrain / KeeperAi (server AI)

# Replicated human input (world-space move vector).
var control_peer: int = 0                # 0 = AI controlled
var input_move := Vector2.ZERO
var input_buttons := 0

# AI-desired motion (set by brain each tick).
var ai_move := Vector2.ZERO
var ai_sprint := false

var heading_dir := Vector3(1, 0, 0)
var anim: int = C.Anim.IDLE
var anim_t := 0.0

var _intent: Dictionary = {}             # {kind, power, aim, expires}
var _kick_anim_t := 0.0
var _kick_cd := 0.0
var _touch_cd := 0.0
var _slide_t := 0.0
var _slide_dir := Vector3.ZERO
var _slide_hit := false
var _slide_cd := 0.0
var _recover_t := 0.0
var _dive_t := 0.0
var _dive_dir := Vector3.ZERO


static func create(p_idx: int, p_team: int, entry: Dictionary, p_mgr: Node) -> Player:
	var p := Player.new()
	p.idx = p_idx
	p.team = p_team
	p.role = entry["role"]
	p.number = entry["num"]
	p.pname = C.SQUAD_NAMES[p_team][(entry["num"] - 1) % 11]
	p.is_keeper = entry["role"] == C.Role.GK
	p.anchor = Vector2(entry["x"], entry["z"])
	p.mgr = p_mgr
	p.name = "P%d" % p_idx
	p.collision_layer = 2
	p.collision_mask = 1 | 2 | 8 | 16    # ground, players, goals, walls — NOT ball
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = C.PLAYER_RADIUS
	capsule.height = C.PLAYER_HEIGHT
	shape.shape = capsule
	shape.position.y = C.PLAYER_HEIGHT * 0.5
	p.add_child(shape)
	return p


func is_human() -> bool:
	return control_peer != 0


func heading() -> Vector3:
	return heading_dir


func yaw() -> float:
	return atan2(heading_dir.x, heading_dir.z)


func has_ball() -> bool:
	return mgr.possession_idx == idx


func attack_dir() -> float:
	return mgr.attack_dir(team)


## Discrete action from a human (reliable RPC) or from the AI brain.
func queue_action(kind: int, power: float, aim: Vector2) -> void:
	if kind == C.Action.TACKLE:
		if mgr.phase == C.Phase.PLAY or mgr.phase == C.Phase.RESTART:
			_try_slide()
		return
	mgr.note_intent(kind, "q")
	_intent = { "kind": kind, "power": clampf(power, 0.0, 1.0),
		"aim": aim, "expires": 0.5 }


func start_dive(dir: Vector3) -> void:
	if _dive_t <= 0.0:
		_dive_t = 0.75
		_dive_dir = Vector3(dir.x, 0.0, dir.z).normalized()


func teleport(pos: Vector3, face_dir: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	if face_dir.length() > 0.01:
		heading_dir = face_dir.normalized()
	_slide_t = 0.0
	_recover_t = 0.0
	_dive_t = 0.0
	_intent = {}


func _physics_process(delta: float) -> void:
	_kick_cd = maxf(0.0, _kick_cd - delta)
	_touch_cd = maxf(0.0, _touch_cd - delta)
	_slide_cd = maxf(0.0, _slide_cd - delta)
	_kick_anim_t = maxf(0.0, _kick_anim_t - delta)
	if not _intent.is_empty():
		_intent["expires"] -= delta
		if _intent["expires"] <= 0.0:
			mgr.note_intent(_intent["kind"], "exp")
			_intent = {}

	var phase: int = mgr.phase
	var sim_active: bool = phase == C.Phase.PLAY or phase == C.Phase.RESTART
	var desired := Vector2.ZERO
	var sprint := false

	if sim_active:
		if is_human():
			desired = input_move.limit_length(1.0)
			sprint = (input_buttons & C.BTN_SPRINT) != 0
		else:
			brain.tick(delta)
			desired = ai_move.limit_length(1.0)
			sprint = ai_sprint

	# --- Slide tackle state ---
	if _slide_t > 0.0:
		_slide_t -= delta
		velocity.x = _slide_dir.x * C.SLIDE_SPEED * maxf(0.3, _slide_t / C.SLIDE_DURATION)
		velocity.z = _slide_dir.z * C.SLIDE_SPEED * maxf(0.3, _slide_t / C.SLIDE_DURATION)
		_apply_gravity(delta)
		move_and_slide()
		_slide_poke()
		anim = C.Anim.SLIDE
		anim_t = 1.0 - maxf(_slide_t, 0.0) / C.SLIDE_DURATION
		if _slide_t <= 0.0:
			_recover_t = 0.55
		return

	# --- Keeper dive state ---
	if _dive_t > 0.0:
		_dive_t -= delta
		velocity.x = _dive_dir.x * 7.0
		velocity.z = _dive_dir.z * 7.0
		_apply_gravity(delta)
		move_and_slide()
		anim = C.Anim.DIVE
		anim_t = clampf((0.75 - _dive_t) / 0.75, 0.0, 1.0)
		if _dive_t <= 0.0:
			_recover_t = 0.5
		_try_execute_intent()
		return

	# --- Recovery (getting up) ---
	if _recover_t > 0.0:
		_recover_t -= delta
		desired = Vector2.ZERO
		sprint = false

	# --- Locomotion ---
	var max_speed := C.SPRINT_SPEED if sprint else C.JOG_SPEED
	if has_ball():
		max_speed *= C.CARRY_SPEED_FACTOR
	if is_human() and (input_buttons & C.BTN_CHARGE) != 0:
		max_speed = minf(max_speed, 3.2)   # winding up a shot slows you
	var target := Vector3(desired.x, 0.0, desired.y) * max_speed
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	var rate := C.ACCEL if target.length() > hv.length() else C.DECEL
	hv = hv.move_toward(target, rate * delta)
	velocity.x = hv.x
	velocity.z = hv.z
	_apply_gravity(delta)
	move_and_slide()

	# --- Facing ---
	var speed2d := Vector2(velocity.x, velocity.z).length()
	if speed2d > 0.6:
		var want := Vector3(velocity.x, 0.0, velocity.z).normalized()
		heading_dir = _slew(heading_dir, want, C.TURN_RATE * delta)
	elif mgr.ball != null:
		var to_ball: Vector3 = mgr.ball.global_position - global_position
		to_ball.y = 0.0
		if to_ball.length() < 8.0 and to_ball.length() > 0.2:
			heading_dir = _slew(heading_dir, to_ball.normalized(), 4.0 * delta)

	# --- Ball interactions ---
	if sim_active:
		_try_execute_intent()
		_try_control_touch()

	# --- Animation state ---
	if _kick_anim_t > 0.0:
		anim = C.Anim.KICK
		anim_t = clampf((0.35 - _kick_anim_t) / 0.35, 0.0, 1.0)
	elif phase == C.Phase.GOAL_CELEBRATION and team == mgr.last_scoring_team:
		anim = C.Anim.CELEBRATE
		anim_t += delta
	elif speed2d > 0.5:
		anim = C.Anim.RUN
		anim_t += delta
	else:
		anim = C.Anim.IDLE
		anim_t += delta


func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y -= 9.81 * delta


func _slew(from: Vector3, to: Vector3, max_step: float) -> Vector3:
	var a := atan2(from.x, from.z)
	var b := atan2(to.x, to.z)
	var na := a + clampf(angle_difference(a, b), -max_step, max_step)
	return Vector3(sin(na), 0.0, cos(na))


# ---------------------------------------------------------------- kicks

func _ball_reachable() -> bool:
	var ball: Ball = mgr.ball
	if ball == null:
		return false
	if ball.holder != null and ball.holder != self:
		return false
	var d := ball.global_position - global_position
	return Vector2(d.x, d.z).length() <= C.KICK_RANGE and d.y < 1.4


func _try_execute_intent() -> void:
	if _intent.is_empty() or _kick_cd > 0.0:
		return
	if not mgr.can_touch_ball(self):
		return
	if not _ball_reachable():
		return
	var kind: int = _intent["kind"]
	var power: float = _intent["power"]
	var aim: Vector2 = _intent["aim"]
	mgr.note_intent(kind, "x")
	_intent = {}
	match kind:
		C.Action.PASS:
			_do_pass(aim, false)
		C.Action.LOB:
			_do_pass(aim, true)
		C.Action.SHOOT:
			_do_shoot(power, aim)
	_kick_cd = 0.3
	_kick_anim_t = 0.35
	mgr.notify_kick(self)


func _aim_or_facing(aim: Vector2) -> Vector3:
	if aim.length() > 0.1:
		return Vector3(aim.x, 0.0, aim.y).normalized()
	return heading_dir


func _do_pass(aim: Vector2, lofted: bool) -> void:
	var ball: Ball = mgr.ball
	var dir := _aim_or_facing(aim)
	var receiver: Player = mgr.pick_pass_target(self, dir)
	var noise := 0.03 if is_human() else 0.045
	if receiver == null:
		# No good option — punt it in the aimed direction.
		var v := dir * (C.LOB_SPEED_MAX if lofted else C.PASS_SPEED_MAX) * 0.8
		if lofted:
			v.y = v.length() * 0.55
		ball.kick(_with_noise(v, noise), Vector3.ZERO, idx, team)
		return
	# Lead the receiver.
	var target := receiver.global_position
	var dist := (target - ball.global_position).length()
	var flight := dist / lerpf(C.PASS_SPEED_MIN, C.PASS_SPEED_MAX, clampf(dist / 35.0, 0.0, 1.0))
	target += Vector3(receiver.velocity.x, 0.0, receiver.velocity.z) * flight * 0.8
	var to_t := target - ball.global_position
	to_t.y = 0.0
	dist = to_t.length()
	var vel: Vector3
	if lofted:
		var speed := clampf(sqrt(maxf(dist, 4.0) * 9.81 / sin(2.0 * deg_to_rad(36.0))),
			C.LOB_SPEED_MIN, C.LOB_SPEED_MAX)
		var horiz := speed * cos(deg_to_rad(36.0))
		vel = to_t.normalized() * horiz
		vel.y = speed * sin(deg_to_rad(36.0))
		# Backspin keeps a lofted ball hanging and sitting down on landing.
		var side := to_t.normalized().cross(Vector3.UP)
		ball.kick(_with_noise(vel, noise), side * 18.0, idx, team)
	else:
		var speed_g := clampf(C.PASS_SPEED_MIN + dist * 0.36, C.PASS_SPEED_MIN, C.PASS_SPEED_MAX)
		vel = to_t.normalized() * speed_g
		vel.y = minf(1.5, dist * 0.04)
		ball.kick(_with_noise(vel, noise), Vector3.ZERO, idx, team)
	mgr.notify_pass(self, receiver)


func _do_shoot(power: float, aim: Vector2) -> void:
	var ball: Ball = mgr.ball
	var dir := attack_dir()
	var goal_x := dir * C.HALF_LEN
	var ball_pos := ball.global_position
	# Corner selection: lateral component of aim relative to the shot line.
	var to_goal := Vector3(goal_x - ball_pos.x, 0.0, -ball_pos.z)
	if to_goal.length() < 1.0:
		to_goal = Vector3(dir, 0.0, 0.0)
	to_goal = to_goal.normalized()
	var aim3 := _aim_or_facing(aim)
	var lateral := aim3.cross(Vector3.UP).dot(to_goal)   # -1..1 left/right of line
	var target_z := clampf(-lateral * 4.0, -3.1, 3.1)
	if not is_human():
		target_z = mgr.keeper_far_corner(team)
	var speed := lerpf(C.SHOT_SPEED_MIN, C.SHOT_SPEED_MAX, power)
	var target_y := lerpf(0.35, 1.85, power * power) + randf() * 0.2
	var target := Vector3(goal_x, target_y, target_z)
	var flat := Vector3(target.x - ball_pos.x, 0.0, target.z - ball_pos.z)
	var dist := flat.length()
	var t := dist / speed
	var vel := flat.normalized() * speed
	vel.y = (target.y - ball_pos.y) / t + 0.5 * 9.81 * t * 0.55   # drag-aware loft
	# Curve: deliberate sidespin from lateral movement at release.
	var move3 := Vector3(input_move.x, 0.0, input_move.y) if is_human() else aim3
	var curve := move3.cross(Vector3.UP).dot(to_goal)
	var spin := Vector3(0.0, -curve * 45.0 * (0.4 + 0.6 * power), 0.0)
	spin += to_goal.cross(Vector3.UP) * -8.0   # mild topspin keeps drives down
	var noise := (0.018 + 0.045 * power) if is_human() else 0.05
	ball.kick(_with_noise(vel, noise), spin, idx, team)
	mgr.notify_shot(self, power)


func _with_noise(v: Vector3, sigma: float) -> Vector3:
	return v.rotated(Vector3.UP, randfn(0.0, sigma)) \
		.rotated(v.cross(Vector3.UP).normalized() if v.cross(Vector3.UP).length() > 0.01
			else Vector3.FORWARD, randfn(0.0, sigma * 0.6))


# ---------------------------------------------------------------- touches

func _try_control_touch() -> void:
	if _touch_cd > 0.0 or _kick_cd > 0.0:
		return
	var ball: Ball = mgr.ball
	if ball == null or ball.holder != null or ball.rules_frozen:
		return
	if not mgr.can_touch_ball(self):
		return
	var d := ball.global_position - global_position
	if d.y > 1.2 or Vector2(d.x, d.z).length() > C.CONTROL_RADIUS:
		return
	var ball_speed := ball.linear_velocity.length()
	var my_speed := Vector3(velocity.x, 0.0, velocity.z).length()
	# A dropping ball can be cushioned (chest/thigh) even when it's fast.
	var dropping := ball.linear_velocity.y < -1.0 and d.y > 0.25
	if ball_speed > (23.0 if dropping else 17.0):
		return   # too hot to control — body deflections handle it
	_touch_cd = 0.33
	if ball_speed > 6.0 or dropping:
		# First touch: kill the pace, set it at our feet.
		var settle := ball.linear_velocity * 0.12 + heading_dir * 0.7
		settle.y = 0.0
		ball.touch(settle, idx, team)
	elif my_speed > 1.5:
		# Dribble: push the ball ahead, slightly faster than we run.
		var push := heading_dir * (my_speed * 1.03 + 1.1)
		push.y = 0.15
		ball.touch(push, idx, team)
	else:
		# Shield / nudge at the feet.
		var settle := ball.linear_velocity * 0.12 + heading_dir * 0.6
		settle.y = 0.0
		ball.touch(settle, idx, team)


func _try_slide() -> void:
	if _slide_cd > 0.0 or _slide_t > 0.0 or _recover_t > 0.0 or is_keeper:
		return
	var dir := Vector3(velocity.x, 0.0, velocity.z)
	_slide_dir = dir.normalized() if dir.length() > 1.0 else heading_dir
	_slide_t = C.SLIDE_DURATION
	_slide_cd = C.SLIDE_COOLDOWN
	_slide_hit = false
	mgr.notify_slide(self)


func _slide_poke() -> void:
	if _slide_hit:
		return
	var ball: Ball = mgr.ball
	if ball == null or ball.holder != null:
		return
	if not mgr.can_touch_ball(self):
		return
	var d := ball.global_position - global_position
	if Vector2(d.x, d.z).length() <= C.SLIDE_REACH and d.y < 0.8:
		_slide_hit = true
		var away := (_slide_dir + d.normalized() * 0.5).normalized()
		ball.kick(away * 8.5 + Vector3(0, 1.6, 0), Vector3.ZERO, idx, team)

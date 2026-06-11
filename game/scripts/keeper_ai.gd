class_name KeeperAi
extends RefCounted
## Goalkeeper AI (server only): angle-narrowing positioning, shot-stopping
## with predictive dives, catches vs parries by shot heat, claiming loose
## balls in the box, and distribution after a hold.

var p: Player
var mgr: Node

var _hold_t := 0.0
var _decide_t := 0.0
var _target := Vector2.ZERO
var _sprint := false


func _init(player: Player, manager: Node) -> void:
	p = player
	mgr = manager


func tick(delta: float) -> void:
	var ball: Ball = mgr.ball
	var dir: float = p.attack_dir()
	var goal_x := -dir * C.HALF_LEN
	var my2 := Vector2(p.global_position.x, p.global_position.z)

	# --- Holding the ball: walk up a touch, then distribute ---
	if ball.holder == p:
		_hold_t += delta
		_target = Vector2(goal_x + dir * 9.0, clampf(my2.y, -8.0, 8.0))
		_steer(my2, false)
		if _hold_t > 2.4:
			_distribute(dir)
			_hold_t = 0.0
		return
	_hold_t = 0.0

	# --- Restart taker duty (goal kicks) ---
	if mgr.phase == C.Phase.RESTART and mgr.restart_taker == p.idx:
		var b2 := Vector2(ball.global_position.x, ball.global_position.z)
		_target = b2
		_steer(my2, true)
		if my2.distance_to(b2) < 1.6 and mgr.restart_elapsed() > 1.6:
			p.queue_action(C.Action.LOB, 1.0,
				Vector2(dir, randf_range(-0.35, 0.35)).normalized())
		return

	if mgr.phase != C.Phase.PLAY:
		p.ai_move = Vector2.ZERO
		return

	var bpos := ball.global_position
	var bv := ball.linear_velocity
	var d_ball := my2.distance_to(Vector2(bpos.x, bpos.z))

	# --- Catch / parry when the ball is on us ---
	if d_ball < 1.2 and ball.holder == null and not ball.rules_frozen \
			and mgr.can_touch_ball(p) and bpos.y < 2.3:
		var speed := bv.length()
		var catch_prob := clampf(1.55 - speed / 21.0, 0.12, 0.95)
		if speed < 9.0 or randf() < catch_prob:
			ball.hold(p)
			mgr.notify_keeper_catch(p)
		else:
			var out := Vector3(-dir * 0.4, 0.0, signf(bpos.z) if absf(bpos.z) > 0.3 else 1.0)
			out = (out.normalized() + Vector3(0, 0.45, 0)).normalized()
			ball.kick(out * clampf(speed * 0.55, 8.0, 16.0),
				Vector3.ZERO, p.idx, p.team)
			mgr.notify_save(p)
		return

	# --- Shot incoming? Predict where it crosses our line ---
	var toward_goal := bv.x * -dir > 6.0   # ball moving toward our end fast
	if toward_goal:
		var t_line: float = (goal_x - bpos.x) / bv.x
		if t_line > 0.0 and t_line < 1.5:
			var z_pred: float = bpos.z + bv.z * t_line
			var y_pred: float = bpos.y + bv.y * t_line - 4.905 * t_line * t_line
			if absf(z_pred) < 5.5 and y_pred < 3.4 and y_pred > -1.0:
				_target = Vector2(goal_x + dir * 0.7, clampf(z_pred, -4.3, 4.3))
				_steer(my2, true)
				# Dive when it's about to arrive and out of walking reach.
				var eta := d_ball / maxf(bv.length(), 0.01)
				if eta < 0.42 and d_ball < 4.5 and d_ball > 1.0:
					var at := bpos + bv * eta * 0.6
					p.start_dive(Vector3(at.x - p.global_position.x, 0.0,
						at.z - p.global_position.z))
				return

	# --- Claim a slow loose ball in our box ---
	var in_my_box: bool = (bpos.x * -dir > C.HALF_LEN - C.PENALTY_BOX_DEPTH) \
		and absf(bpos.z) < C.PENALTY_BOX_WIDTH * 0.5
	if in_my_box and ball.holder == null and bv.length() < 7.0 \
			and mgr.possession_team != 1 - p.team:
		var opp_d: float = mgr.nearest_opponent_dist_to_ball(p.team)
		if d_ball < opp_d * 0.9 or d_ball < 3.0:
			_target = Vector2(bpos.x, bpos.z)
			_steer(my2, true)
			return

	# --- Default: hold the angle between ball and goal center ---
	var goal2 := Vector2(goal_x, 0.0)
	var ball2 := Vector2(bpos.x, bpos.z)
	var ball_dist := goal2.distance_to(ball2)
	var off_line := lerpf(4.5, 1.0, clampf(ball_dist / 55.0, 0.0, 1.0))
	if ball_dist > 60.0:
		off_line = 8.0   # sweeper position when play is far away
	var out_dir := (ball2 - goal2).normalized()
	_target = goal2 + out_dir * off_line
	_target.x = clampf(_target.x, minf(goal_x, goal_x + dir * 14.0),
		maxf(goal_x, goal_x + dir * 14.0))
	_target.y = clampf(_target.y, -5.5, 5.5)
	_steer(my2, false)


func _steer(my2: Vector2, sprint: bool) -> void:
	var to_t := _target - my2
	p.ai_move = Vector2.ZERO if to_t.length() < 0.35 else to_t.normalized()
	p.ai_sprint = sprint


func _distribute(dir: float) -> void:
	var ball: Ball = mgr.ball
	var mate: Player = mgr.pick_open_teammate(p)
	if mate != null:
		var to_m: Vector3 = mate.global_position - p.global_position
		var d := Vector2(to_m.x, to_m.z).length()
		if d < 26.0:
			# Roll/throw it out.
			var v := Vector3(to_m.x, 0.0, to_m.z).normalized() * clampf(6.0 + d * 0.45, 7.0, C.KEEPER_THROW_SPEED)
			v.y = 2.0
			ball.kick(v, Vector3.ZERO, p.idx, p.team)
			return
	# Big boot upfield.
	p.queue_action(C.Action.LOB, 1.0, Vector2(dir, randf_range(-0.5, 0.5)).normalized())

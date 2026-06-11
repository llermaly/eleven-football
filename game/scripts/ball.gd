class_name Ball
extends RigidBody3D
## Server-side match ball. Realistic flight model on top of Godot rigid body
## dynamics: quadratic air drag, Magnus lift from spin, rolling resistance,
## grass restitution. Clients never instance this — they render snapshots.

signal kicked(strength: float)
signal bounced(strength: float)

var last_toucher: int = -1
var last_touch_team: int = -1
var holder: Node3D = null            # keeper holding the ball (rules-frozen)
var rules_frozen: bool = false       # placed for a restart, nobody may move it

var _kick_cooldown := 0.0


static func create() -> Ball:
	var b := Ball.new()
	b.name = "Ball"
	b.mass = C.BALL_MASS
	b.continuous_cd = true
	b.contact_monitor = true
	b.max_contacts_reported = 4
	b.collision_layer = 4
	b.collision_mask = 1 | 2 | 8 | 16   # ground, players, goals, walls
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = C.BALL_RADIUS
	shape.shape = sphere
	b.add_child(shape)
	var mat := PhysicsMaterial.new()
	mat.bounce = C.BALL_BOUNCE
	mat.friction = C.BALL_FRICTION
	b.physics_material_override = mat
	b.angular_damp = C.AIR_ANGULAR_DAMP
	b.linear_damp = 0.0
	b.body_entered.connect(b._on_body_entered)
	return b


func _physics_process(delta: float) -> void:
	_kick_cooldown = maxf(0.0, _kick_cooldown - delta)
	if holder != null:
		# Glued to the keeper's hands; keeper AI releases via kick()/release().
		global_position = holder.global_position \
			+ holder.heading() * 0.45 + Vector3(0.0, 1.0, 0.0)
		return
	if freeze:
		return
	_sanity_check()
	var v := linear_velocity
	var sp := v.length()
	var force := Vector3.ZERO
	# Quadratic air drag: F = -0.5 * rho * Cd * A * |v| * v
	if sp > 0.05:
		force += -0.5 * C.AIR_DENSITY * C.BALL_DRAG_CD * C.BALL_AREA * sp * v
	# Magnus effect: F = k * (w x v) — curls shots with sidespin, dips topspin.
	var w := angular_velocity
	if w.length_squared() > 1.0 and sp > 1.0:
		var magnus := C.MAGNUS_COEF * w.cross(v)
		var max_f := C.MAGNUS_MAX_ACCEL * mass
		if magnus.length() > max_f:
			magnus = magnus.normalized() * max_f
		force += magnus
	var on_ground := global_position.y <= C.BALL_RADIUS + 0.04
	if on_ground:
		angular_damp = C.GROUND_ANGULAR_DAMP
		var hv := Vector3(v.x, 0.0, v.z)
		if hv.length() > 0.15:
			force += -hv.normalized() * C.ROLL_RESIST_DECEL * mass
	else:
		angular_damp = C.AIR_ANGULAR_DAMP
	apply_central_force(force)
	if angular_velocity.length() > C.SPIN_MAX:
		angular_velocity = angular_velocity.normalized() * C.SPIN_MAX


## Full-blooded strike: sets velocity directly (foot contact is sub-tick anyway).
func kick(vel: Vector3, spin: Vector3, kicker_idx: int, kicker_team: int) -> void:
	release()
	rules_frozen = false
	freeze = false
	sleeping = false
	linear_velocity = vel
	angular_velocity = spin.limit_length(C.SPIN_MAX)
	last_toucher = kicker_idx
	last_touch_team = kicker_team
	_kick_cooldown = 0.15
	kicked.emit(vel.length())


## Soft dribble touch — nudges the ball without the kick cooldown/sfx weight.
func touch(vel: Vector3, toucher_idx: int, toucher_team: int) -> void:
	if holder != null or rules_frozen or _kick_cooldown > 0.0:
		return
	freeze = false
	sleeping = false
	linear_velocity = vel
	angular_velocity = Vector3(vel.z, 0.0, -vel.x) / C.BALL_RADIUS * 0.5
	last_toucher = toucher_idx
	last_touch_team = toucher_team


func hold(by: Node3D) -> void:
	holder = by
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func release() -> void:
	if holder != null:
		holder = null
		freeze = false


## Rules placement (kickoff, throw-in, corner, goal kick).
func place(pos: Vector3, frozen: bool = true) -> void:
	release()
	global_position = pos
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	rules_frozen = frozen
	freeze = frozen


func unfreeze_rules() -> void:
	rules_frozen = false
	freeze = false
	sleeping = false


func _on_body_entered(body: Node) -> void:
	if body is Player:
		# Body blocks/deflections absorb a lot of energy.
		if _kick_cooldown <= 0.0:
			linear_velocity *= 0.45
			angular_velocity *= 0.5
			last_toucher = body.idx
			last_touch_team = body.team
			bounced.emit(linear_velocity.length())
	else:
		var impact := absf(linear_velocity.y)
		if impact > 2.0:
			bounced.emit(impact)


func _sanity_check() -> void:
	var p := global_position
	if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)) \
			or p.y < -5.0 or absf(p.x) > 90.0 or absf(p.z) > 70.0 or p.y > 60.0:
		place(Vector3(0.0, C.BALL_RADIUS + 0.01, 0.0), false)
		return
	# Squeezed under the turf by a depenetration fight? Pop it back up.
	if p.y < C.BALL_RADIUS - 0.06:
		global_position.y = C.BALL_RADIUS
		if linear_velocity.y < 0.0:
			linear_velocity.y = 0.0

class_name CameraRig
extends Node3D
## Broadcast telecam on the -z sideline (high TV gantry shot).
## main.gd calls setup() once, then track() every render frame with the
## interpolated ball state. goal_mode() swings into a closer celebration
## shot; normal_mode() eases back to match coverage.
## Self-contained: reads only constants from C.

enum Mode { NORMAL, GOAL }

# --- Telecam framing --------------------------------------------------------
const BASE_HEIGHT := 17.0        # gantry height (m)
const BASE_BACK := 26.0          # distance behind the -z touchline (m)
const BASE_FOV := 33.0           # long broadcast lens
const PAN_SCALE := 0.92          # camera travels a little less than the ball
const PAN_LIMIT_MARGIN := 4.0    # keep the gantry off the corner flags
const LEAD_TIME := 0.5           # seconds of ball-velocity lead on the pan
const AIM_LEAD_TIME := 0.15      # smaller anticipation on the aim point
const FOLLOW_SMOOTH := 0.55      # smooth-time of the critically damped x follow
const AIM_SMOOTH := 0.38         # smooth-time of the aim point
const LOOK_CENTER_BLEND := 0.28  # aim pulled toward midfield for steady framing
const LOOK_HEIGHT := 1.1         # aim a touch above the grass
const AIR_FOLLOW := 0.45         # how much the aim chases lofted balls

# --- Subtle push-in near the goals ------------------------------------------
const ZOOM_START_X := 28.0       # |ball x| where the zoom begins
const ZOOM_HEIGHT := 14.0
const ZOOM_BACK := 19.5
const ZOOM_FOV := 29.0

# --- Celebration shot --------------------------------------------------------
const CELEB_HEIGHT := 6.5
const CELEB_BACK := 14.5
const CELEB_DOLLY := 0.9         # slow push-in speed (m/s) while celebrating
const CELEB_DOLLY_MAX := 3.5
const CELEB_FOV := 38.0
const CELEB_SWAY := 4.5          # lateral drift amplitude (m)
const CELEB_SWAY_RATE := 0.45    # rad/s of the drift
const MODE_BLEND_RATE := 2.0     # exp rate for swinging between modes
const SETTLE_RATE := 3.0         # exp rate for height/back/fov settling

var _cam: Camera3D
var _mode: int = Mode.NORMAL
var _goal_focus := Vector3.ZERO
var _goal_t := 0.0
var _blend := 0.0                # 0 = telecam, 1 = celebration shot

var _x := 0.0                    # critically damped pan state
var _x_vel := 0.0
var _aim := Vector3(0.0, LOOK_HEIGHT, 0.0)
var _aim_vel := Vector3.ZERO
var _pos := Vector3.ZERO
var _fov := BASE_FOV


func setup(parent_viewport_world: Node3D) -> void:
	name = "CameraRig"
	_cam = Camera3D.new()
	_cam.name = "TeleCam"
	_cam.fov = BASE_FOV
	_cam.near = 0.4
	_cam.far = 500.0
	_cam.current = true
	add_child(_cam)
	if parent_viewport_world != null and get_parent() == null:
		parent_viewport_world.add_child(self)
	_pos = Vector3(0.0, BASE_HEIGHT, -(C.HALF_WID + BASE_BACK))
	_aim = Vector3(0.0, LOOK_HEIGHT, 0.0)
	_x = 0.0
	_x_vel = 0.0
	_aim_vel = Vector3.ZERO
	_fov = BASE_FOV
	_apply()


func track(ball_pos: Vector3, ball_vel: Vector3, delta: float) -> void:
	if _cam == null or not ball_pos.is_finite() or not ball_vel.is_finite():
		return
	var dt := clampf(delta, 0.0001, 0.1)

	# Eased swing between the telecam and the celebration shot.
	var want := 1.0 if _mode == Mode.GOAL else 0.0
	_blend = lerpf(_blend, want, 1.0 - exp(-MODE_BLEND_RATE * dt))
	if _mode == Mode.GOAL:
		_goal_t += dt
	var k: float = smoothstep(0.0, 1.0, _blend)

	# --- Telecam targets ---
	var lead_x := clampf(ball_pos.x + ball_vel.x * LEAD_TIME, -C.HALF_LEN, C.HALF_LEN)
	var zoom: float = smoothstep(ZOOM_START_X, C.HALF_LEN, absf(lead_x))
	var tele_pos := Vector3(
		0.0,  # x filled in after the damped pan below
		lerpf(BASE_HEIGHT, ZOOM_HEIGHT, zoom),
		-(C.HALF_WID + lerpf(BASE_BACK, ZOOM_BACK, zoom)))
	var tele_fov := lerpf(BASE_FOV, ZOOM_FOV, zoom)

	var anticipated := ball_pos + ball_vel * AIM_LEAD_TIME
	var tele_aim := anticipated.lerp(Vector3.ZERO, LOOK_CENTER_BLEND)
	tele_aim.x = clampf(tele_aim.x, -C.HALF_LEN, C.HALF_LEN)
	tele_aim.z = clampf(tele_aim.z, -C.HALF_WID, C.HALF_WID)
	tele_aim.y = LOOK_HEIGHT + maxf(ball_pos.y - C.BALL_RADIUS, 0.0) * AIR_FOLLOW

	# Critically damped x pan with velocity lead.
	var sd := _smooth_damp(_x, lead_x, _x_vel, FOLLOW_SMOOTH, dt)
	_x = sd.x
	_x_vel = sd.y
	var pan_limit := C.HALF_LEN - PAN_LIMIT_MARGIN
	tele_pos.x = clampf(_x * PAN_SCALE, -pan_limit, pan_limit)

	# --- Celebration targets, blended in by k ---
	var pos_t := tele_pos
	var aim_t := tele_aim
	var fov_t := tele_fov
	if k > 0.001:
		var dolly := minf(_goal_t * CELEB_DOLLY, CELEB_DOLLY_MAX)
		var celeb_pos := Vector3(
			clampf(_goal_focus.x + sin(_goal_t * CELEB_SWAY_RATE) * CELEB_SWAY,
				-(C.HALF_LEN + 8.0), C.HALF_LEN + 8.0),
			CELEB_HEIGHT,
			_goal_focus.z - (CELEB_BACK - dolly))
		var celeb_aim := _goal_focus + Vector3(0.0, 1.0, 0.0)
		pos_t = tele_pos.lerp(celeb_pos, k)
		aim_t = tele_aim.lerp(celeb_aim, k)
		fov_t = lerpf(tele_fov, CELEB_FOV, k)

	# --- Settle the rig onto its targets ---
	_pos.x = pos_t.x  # already damped/eased above
	var settle := 1.0 - exp(-SETTLE_RATE * dt)
	_pos.y = lerpf(_pos.y, pos_t.y, settle)
	_pos.z = lerpf(_pos.z, pos_t.z, settle)
	_fov = lerpf(_fov, fov_t, settle)

	var ad := _smooth_damp_v3(_aim, aim_t, _aim_vel, AIM_SMOOTH, dt)
	_aim = ad[0]
	_aim_vel = ad[1]

	_apply()


func goal_mode(focus: Vector3) -> void:
	var f := focus if focus.is_finite() else Vector3.ZERO
	_goal_focus = Vector3(
		clampf(f.x, -(C.HALF_LEN + 4.0), C.HALF_LEN + 4.0),
		0.0,
		clampf(f.z, -C.HALF_WID, C.HALF_WID))
	_goal_t = 0.0
	_mode = Mode.GOAL


func normal_mode() -> void:
	_mode = Mode.NORMAL


# --- Internals ---------------------------------------------------------------

func _apply() -> void:
	if _cam == null:
		return
	_cam.fov = _fov
	var dir := _aim - _pos
	if dir.length_squared() < 0.000001:
		dir = Vector3.FORWARD
	_cam.transform = Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), _pos)


## Critically damped spring smoothing (SmoothDamp). Returns (value, velocity).
func _smooth_damp(current: float, target: float, vel: float,
		smooth_time: float, dt: float) -> Vector2:
	var omega := 2.0 / maxf(smooth_time, 0.0001)
	var x := omega * dt
	var decay := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change := current - target
	var temp := (vel + omega * change) * dt
	var new_vel := (vel - omega * temp) * decay
	var new_val := target + (change + temp) * decay
	return Vector2(new_val, new_vel)


func _smooth_damp_v3(current: Vector3, target: Vector3, vel: Vector3,
		smooth_time: float, dt: float) -> Array:
	var rx := _smooth_damp(current.x, target.x, vel.x, smooth_time, dt)
	var ry := _smooth_damp(current.y, target.y, vel.y, smooth_time, dt)
	var rz := _smooth_damp(current.z, target.z, vel.z, smooth_time, dt)
	return [Vector3(rx.x, ry.x, rz.x), Vector3(rx.y, ry.y, rz.y)]

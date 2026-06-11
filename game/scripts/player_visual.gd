class_name PlayerVisual
extends Node3D
## Client-side humanoid body + procedural animation for one soccer player.
## Built 100% from primitive meshes in code (no scenes, no assets).
## All joints lerp toward per-anim target angles every frame, so poses blend
## smoothly when the server switches anim states. Meshes and materials are
## shared via static caches keyed by team/keeper so 22 players stay cheap
## (11 MeshInstances per body + 1 highlight ring = 12, the budget cap).
## See INTERFACES.md — only `C` (constants.gd) may be referenced.

# ---------- proportions (meters; soles rest on y=0 when self.position.y == 0) ----------
const HIP_Y := 0.92
const THIGH_LEN := 0.46
const SHIN_LEN := 0.42
const HIP_HALF_W := 0.105
const CHEST_PIVOT_Y := 0.06          # chest pivot above hip
const SHOULDER_X := 0.235
const SHOULDER_Y := 0.46             # above chest pivot
const HEAD_PIVOT_Y := 0.56           # above chest pivot
const LABEL_Y := 2.12
const ARM_SPLAY := 0.14              # resting outward arm tilt (rad)
const LABEL_MAX_DIST := 45.0

# ---------- joint channel indices (smoothed float pose vector) ----------
const J_LEG_L := 0                   # left thigh pitch  (+ = swing forward)
const J_LEG_R := 1                   # right thigh pitch
const J_SHIN_L := 2                  # left knee  (- = bend backward)
const J_SHIN_R := 3                  # right knee
const J_ARM_LX := 4                  # left arm pitch (+ = swing forward/up)
const J_ARM_RX := 5                  # right arm pitch
const J_ARM_LZ := 6                  # left arm sideways splay (- = outward)
const J_ARM_RZ := 7                  # right arm sideways splay (+ = outward)
const J_LEAN := 8                    # chest pitch: - = lean forward (run lean)
const J_PITCH := 9                   # whole-body pitch: + = recline back (slide/fall)
const J_ROLL := 10                   # whole-body roll (keeper dive)
const J_HIP := 11                    # hip height above ground
const J_HEAD := 12                   # head pitch: + = look up
const J_COUNT := 13

# ---------- shared static caches (built once, reused by every instance) ----------
static var _meshes: Dictionary = {}
static var _mats: Dictionary = {}

# ---------- instance state ----------
var _team := 0
var _number := 0
var _is_keeper := false
var _built := false

var _body: Node3D                    # hip root: height + whole-body pitch/roll
var _chest: Node3D                   # torso/arms/head root: run lean
var _head: Node3D
var _arm_l: Node3D
var _arm_r: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _shin_l: Node3D
var _shin_r: Node3D
var _label: Label3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D

var _cur := PackedFloat32Array()     # current smoothed joint values
var _tgt := PackedFloat32Array()     # this-frame pose targets
var _phase := 0.0                    # run cycle phase (radians)
var _time := 0.0                     # local animation clock
var _last_anim := -1
var _dive_sign := 1.0
var _dive_locked := false
var _prev_pos := Vector3.ZERO


func _init() -> void:
	_cur.resize(J_COUNT)
	_tgt.resize(J_COUNT)
	_cur[J_HIP] = HIP_Y
	_cur[J_ARM_LZ] = -ARM_SPLAY
	_cur[J_ARM_RZ] = ARM_SPLAY


# ============================================================ public API ====

func setup(team: int, number: int, pname: String, is_keeper: bool) -> void:
	_team = clampi(team, 0, C.KITS.size() - 1)
	_number = number
	_is_keeper = is_keeper
	for child in get_children():
		child.queue_free()

	var kit: Dictionary = C.KITS[_team]
	var shirt_col: Color = kit["gk_shirt"] if is_keeper else kit["shirt"]
	var shorts_col: Color = kit["gk_shorts"] if is_keeper else kit["shorts"]
	var socks_col: Color = kit["gk_shorts"] if is_keeper else kit["socks"]
	var skin_idx := absi(number) % C.SKIN_TONES.size()
	var skin_col: Color = C.SKIN_TONES[skin_idx]
	var kt := "k" if is_keeper else "o"

	var m_shirt := _mat("shirt_%d_%s" % [_team, kt], shirt_col, 0.82)
	var m_shorts := _mat("shorts_%d_%s" % [_team, kt], shorts_col, 0.85)
	var m_socks := _mat("socks_%d_%s" % [_team, kt], socks_col, 0.88)
	var m_skin := _mat("skin_%d" % skin_idx, skin_col, 0.65)
	var m_boot := _mat("boot", Color(0.08, 0.08, 0.09), 0.45)

	# --- skeleton ---
	_body = Node3D.new()
	_body.position = Vector3(0.0, HIP_Y, 0.0)
	add_child(_body)

	_chest = Node3D.new()
	_chest.position = Vector3(0.0, CHEST_PIVOT_Y, 0.0)
	_body.add_child(_chest)

	# torso jersey (capsule flattened front-to-back for a nicer silhouette)
	_mi(_mesh("torso"), m_shirt, _chest, Vector3(0.0, 0.27, 0.0), Vector3(1.0, 1.0, 0.72))
	# shorts
	_mi(_mesh("shorts"), m_shorts, _body, Vector3(0.0, 0.04, 0.0))

	# head
	_head = Node3D.new()
	_head.position = Vector3(0.0, HEAD_PIVOT_Y, 0.0)
	_chest.add_child(_head)
	_mi(_mesh("head"), m_skin, _head, Vector3(0.0, 0.14, 0.0))

	# arms (jersey sleeves; single segment each, pivot at shoulder)
	_arm_l = Node3D.new()
	_arm_l.position = Vector3(-SHOULDER_X, SHOULDER_Y, 0.0)
	_chest.add_child(_arm_l)
	_mi(_mesh("arm"), m_shirt, _arm_l, Vector3(0.0, -0.225, 0.0))

	_arm_r = Node3D.new()
	_arm_r.position = Vector3(SHOULDER_X, SHOULDER_Y, 0.0)
	_chest.add_child(_arm_r)
	_mi(_mesh("arm"), m_shirt, _arm_r, Vector3(0.0, -0.225, 0.0))

	# legs: thigh (skin) -> shin (sock) -> boot. Pivots at hip and knee.
	_leg_l = Node3D.new()
	_leg_l.position = Vector3(-HIP_HALF_W, 0.0, 0.0)
	_body.add_child(_leg_l)
	_mi(_mesh("thigh"), m_skin, _leg_l, Vector3(0.0, -0.22, 0.0))
	_shin_l = Node3D.new()
	_shin_l.position = Vector3(0.0, -THIGH_LEN, 0.0)
	_leg_l.add_child(_shin_l)
	_mi(_mesh("shin"), m_socks, _shin_l, Vector3(0.0, -0.19, 0.0))
	_mi(_mesh("boot"), m_boot, _shin_l, Vector3(0.0, -0.393, -0.065))

	_leg_r = Node3D.new()
	_leg_r.position = Vector3(HIP_HALF_W, 0.0, 0.0)
	_body.add_child(_leg_r)
	_mi(_mesh("thigh"), m_skin, _leg_r, Vector3(0.0, -0.22, 0.0))
	_shin_r = Node3D.new()
	_shin_r.position = Vector3(0.0, -THIGH_LEN, 0.0)
	_leg_r.add_child(_shin_r)
	_mi(_mesh("shin"), m_socks, _shin_r, Vector3(0.0, -0.19, 0.0))
	_mi(_mesh("boot"), m_boot, _shin_r, Vector3(0.0, -0.393, -0.065))

	# --- name/number tag ---
	_label = Label3D.new()
	var clean := pname.strip_edges()
	_label.text = str(number) if clean.is_empty() else "%d · %s" % [number, clean]
	_label.font_size = 44
	_label.outline_size = 10
	_label.pixel_size = 0.0008
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.modulate = Color(1.0, 1.0, 1.0, 0.92)
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	_label.position = Vector3(0.0, LABEL_Y, 0.0)
	_label.visibility_range_end = LABEL_MAX_DIST
	add_child(_label)

	# --- highlight ring (controlled-player marker) ---
	_ring = MeshInstance3D.new()
	_ring.mesh = _mesh("ring")
	_ring_mat = StandardMaterial3D.new()  # per-instance: color set in set_highlight
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.85)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.position = Vector3(0.0, 0.035, 0.0)
	_ring.visible = false
	add_child(_ring)

	_built = true
	_pose_apply()  # snap initial pose


func apply_state(yaw: float, speed: float, anim: int, anim_t: float) -> void:
	if not _built:
		return
	var dt := get_process_delta_time()
	if dt <= 0.0:
		dt = 1.0 / 60.0
	_time += dt
	rotation.y = yaw + PI   # model front is local -Z; server yaw faces +Z

	if anim != _last_anim:
		if anim == C.Anim.DIVE:
			_dive_locked = false
		_last_anim = anim
	if anim == C.Anim.DIVE and not _dive_locked:
		# Roll direction from actual lateral motion (position is set by the
		# interpolated snapshot before apply_state runs each frame).
		var d3 := position - _prev_pos
		var lateral := d3.x * cos(yaw) - d3.z * sin(yaw)
		if absf(lateral) > 0.02:
			_dive_sign = -signf(lateral)
			_dive_locked = true
	_prev_pos = position

	# RUN with near-zero speed reads as standing — use the idle pose instead.
	var a := anim
	if a == C.Anim.RUN and speed < 0.25:
		a = C.Anim.IDLE

	_pose_defaults()
	match a:
		C.Anim.RUN:
			_pose_run(speed, dt)
		C.Anim.KICK:
			_pose_kick(clampf(anim_t, 0.0, 1.0))
		C.Anim.SLIDE:
			_pose_slide()
		C.Anim.DIVE:
			_pose_dive(clampf(anim_t, 0.0, 1.0))
		C.Anim.CELEBRATE:
			_pose_celebrate()
		C.Anim.FALL:
			_pose_fall()
		_:
			_pose_idle()

	# blend: limbs track faster than posture so transitions feel weighty
	var rates := _blend_rates(a)
	var kl := 1.0 - exp(-rates.x * dt)
	var kb := 1.0 - exp(-rates.y * dt)
	for i in J_COUNT:
		_cur[i] = lerpf(_cur[i], _tgt[i], kl if i <= J_ARM_RZ else kb)
	_pose_apply()

	if _ring.visible:
		var s := 1.0 + 0.06 * sin(_time * 6.0)
		_ring.scale = Vector3(s, 1.0, s)


func set_highlight(on: bool, color: Color) -> void:
	if _ring == null:
		return
	_ring.visible = on
	if on:
		_ring_mat.albedo_color = Color(color.r, color.g, color.b, 0.85)


# ============================================================ poses ====

func _pose_defaults() -> void:
	for i in J_COUNT:
		_tgt[i] = 0.0
	_tgt[J_HIP] = HIP_Y
	_tgt[J_ARM_LZ] = -ARM_SPLAY
	_tgt[J_ARM_RZ] = ARM_SPLAY
	_tgt[J_SHIN_L] = -0.08
	_tgt[J_SHIN_R] = -0.08
	_tgt[J_LEAN] = -0.04


func _pose_idle() -> void:
	# soft breathing + weight shift; offset phases keep it from looking metronomic
	var b := sin(_time * 1.7)
	_tgt[J_HIP] = HIP_Y - 0.008 + 0.005 * b
	_tgt[J_LEAN] = -0.045 + 0.02 * b
	_tgt[J_ARM_LX] = 0.05 * sin(_time * 1.7 + 0.6)
	_tgt[J_ARM_RX] = 0.05 * sin(_time * 1.7 + 2.2)
	_tgt[J_ROLL] = 0.025 * sin(_time * 0.7)
	_tgt[J_HEAD] = 0.03 * sin(_time * 0.9 + 1.0)
	_tgt[J_SHIN_L] = -0.10
	_tgt[J_SHIN_R] = -0.10


func _pose_run(speed: float, dt: float) -> void:
	var n := clampf(speed / C.SPRINT_SPEED, 0.0, 1.0)
	_phase += dt * (5.0 + 8.5 * n)        # stride frequency scales with speed
	var s := sin(_phase)
	var amp := lerpf(0.35, 1.0, n)
	var thigh := lerpf(0.45, 0.95, n)

	_tgt[J_LEG_L] = s * thigh
	_tgt[J_LEG_R] = -s * thigh
	# knee flexes hardest mid-recovery (while that thigh swings forward)
	_tgt[J_SHIN_L] = -(0.18 + 1.35 * amp * maxf(0.0, cos(_phase)))
	_tgt[J_SHIN_R] = -(0.18 + 1.35 * amp * maxf(0.0, -cos(_phase)))
	# arms counter-swing the legs
	_tgt[J_ARM_LX] = -s * 0.65 * amp
	_tgt[J_ARM_RX] = s * 0.65 * amp
	_tgt[J_ARM_LZ] = -0.18
	_tgt[J_ARM_RZ] = 0.18
	_tgt[J_LEAN] = -(0.06 + 0.24 * n)     # forward lean grows with speed
	_tgt[J_HEAD] = 0.15 * n               # keep gaze level against the lean
	# two footfalls per cycle -> double-frequency bob, plus slight crouch
	_tgt[J_HIP] = HIP_Y - 0.04 * amp + 0.045 * amp * absf(cos(_phase))
	_tgt[J_ROLL] = 0.035 * amp * s        # subtle hip sway


func _pose_kick(t: float) -> void:
	# plant-and-swing, right footed: wind-up -> strike -> follow-through
	var w := smoothstep(0.0, 0.32, t)     # wind-up
	var k := smoothstep(0.36, 0.58, t)    # strike
	var f := smoothstep(0.70, 1.0, t)     # settle
	_tgt[J_LEG_R] = -0.9 * w + 2.1 * k - 0.85 * f
	_tgt[J_SHIN_R] = -1.7 * w + 1.62 * k - 0.35 * f
	_tgt[J_LEG_L] = 0.28 * w - 0.18 * k   # planted left leg braces
	_tgt[J_SHIN_L] = -0.45
	_tgt[J_LEAN] = 0.10 * w - 0.38 * k + 0.10 * f
	_tgt[J_ROLL] = 0.12 * k               # tip over the plant leg
	_tgt[J_ARM_LX] = -0.20 * w + 0.85 * k # opposite arm swings through
	_tgt[J_ARM_RX] = 0.30 * w - 0.70 * k
	_tgt[J_ARM_LZ] = -ARM_SPLAY - 0.55 * k
	_tgt[J_ARM_RZ] = ARM_SPLAY + 0.45 * k
	_tgt[J_HIP] = HIP_Y - 0.02 * w - 0.07 * k
	_tgt[J_HEAD] = -0.28 * w + 0.10 * k   # eyes on the ball


func _pose_slide() -> void:
	# low reclined slide, right leg extended along the grass, left tucked
	_tgt[J_HIP] = 0.34
	_tgt[J_PITCH] = 0.78
	_tgt[J_LEAN] = 0.15
	_tgt[J_LEG_R] = 2.15
	_tgt[J_SHIN_R] = -0.06
	_tgt[J_LEG_L] = 1.0
	_tgt[J_SHIN_L] = -1.85
	_tgt[J_ARM_LX] = -0.5
	_tgt[J_ARM_RX] = 0.9
	_tgt[J_ARM_LZ] = -0.9
	_tgt[J_ARM_RZ] = 0.8
	_tgt[J_HEAD] = 0.45


func _pose_dive(t: float) -> void:
	# keeper dive: launch up + roll sideways with arms at full stretch, then land low
	var up := smoothstep(0.0, 0.40, t)
	var land := smoothstep(0.50, 0.95, t)
	_tgt[J_ROLL] = _dive_sign * (1.45 * up - 0.10 * land)
	_tgt[J_PITCH] = -0.25 * up
	_tgt[J_HIP] = HIP_Y + 0.30 * up - (HIP_Y + 0.30 - 0.34) * land
	_tgt[J_ARM_LX] = 2.9 * up             # both arms stretched past overhead
	_tgt[J_ARM_RX] = 2.9 * up
	_tgt[J_ARM_LZ] = -0.25
	_tgt[J_ARM_RZ] = 0.25
	_tgt[J_LEG_L] = 0.25 * up
	_tgt[J_LEG_R] = -0.10
	_tgt[J_SHIN_L] = -0.50 * up
	_tgt[J_SHIN_R] = -0.15
	_tgt[J_LEAN] = -0.10
	_tgt[J_HEAD] = -0.30 * up


func _pose_celebrate() -> void:
	var hop := absf(sin(_time * 6.5))
	var wave := sin(_time * 6.5)
	_tgt[J_HIP] = HIP_Y + 0.20 * hop
	_tgt[J_ARM_LX] = 2.75                 # both arms up
	_tgt[J_ARM_RX] = 2.75
	_tgt[J_ARM_LZ] = -0.5 - 0.25 * wave   # waving spread
	_tgt[J_ARM_RZ] = 0.5 + 0.25 * wave
	_tgt[J_LEG_L] = 0.30 * hop
	_tgt[J_LEG_R] = 0.30 * hop
	_tgt[J_SHIN_L] = -0.70 * hop
	_tgt[J_SHIN_R] = -0.70 * hop
	_tgt[J_LEAN] = 0.12
	_tgt[J_HEAD] = 0.35
	_tgt[J_ROLL] = 0.06 * wave


func _pose_fall() -> void:
	# flat on the back, limbs loose
	_tgt[J_HIP] = 0.30
	_tgt[J_PITCH] = 1.35
	_tgt[J_LEAN] = 0.10
	_tgt[J_LEG_L] = 0.35
	_tgt[J_LEG_R] = 0.15
	_tgt[J_SHIN_L] = -0.50
	_tgt[J_SHIN_R] = -0.25
	_tgt[J_ARM_LX] = 0.5
	_tgt[J_ARM_RX] = 0.4
	_tgt[J_ARM_LZ] = -1.1
	_tgt[J_ARM_RZ] = 1.0
	_tgt[J_HEAD] = 0.5


func _blend_rates(a: int) -> Vector2:
	# x = limb lerp rate, y = posture lerp rate (1/s)
	match a:
		C.Anim.KICK, C.Anim.DIVE:
			return Vector2(20.0, 12.0)
		C.Anim.RUN:
			return Vector2(14.0, 7.0)
		C.Anim.SLIDE:
			return Vector2(13.0, 10.0)
		C.Anim.CELEBRATE:
			return Vector2(10.0, 8.0)
		_:
			return Vector2(7.0, 6.0)


func _pose_apply() -> void:
	_leg_l.rotation.x = _cur[J_LEG_L]
	_leg_r.rotation.x = _cur[J_LEG_R]
	_shin_l.rotation.x = _cur[J_SHIN_L]
	_shin_r.rotation.x = _cur[J_SHIN_R]
	_arm_l.rotation = Vector3(_cur[J_ARM_LX], 0.0, _cur[J_ARM_LZ])
	_arm_r.rotation = Vector3(_cur[J_ARM_RX], 0.0, _cur[J_ARM_RZ])
	_chest.rotation.x = _cur[J_LEAN]
	_head.rotation.x = _cur[J_HEAD]
	_body.position.y = _cur[J_HIP]
	_body.rotation = Vector3(_cur[J_PITCH], 0.0, _cur[J_ROLL])


# ============================================================ shared builders ====

func _mi(mesh: Mesh, mat: Material, parent: Node3D, pos: Vector3,
		scl: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	inst.position = pos
	if scl != Vector3.ONE:
		inst.scale = scl
	parent.add_child(inst)
	return inst


static func _mat(key: String, col: Color, rough: float = 0.85) -> StandardMaterial3D:
	var m: StandardMaterial3D = _mats.get(key)
	if m != null:
		return m
	m = StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = 0.0
	_mats[key] = m
	return m


static func _mesh(key: String) -> Mesh:
	var found: Mesh = _meshes.get(key)
	if found != null:
		return found
	var m: Mesh = null
	match key:
		"head":
			var sp := SphereMesh.new()
			sp.radius = 0.125
			sp.height = 0.25
			sp.radial_segments = 16
			sp.rings = 8
			m = sp
		"torso":
			var to := CapsuleMesh.new()
			to.radius = 0.17
			to.height = 0.64
			to.radial_segments = 14
			to.rings = 6
			m = to
		"shorts":
			var sh := BoxMesh.new()
			sh.size = Vector3(0.36, 0.26, 0.25)
			m = sh
		"arm":
			var ar := CapsuleMesh.new()
			ar.radius = 0.055
			ar.height = 0.52
			ar.radial_segments = 10
			ar.rings = 4
			m = ar
		"thigh":
			var th := CapsuleMesh.new()
			th.radius = 0.085
			th.height = 0.50
			th.radial_segments = 10
			th.rings = 4
			m = th
		"shin":
			var sn := CapsuleMesh.new()
			sn.radius = 0.065
			sn.height = 0.46
			sn.radial_segments = 10
			sn.rings = 4
			m = sn
		"boot":
			var bo := BoxMesh.new()
			bo.size = Vector3(0.12, 0.085, 0.27)
			m = bo
		"ring":
			var ri := TorusMesh.new()
			ri.inner_radius = 0.40
			ri.outer_radius = 0.52
			ri.rings = 40
			ri.ring_segments = 6
			m = ri
		_:
			m = BoxMesh.new()
	_meshes[key] = m
	return m

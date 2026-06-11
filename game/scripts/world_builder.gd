class_name WorldBuilder
extends Object
## Procedural stadium factory — pure static geometry, no autoloads, no state
## beyond texture caches. See INTERFACES.md.
##
## - build_visual_world(parent)    : client — pitch, goals, stands, lights, sky.
## - build_collision_world(parent) : server — colliders only, no meshes.
## - build_ball_visual(parent)     : returns a Node3D holding the ball mesh.
##
## Field coords: x = length [-52.5, 52.5], z = width [-34, 34], y up, ground y=0.
## All pitch markings are painted into the grass texture (no coplanar geometry,
## so no z-fighting). All materials are StandardMaterial3D and safe on the
## GL Compatibility renderer.

const PPM := 16.0                 # grass texture pixels per meter
const GRASS_MARGIN := 10.0        # grass apron beyond the lines, meters
const STRIPE_W := 7.5             # mowing stripe width (14 stripes over 105 m)
const WALL_DIST := 8.0            # collision backstop distance outside the pitch
const CEILING_Y := 30.0           # collision ceiling height
const NET_CELL := 0.96            # meters covered by one net-texture tile (8 cells)
const PITCH_WHITE := Color(0.93, 0.95, 0.93)

# Generated-texture caches (Resources are safe to keep across scene rebuilds).
static var _grass_tex: ImageTexture
static var _crowd_tex: ImageTexture
static var _net_tex: ImageTexture
static var _ad_tex: ImageTexture
static var _ball_tex: ImageTexture


# ============================================================ public API ====

static func build_visual_world(parent: Node3D) -> void:
	var root := Node3D.new()
	root.name = "VisualWorld"
	parent.add_child(root)
	_add_environment(root)
	_add_pitch(root)
	_add_goals(root)
	_add_ad_boards(root)
	_add_stands(root)
	_add_floodlights(root)


static func build_collision_world(parent: Node3D) -> void:
	var root := Node3D.new()
	root.name = "CollisionWorld"
	parent.add_child(root)

	# Ground — top surface at exactly y = 0.
	var ground_pm := PhysicsMaterial.new()
	ground_pm.friction = 0.85
	ground_pm.bounce = 0.0
	var ground := _static_body(root, "Ground", ground_pm)
	_add_box_shape(ground, Vector3(0, -2.0, 0), Vector3(280, 4, 240))

	# Goal frames (lively rebound) and net catch boxes (dead) behind each line.
	var frame_pm := PhysicsMaterial.new()
	frame_pm.friction = 0.4
	frame_pm.bounce = 0.55
	var net_pm := PhysicsMaterial.new()
	net_pm.friction = 0.95
	net_pm.bounce = 0.03
	for s: float in [-1.0, 1.0]:
		var gl := s * C.HALF_LEN
		var zoff := C.GOAL_WIDTH * 0.5 + C.POST_RADIUS         # post center z
		var side := "L" if s < 0.0 else "R"
		var post_h := C.GOAL_HEIGHT + C.POST_RADIUS * 2.0      # to top of bar

		var frame := _static_body(root, "GoalFrame" + side, frame_pm)
		for sz: float in [-1.0, 1.0]:
			_add_cylinder_shape(frame, Vector3(gl, post_h * 0.5, sz * zoff),
					C.POST_RADIUS, post_h, false)
		_add_cylinder_shape(frame, Vector3(gl, C.GOAL_HEIGHT + C.POST_RADIUS, 0),
				C.POST_RADIUS, C.GOAL_WIDTH + C.POST_RADIUS * 4.0, true)

		# Net box fully behind the goal line so it never touches a ball in play.
		var net := _static_body(root, "GoalNet" + side, net_pm)
		_add_box_shape(net, Vector3(gl + s * (C.GOAL_DEPTH + 0.06), 1.35, 0),
				Vector3(0.12, 2.7, 7.8))                       # back
		for sz: float in [-1.0, 1.0]:
			_add_box_shape(net, Vector3(gl + s * 1.17, 1.35, sz * (zoff + 0.06)),
					Vector3(2.30, 2.7, 0.12))                  # sides
		_add_box_shape(net, Vector3(gl + s * 1.17, post_h + 0.06, 0),
				Vector3(2.30, 0.12, 7.8))                      # top

	# Out-of-play backstop: walls 8 m outside the pitch, ceiling at 30 m.
	var wall_pm := PhysicsMaterial.new()
	wall_pm.friction = 0.6
	wall_pm.bounce = 0.35
	var walls := _static_body(root, "Perimeter", wall_pm)
	var wx := C.HALF_LEN + WALL_DIST                            # 60.5
	var wz := C.HALF_WID + WALL_DIST                            # 42.0
	_add_box_shape(walls, Vector3(wx + 0.5, CEILING_Y * 0.5, 0),
			Vector3(1, CEILING_Y, wz * 2.0 + 2.0))
	_add_box_shape(walls, Vector3(-wx - 0.5, CEILING_Y * 0.5, 0),
			Vector3(1, CEILING_Y, wz * 2.0 + 2.0))
	_add_box_shape(walls, Vector3(0, CEILING_Y * 0.5, wz + 0.5),
			Vector3(wx * 2.0 + 2.0, CEILING_Y, 1))
	_add_box_shape(walls, Vector3(0, CEILING_Y * 0.5, -wz - 0.5),
			Vector3(wx * 2.0 + 2.0, CEILING_Y, 1))
	_add_box_shape(walls, Vector3(0, CEILING_Y + 0.5, 0),
			Vector3(wx * 2.0 + 2.0, 1, wz * 2.0 + 2.0))


static func build_ball_visual(parent: Node3D) -> Node3D:
	var root := Node3D.new()
	root.name = "BallVisual"
	var mi := MeshInstance3D.new()
	mi.name = "BallMesh"
	var sphere := SphereMesh.new()
	sphere.radius = C.BALL_RADIUS
	sphere.height = C.BALL_RADIUS * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	mi.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _get_ball_tex()
	mat.roughness = 0.35
	mat.metallic = 0.0
	mi.material_override = mat
	root.add_child(mi)
	parent.add_child(root)
	return root


# ==================================================== visual sub-builders ====

static func _add_environment(root: Node3D) -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.38, 0.64)
	sky_mat.sky_horizon_color = Color(0.76, 0.81, 0.86)
	sky_mat.ground_horizon_color = Color(0.42, 0.46, 0.44)
	sky_mat.ground_bottom_color = Color(0.12, 0.13, 0.12)
	sky_mat.sun_angle_max = 30.0
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.glow_strength = 1.0
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.15

	var we := WorldEnvironment.new()
	we.name = "WorldEnv"
	we.environment = env
	root.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, -34.0, 0.0)
	sun.light_color = Color(1.0, 0.965, 0.89)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 150.0
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.5
	root.add_child(sun)


static func _add_pitch(root: Node3D) -> void:
	# Dark surround under the stands, slightly below the grass (no z-fighting).
	var under := MeshInstance3D.new()
	under.name = "Surround"
	var um := PlaneMesh.new()
	um.size = Vector2(260.0, 220.0)
	under.mesh = um
	var umat := StandardMaterial3D.new()
	umat.albedo_color = Color(0.17, 0.185, 0.17)
	umat.roughness = 1.0
	under.material_override = umat
	under.position = Vector3(0, -0.05, 0)
	under.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(under)

	# Grass plane — markings live in the texture, top surface at y = 0.
	var pitch := MeshInstance3D.new()
	pitch.name = "Pitch"
	var pm := PlaneMesh.new()
	pm.size = Vector2(C.FIELD_LENGTH + GRASS_MARGIN * 2.0,
			C.FIELD_WIDTH + GRASS_MARGIN * 2.0)
	pitch.mesh = pm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_texture = _get_grass_tex()
	gmat.roughness = 1.0
	gmat.metallic_specular = 0.1
	gmat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	pitch.material_override = gmat
	pitch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(pitch)


static func _add_goals(root: Node3D) -> void:
	var home := _build_goal()
	home.name = "GoalHome"
	home.position = Vector3(-C.HALF_LEN, 0, 0)
	root.add_child(home)
	var away := home.duplicate() as Node3D       # shares meshes/materials
	away.name = "GoalAway"
	away.position = Vector3(C.HALF_LEN, 0, 0)
	away.rotation = Vector3(0, PI, 0)
	root.add_child(away)


## Builds one goal at local origin = goal-line center, mouth facing +x.
static func _build_goal() -> Node3D:
	var goal := Node3D.new()
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.96, 0.96, 0.97)
	white.roughness = 0.35

	# Posts: inner faces GOAL_WIDTH apart, tops flush with crossbar top.
	var post_h := C.GOAL_HEIGHT + C.POST_RADIUS * 2.0
	var zoff := C.GOAL_WIDTH * 0.5 + C.POST_RADIUS
	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = C.POST_RADIUS
	post_mesh.bottom_radius = C.POST_RADIUS
	post_mesh.height = post_h
	post_mesh.radial_segments = 12
	for sz: float in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		post.mesh = post_mesh
		post.material_override = white
		post.position = Vector3(0, post_h * 0.5, sz * zoff)
		goal.add_child(post)

	# Crossbar: underside at GOAL_HEIGHT.
	var bar_mesh := CylinderMesh.new()
	bar_mesh.top_radius = C.POST_RADIUS
	bar_mesh.bottom_radius = C.POST_RADIUS
	bar_mesh.height = C.GOAL_WIDTH + C.POST_RADIUS * 4.0
	bar_mesh.radial_segments = 12
	var bar := MeshInstance3D.new()
	bar.mesh = bar_mesh
	bar.material_override = white
	bar.rotation = Vector3(PI * 0.5, 0, 0)
	bar.position = Vector3(0, C.GOAL_HEIGHT + C.POST_RADIUS, 0)
	goal.add_child(bar)

	# Back stanchions holding the net box.
	var stan_mesh := CylinderMesh.new()
	stan_mesh.top_radius = 0.035
	stan_mesh.bottom_radius = 0.035
	stan_mesh.height = C.GOAL_HEIGHT
	stan_mesh.radial_segments = 8
	for sz: float in [-1.0, 1.0]:
		var stan := MeshInstance3D.new()
		stan.mesh = stan_mesh
		stan.material_override = white
		stan.position = Vector3(-C.GOAL_DEPTH, C.GOAL_HEIGHT * 0.5, sz * zoff)
		stan.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		goal.add_child(stan)

	# Net: translucent grid-textured quads (back, two sides, top).
	var net_w := zoff * 2.0
	_net_quad(goal, Vector2(net_w, C.GOAL_HEIGHT),
			Vector3(-C.GOAL_DEPTH, C.GOAL_HEIGHT * 0.5, 0), Vector3(0, PI * 0.5, 0))
	_net_quad(goal, Vector2(C.GOAL_DEPTH, C.GOAL_HEIGHT),
			Vector3(-C.GOAL_DEPTH * 0.5, C.GOAL_HEIGHT * 0.5, -zoff), Vector3.ZERO)
	_net_quad(goal, Vector2(C.GOAL_DEPTH, C.GOAL_HEIGHT),
			Vector3(-C.GOAL_DEPTH * 0.5, C.GOAL_HEIGHT * 0.5, zoff), Vector3.ZERO)
	_net_quad(goal, Vector2(C.GOAL_DEPTH, net_w),
			Vector3(-C.GOAL_DEPTH * 0.5, C.GOAL_HEIGHT, 0), Vector3(-PI * 0.5, 0, 0))
	return goal


static func _net_quad(goal: Node3D, size: Vector2, pos: Vector3, rot: Vector3) -> void:
	var q := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = size
	q.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _get_net_tex()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.uv1_scale = Vector3(size.x / NET_CELL, size.y / NET_CELL, 1.0)
	q.material_override = mat
	q.position = pos
	q.rotation = rot
	q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	goal.add_child(q)


static func _add_ad_boards(root: Node3D) -> void:
	# One-sided quads facing the pitch (back-culled, so they never block the
	# telecam looking over the near board). Leaned back ~10 degrees.
	_add_board(root, Vector3(0, 0.45, -40.0), 0.0, 104.0)
	_add_board(root, Vector3(0, 0.45, 40.0), 180.0, 104.0)
	_add_board(root, Vector3(-58.5, 0.45, 0), 90.0, 76.0)
	_add_board(root, Vector3(58.5, 0.45, 0), -90.0, 76.0)


static func _add_board(root: Node3D, pos: Vector3, yaw_deg: float, length: float) -> void:
	var mi := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(length, 0.9)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _get_ad_tex()
	mat.roughness = 0.6
	mat.emission_enabled = true
	mat.emission = Color(1, 1, 1)
	mat.emission_energy_multiplier = 0.25
	mat.emission_texture = _get_ad_tex()
	mat.uv1_scale = Vector3(length / 30.0, 1.0, 1.0)
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = Vector3(-10.0, yaw_deg, 0.0)   # YXZ: yaw, then lean back
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


static func _add_stands(root: Node3D) -> void:
	# South stand is roofless: the broadcast telecam (~17 m up, ~26 m back on
	# the -z sideline) sits inside it and must see the near touchline.
	_add_stand(root, 96.0, 0.0, Vector3(0, 0, -42.0), false)   # south (camera)
	_add_stand(root, 96.0, 180.0, Vector3(0, 0, 42.0), true)   # north
	_add_stand(root, 64.0, 90.0, Vector3(-60.5, 0, 0), true)   # west, home goal
	_add_stand(root, 64.0, -90.0, Vector3(60.5, 0, 0), true)   # east


## Stand built facing local +z; front face at local z = 0.
static func _add_stand(root: Node3D, length: float, yaw_deg: float, pos: Vector3,
		roofed: bool) -> void:
	var stand := Node3D.new()
	stand.name = "Stand%d" % roundi(yaw_deg)
	stand.position = pos
	stand.rotation_degrees = Vector3(0, yaw_deg, 0)
	root.add_child(stand)

	var struct_mat := StandardMaterial3D.new()
	struct_mat.albedo_color = Color(0.16, 0.17, 0.19)
	struct_mat.roughness = 0.9

	var front := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(length, 2.6, 0.5)
	front.mesh = fm
	front.material_override = struct_mat
	front.position = Vector3(0, 1.3, -0.25)
	front.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stand.add_child(front)

	# Crowd slope: rises 10 m over 16 m of depth, starting atop the front wall.
	var rise := 10.0
	var run := 16.0
	var slope_len := Vector2(run, rise).length()
	var crowd := MeshInstance3D.new()
	var cm := PlaneMesh.new()
	cm.size = Vector2(length, slope_len)
	crowd.mesh = cm
	var cmat := StandardMaterial3D.new()
	cmat.albedo_texture = _get_crowd_tex()
	cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cmat.uv1_scale = Vector3(length / 140.0, 0.7, 1.0)    # ~0.55 m seats, ~0.85 m rows
	crowd.material_override = cmat
	crowd.rotation = Vector3(atan2(rise, run), 0, 0)
	crowd.position = Vector3(0, 2.4 + rise * 0.5, -0.5 - run * 0.5)
	crowd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stand.add_child(crowd)

	var back := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(length, 13.0, 1.5)
	back.mesh = bm
	back.material_override = struct_mat
	back.position = Vector3(0, 6.5, -17.25)
	back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stand.add_child(back)

	if roofed:
		var roof := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(length + 2.0, 0.4, 9.0)
		roof.mesh = rm
		var roof_mat := StandardMaterial3D.new()
		roof_mat.albedo_color = Color(0.55, 0.57, 0.60)
		roof_mat.roughness = 0.5
		roof.material_override = roof_mat
		roof.position = Vector3(0, 13.4, -12.0)
		roof.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		stand.add_child(roof)


static func _add_floodlights(root: Node3D) -> void:
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_add_floodlight(root, Vector3(sx * 62.0, 0, sz * 47.0))


static func _add_floodlight(root: Node3D, base: Vector3) -> void:
	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.4
	pm.bottom_radius = 0.6
	pm.height = 31.0
	pm.radial_segments = 10
	pole.mesh = pm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.45, 0.47, 0.50)
	pmat.roughness = 0.6
	pole.material_override = pmat
	pole.position = base + Vector3(0, 15.5, 0)
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(pole)

	var head := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(4.6, 2.8, 0.6)
	head.mesh = hm
	var hmat := StandardMaterial3D.new()
	hmat.albedo_color = Color(0.92, 0.93, 0.95)
	hmat.emission_enabled = true
	hmat.emission = Color(1.0, 0.98, 0.92)
	hmat.emission_energy_multiplier = 3.0
	head.material_override = hmat
	var hp := base + Vector3(0, 31.5, 0)
	head.basis = Basis.looking_at((Vector3(0, 0, 0) - hp).normalized(), Vector3.UP)
	head.position = hp
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)


# ================================================== collision helpers ====

static func _static_body(parent: Node3D, body_name: String, pm: PhysicsMaterial) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.physics_material_override = pm
	parent.add_child(body)
	return body


static func _add_box_shape(body: StaticBody3D, pos: Vector3, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position = pos
	body.add_child(cs)


static func _add_cylinder_shape(body: StaticBody3D, pos: Vector3, radius: float,
		height: float, along_z: bool) -> void:
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	cs.shape = cyl
	cs.position = pos
	if along_z:
		cs.rotation = Vector3(PI * 0.5, 0, 0)
	body.add_child(cs)


# ======================================================= grass texture ====

static func _gx(x: float) -> float:
	return (x + C.HALF_LEN + GRASS_MARGIN) * PPM


static func _gz(z: float) -> float:
	return (z + C.HALF_WID + GRASS_MARGIN) * PPM


## Fills an axis-aligned world-space rect [x0,z0]..[x1,z1] (meters) on the image.
static func _wrect(img: Image, x0: float, z0: float, x1: float, z1: float, col: Color) -> void:
	var px0 := floori(_gx(x0))
	var py0 := floori(_gz(z0))
	var px1 := ceili(_gx(x1))
	var py1 := ceili(_gz(z1))
	img.fill_rect(Rect2i(px0, py0, maxi(px1 - px0, 1), maxi(py1 - py0, 1)), col)


## Strokes an arc (angles in field plane: x = cos, z = sin) with square stamps.
static func _stroke_arc(img: Image, cx: float, cz: float, radius: float,
		a0: float, a1: float, col: Color) -> void:
	var stamp := maxi(ceili(C.LINE_WIDTH * PPM), 2)
	var step := (C.LINE_WIDTH * 0.45) / radius
	var a := a0
	while a < a1:
		var px := roundi(_gx(cx + cos(a) * radius) - stamp * 0.5)
		var py := roundi(_gz(cz + sin(a) * radius) - stamp * 0.5)
		img.fill_rect(Rect2i(px, py, stamp, stamp), col)
		a += step


static func _fill_circle(img: Image, cx: float, cz: float, r: float, col: Color) -> void:
	var cpx := _gx(cx)
	var cpz := _gz(cz)
	var rp := maxf(r * PPM, 1.5)
	for py in range(int(cpz - rp) - 1, int(cpz + rp) + 2):
		for px in range(int(cpx - rp) - 1, int(cpx + rp) + 2):
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			var dx := px + 0.5 - cpx
			var dy := py + 0.5 - cpz
			if dx * dx + dy * dy <= rp * rp:
				img.set_pixel(px, py, col)


## Mowing stripes: bands along x, globally aligned so apron and pitch line up.
static func _fill_stripes(img: Image, x0: float, z0: float, x1: float, z1: float,
		col_a: Color, col_b: Color) -> void:
	var k0 := floori(x0 / STRIPE_W)
	var k1 := ceili(x1 / STRIPE_W)
	for k in range(k0, k1):
		var sx0 := maxf(x0, k * STRIPE_W)
		var sx1 := minf(x1, (k + 1) * STRIPE_W)
		if sx1 <= sx0:
			continue
		_wrect(img, sx0, z0, sx1, z1, col_a if k % 2 == 0 else col_b)


static func _wear_patch(img: Image, cx: float, cz: float, rx: float, rz: float,
		count: int, rng: RandomNumberGenerator) -> void:
	var dirt := Color(0.43, 0.36, 0.22)
	for i in count:
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf())
		var px := int(_gx(cx + cos(ang) * rx * rad))
		var py := int(_gz(cz + sin(ang) * rz * rad))
		if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
			continue
		var c := img.get_pixel(px, py)
		img.set_pixel(px, py, c.lerp(dirt, rng.randf_range(0.18, 0.5)))


static func _get_grass_tex() -> ImageTexture:
	if _grass_tex != null:
		return _grass_tex
	var w := int((C.FIELD_LENGTH + GRASS_MARGIN * 2.0) * PPM)
	var h := int((C.FIELD_WIDTH + GRASS_MARGIN * 2.0) * PPM)
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260611   # deterministic look

	# Apron (darker mow) over the whole sheet, brighter mow inside the lines.
	_fill_stripes(img, -C.HALF_LEN - GRASS_MARGIN, -C.HALF_WID - GRASS_MARGIN,
			C.HALF_LEN + GRASS_MARGIN, C.HALF_WID + GRASS_MARGIN,
			Color(0.205, 0.395, 0.165), Color(0.185, 0.360, 0.150))
	_fill_stripes(img, -C.HALF_LEN, -C.HALF_WID, C.HALF_LEN, C.HALF_WID,
			Color(0.270, 0.520, 0.205), Color(0.232, 0.462, 0.180))

	# Worn turf: center circle, penalty spots, goalmouths.
	_wear_patch(img, 0.0, 0.0, 3.2, 3.2, 2600, rng)
	for s: float in [-1.0, 1.0]:
		_wear_patch(img, s * (C.HALF_LEN - C.PENALTY_SPOT), 0.0, 2.2, 2.2, 1600, rng)
		_wear_patch(img, s * (C.HALF_LEN - 2.5), 0.0, 3.0, 5.0, 3200, rng)

	# Grain noise (under the lines, so markings stay crisp).
	for i in 90000:
		var px := rng.randi_range(0, w - 1)
		var py := rng.randi_range(0, h - 1)
		var c := img.get_pixel(px, py)
		var f := rng.randf_range(0.90, 1.10)
		img.set_pixel(px, py, Color(c.r * f, c.g * f, c.b * f))

	_paint_markings(img)
	img.generate_mipmaps()
	_grass_tex = ImageTexture.create_from_image(img)
	return _grass_tex


## All standard markings, FIFA edge-alignment: boundary lines lie inside the
## area they bound; circle radii are measured to the outside of the line.
static func _paint_markings(img: Image) -> void:
	var lw := C.LINE_WIDTH
	var hl := C.HALF_LEN
	var hw := C.HALF_WID
	var white := PITCH_WHITE

	# Touch lines and goal lines.
	_wrect(img, -hl, -hw, hl, -hw + lw, white)
	_wrect(img, -hl, hw - lw, hl, hw, white)
	_wrect(img, -hl, -hw, -hl + lw, hw, white)
	_wrect(img, hl - lw, -hw, hl, hw, white)

	# Halfway line (centered on x = 0), center circle, center mark.
	_wrect(img, -lw * 0.5, -hw, lw * 0.5, hw, white)
	_stroke_arc(img, 0.0, 0.0, C.CENTER_CIRCLE_R - lw * 0.5, 0.0, TAU, white)
	_fill_circle(img, 0.0, 0.0, 0.2, white)

	for s: float in [-1.0, 1.0]:
		var gl := s * hl
		# Penalty area.
		var pfx := s * (hl - C.PENALTY_BOX_DEPTH)
		var phw := C.PENALTY_BOX_WIDTH * 0.5
		_wrect(img, minf(gl, pfx), -phw, maxf(gl, pfx), -phw + lw, white)
		_wrect(img, minf(gl, pfx), phw - lw, maxf(gl, pfx), phw, white)
		_wrect(img, minf(pfx, pfx + s * lw), -phw, maxf(pfx, pfx + s * lw), phw, white)
		# Goal area (six-yard box).
		var sfx := s * (hl - C.SIX_BOX_DEPTH)
		var shw := C.SIX_BOX_WIDTH * 0.5
		_wrect(img, minf(gl, sfx), -shw, maxf(gl, sfx), -shw + lw, white)
		_wrect(img, minf(gl, sfx), shw - lw, maxf(gl, sfx), shw, white)
		_wrect(img, minf(sfx, sfx + s * lw), -shw, maxf(sfx, sfx + s * lw), shw, white)
		# Penalty mark + arc: the part of the 9.15 m circle around the mark
		# that lies outside the penalty area.
		var spot_x := s * (hl - C.PENALTY_SPOT)
		_fill_circle(img, spot_x, 0.0, 0.2, white)
		var a_lim := acos((C.PENALTY_BOX_DEPTH - C.PENALTY_SPOT) / C.CENTER_CIRCLE_R)
		var base := 0.0 if s < 0.0 else PI
		_stroke_arc(img, spot_x, 0.0, C.CENTER_CIRCLE_R - lw * 0.5,
				base - a_lim, base + a_lim, white)

	# Corner arcs (quarter circles, inside the field).
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var a0 := atan2(-sz, -sx)             # direction into the field
			_stroke_arc(img, sx * hl, sz * hw, C.CORNER_ARC_R - lw * 0.5,
					a0 - PI * 0.25, a0 + PI * 0.25, white)


# ====================================================== other textures ====

static func _get_crowd_tex() -> ImageTexture:
	if _crowd_tex != null:
		return _crowd_tex
	var w := 512
	var h := 256
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	img.fill(Color(0.10, 0.10, 0.12))
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var palette: Array[Color] = [
		Color(0.75, 0.16, 0.16), Color(0.16, 0.25, 0.70), Color(0.92, 0.90, 0.86),
		Color(0.15, 0.15, 0.18), Color(0.85, 0.75, 0.25), Color(0.20, 0.55, 0.30),
		Color(0.85, 0.45, 0.15),
	]
	for row in range(0, h, 8):
		img.fill_rect(Rect2i(0, row, w, 2), Color(0.16, 0.16, 0.18))  # row step
		var x := 0
		while x < w:
			if x % 64 >= 60:                                          # aisles
				img.fill_rect(Rect2i(x, row + 2, 2, 6), Color(0.14, 0.14, 0.16))
			else:
				var col: Color
				if rng.randf() < 0.45:
					col = palette[rng.randi_range(0, palette.size() - 1)].darkened(rng.randf_range(0.0, 0.35))
				else:
					col = Color.from_hsv(rng.randf(), rng.randf_range(0.10, 0.50),
							rng.randf_range(0.22, 0.68))
				img.fill_rect(Rect2i(x, row + 2, 2, 6), col)
			x += 2
	img.generate_mipmaps()
	_crowd_tex = ImageTexture.create_from_image(img)
	return _crowd_tex


static func _get_net_tex() -> ImageTexture:
	if _net_tex != null:
		return _net_tex
	var img := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var cord := Color(0.93, 0.95, 0.97, 0.78)
	for k in range(0, 64, 8):
		img.fill_rect(Rect2i(0, k, 64, 2), cord)
		img.fill_rect(Rect2i(k, 0, 2, 64), cord)
	img.generate_mipmaps()
	_net_tex = ImageTexture.create_from_image(img)
	return _net_tex


static func _get_ad_tex() -> ImageTexture:
	if _ad_tex != null:
		return _ad_tex
	var w := 1024
	var img := Image.create_empty(w, 64, false, Image.FORMAT_RGB8)
	img.fill(Color(0.95, 0.95, 0.95))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var cols: Array[Color] = [
		Color(0.85, 0.15, 0.20), Color(0.10, 0.35, 0.80), Color(0.95, 0.80, 0.10),
		Color(0.05, 0.60, 0.45), Color(0.15, 0.15, 0.20), Color(0.90, 0.45, 0.10),
	]
	var x := 0
	while x < w:
		var bw := rng.randi_range(90, 180)
		var col := cols[rng.randi_range(0, cols.size() - 1)]
		img.fill_rect(Rect2i(x, 4, mini(bw, w - x), 56), col)
		img.fill_rect(Rect2i(x, 34, mini(bw, w - x), 6), col.lightened(0.35))
		x += bw + 6
	img.generate_mipmaps()
	_ad_tex = ImageTexture.create_from_image(img)
	return _ad_tex


static func _get_ball_tex() -> ImageTexture:
	if _ball_tex != null:
		return _ball_tex
	var w := 192
	var h := 96
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	# 12 black pentagon-ish patches at icosahedron vertex directions.
	var g := (1.0 + sqrt(5.0)) * 0.5
	var dirs: Array[Vector3] = []
	for v: Vector3 in [
			Vector3(-1, g, 0), Vector3(1, g, 0), Vector3(-1, -g, 0), Vector3(1, -g, 0),
			Vector3(0, -1, g), Vector3(0, 1, g), Vector3(0, -1, -g), Vector3(0, 1, -g),
			Vector3(g, 0, -1), Vector3(g, 0, 1), Vector3(-g, 0, -1), Vector3(-g, 0, 1)]:
		dirs.append(v.normalized())
	var cos_patch := cos(0.36)
	var cos_edge := cos(0.405)
	var white := Color(0.94, 0.94, 0.95)
	var seam := Color(0.62, 0.62, 0.64)
	var black := Color(0.07, 0.07, 0.08)
	for j in h:
		var th := PI * (j + 0.5) / h
		var st := sin(th)
		var ct := cos(th)
		for i in w:
			var ph := TAU * (i + 0.5) / w
			var d := Vector3(st * cos(ph), ct, st * sin(ph))
			var best := -1.0
			for k in 12:
				var dd := d.dot(dirs[k])
				if dd > best:
					best = dd
			var col := white
			if best > cos_patch:
				col = black
			elif best > cos_edge:
				col = seam
			img.set_pixel(i, j, col)
	img.generate_mipmaps()
	_ball_tex = ImageTexture.create_from_image(img)
	return _ball_tex

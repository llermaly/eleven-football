extends Node
## Entry point. Decides server vs client at boot.
## Server: builds the simulation world and runs forever (optionally --smoke=N).
## Client: menu -> connect -> build visual world, send inputs, render snapshots.
##
## Useful args (after "--"):
##   --server              run dedicated server
##   --smoke=N             server: simulate N seconds, print stats JSON, exit
##   --timescale=X         server: speed up simulation (smoke testing)
##   --connect=ws://...    client: skip menu, autoconnect
##   --name=Foo            client: player name for autoconnect
##   --screenshot-dir=DIR  client: save a screenshot every 2 s (visual QA)

var menu: GameMenu = null
var hud: Hud = null
var cam: CameraRig = null
var sfx: Sfx = null
var world: Node3D = null
var ball_node: Node3D = null
var visuals: Array[PlayerVisual] = []
var in_match := false

var _mgr: MatchManager = null
var _args := {}
var _charge := -1.0
var _aim := Vector2(1, 0)
var _input_tick := 0
var _smoke_elapsed := 0.0
var _shot_timer := 0.0
var _last_my_idx := -1


func _ready() -> void:
	_args = _parse_args()
	var dedicated: bool = OS.has_feature("dedicated_server") \
		or DisplayServer.get_name() == "headless" or _args.has("server")
	if dedicated:
		_start_server()
	else:
		_start_client()


func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var eq := a.find("=")
			if eq > 0:
				out[a.substr(2, eq - 2)] = a.substr(eq + 1)
			else:
				out[a.substr(2)] = true
	return out


# ---------------------------------------------------------------- server

func _start_server() -> void:
	if Net.start_server() != OK:
		get_tree().quit(1)
		return
	var sim := Node3D.new()
	sim.name = "SimWorld"
	add_child(sim)
	_mgr = MatchManager.new()
	_mgr.name = "MatchManager"
	add_child(_mgr)
	_mgr.setup(sim)
	Net.attach_manager(_mgr)
	if _args.has("timescale"):
		Engine.time_scale = float(_args["timescale"])
	print("[server] match running — phase %d, %d players" % [_mgr.phase, _mgr.players.size()])


func _process(delta: float) -> void:
	if _mgr != null and _args.has("smoke"):
		_smoke_elapsed += delta
		if int(_smoke_elapsed / 5.0) != int((_smoke_elapsed - delta) / 5.0):
			var bp := _mgr.ball.global_position
			print("[trace] t=%5.1f phase=%d poss=%d ball=(%6.1f,%5.2f,%6.1f) score=%d-%d"
				% [_smoke_elapsed, _mgr.phase, _mgr.possession_idx,
				bp.x, bp.y, bp.z, _mgr.score[0], _mgr.score[1]])
		if _smoke_elapsed >= float(_args["smoke"]):
			_finish_smoke()
		return
	if in_match:
		_render_frame(delta)


func _finish_smoke() -> void:
	var bp := _mgr.ball.global_position
	var result := {
		"sim_seconds": _smoke_elapsed,
		"stats": _mgr.stats,
		"score": _mgr.score,
		"phase": _mgr.phase,
		"clock": _mgr.clock,
		"ball": [snappedf(bp.x, 0.01), snappedf(bp.y, 0.01), snappedf(bp.z, 0.01)],
	}
	print("SMOKE_RESULT " + JSON.stringify(result))
	var ok: bool = _mgr.stats["kicks"] >= 5 and _mgr.clock > 1.0 \
		and absf(bp.x) < 90.0 and absf(bp.z) < 70.0
	get_tree().quit(0 if ok else 2)


# ---------------------------------------------------------------- client

func _start_client() -> void:
	_register_inputs()
	menu = GameMenu.new()
	add_child(menu)
	menu.join_pressed.connect(_on_join_pressed)
	Net.status_changed.connect(func(t: String) -> void:
		if menu != null:
			menu.set_status(t))
	Net.joined.connect(_on_joined)
	Net.connection_lost.connect(_on_connection_lost)
	Net.game_event.connect(_on_game_event)
	MatchState.score_changed.connect(func(h: int, a: int) -> void:
		if hud != null:
			hud.set_score(h, a))
	MatchState.big_message.connect(func(t: String, s: float) -> void:
		if hud != null:
			hud.show_message(t, s))
	MatchState.roster_message.connect(func(t: String) -> void:
		if hud != null:
			hud.set_status(t))
	MatchState.control_changed.connect(_on_control_changed)
	MatchState.phase_changed.connect(_on_phase_changed)
	if _args.has("connect"):
		var pname: String = str(_args.get("name", "Tester%d" % (randi() % 100)))
		Net.connect_to(str(_args["connect"]), pname)
	elif OS.has_feature("web"):
		# ?join=Name in the URL skips the menu — handy for shared links.
		var jn = JavaScriptBridge.eval(
			"(new URLSearchParams(window.location.search)).get('join') || ''", true)
		if jn is String and not (jn as String).is_empty():
			menu.set_busy(true)
			Net.connect_to(_resolve_url(""), jn)
	if _args.has("screenshot-dir"):
		var t := Timer.new()
		t.wait_time = 2.0
		t.autostart = true
		t.timeout.connect(_save_screenshot)
		add_child(t)


func _on_join_pressed(pname: String, url: String) -> void:
	menu.set_busy(true)
	Net.connect_to(_resolve_url(url), pname)


func _resolve_url(menu_url: String) -> String:
	if OS.has_feature("web"):
		var js := "(new URLSearchParams(window.location.search)).get('ws') || " \
			+ "((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws')"
		var url = JavaScriptBridge.eval(js, true)
		if url is String and not (url as String).is_empty():
			return url
		return "ws://127.0.0.1:9080"
	return menu_url if not menu_url.strip_edges().is_empty() else C.DEFAULT_WS_URL


func _on_joined(team: int, _idx: int) -> void:
	in_match = true
	menu.set_busy(false)
	menu.visible = false
	world = Node3D.new()
	world.name = "World"
	add_child(world)
	WorldBuilder.build_visual_world(world)
	ball_node = WorldBuilder.build_ball_visual(world)
	visuals.clear()
	for i in 22:
		var t := i / 11
		var e: Dictionary = C.FORMATION[i % 11]
		var pv := PlayerVisual.new()
		world.add_child(pv)
		pv.setup(t, e["num"], C.SQUAD_NAMES[t][(e["num"] - 1) % 11],
			e["role"] == C.Role.GK)
		visuals.append(pv)
	cam = CameraRig.new()
	cam.setup(world)
	hud = Hud.new()
	add_child(hud)
	hud.set_teams(C.TEAM_NAMES[0], C.TEAM_NAMES[1],
		C.KITS[0]["shirt"], C.KITS[1]["shirt"])
	hud.set_score(MatchState.score[0], MatchState.score[1])
	hud.set_status("You are %s — %s" % [C.TEAM_NAMES[team],
		"HOME" if team == 0 else "AWAY"])
	hud.set_hint("WASD move · SHIFT sprint · SPACE shoot (hold) · E pass · Q lob · F slide · C switch · R rematch")
	sfx = Sfx.new()
	add_child(sfx)
	sfx.start_crowd()
	_on_control_changed(MatchState.my_idx)


func _teardown_match() -> void:
	in_match = false
	for n in [world, hud, sfx]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	world = null
	hud = null
	cam = null
	sfx = null
	ball_node = null
	visuals.clear()


func _on_connection_lost() -> void:
	_teardown_match()
	menu.visible = true
	menu.set_busy(false)
	menu.set_status("Disconnected from server.")


func _on_control_changed(my_idx: int) -> void:
	_last_my_idx = my_idx
	for i in visuals.size():
		var mine := i == my_idx
		var col: Color = C.KITS[Net.my_team]["shirt"] if Net.my_team >= 0 else Color.WHITE
		visuals[i].set_highlight(mine, Color(1, 1, 1) if not mine else col.lightened(0.4))


func _on_phase_changed(phase: int) -> void:
	if cam == null:
		return
	if phase != C.Phase.GOAL_CELEBRATION:
		cam.normal_mode()


func _on_game_event(kind: int, data: Dictionary) -> void:
	if sfx == null:
		return
	match kind:
		C.Event.KICK_SFX:
			sfx.play_kick(clampf(float(data.get("s", 10.0)) / 33.0, 0.1, 1.0))
		C.Event.BOUNCE:
			sfx.play_bounce(clampf(float(data.get("s", 5.0)) / 20.0, 0.05, 1.0))
		C.Event.WHISTLE:
			sfx.play_whistle(int(data.get("k", 0)))
		C.Event.GOAL:
			sfx.play_cheer()
			if cam != null and ball_node != null:
				cam.goal_mode(ball_node.global_position)


func _render_frame(delta: float) -> void:
	var state := Net.buffer.sample()
	if state.is_empty():
		return
	ball_node.position = state["ball_pos"]
	ball_node.quaternion = state["ball_quat"]
	var pdata: Array = state["players"]
	for i in 22:
		var pd: Dictionary = pdata[i]
		visuals[i].position = pd["pos"]
		visuals[i].apply_state(pd["yaw"], pd["speed"], pd["anim"], pd["anim_t"])
	cam.track(state["ball_pos"], state["ball_vel"], delta)
	hud.set_clock(state["clock"], MatchState.half)
	hud.set_charge(_charge)


func _physics_process(delta: float) -> void:
	if not in_match:
		return
	# Gather camera-relative input -> world-space move vector.
	var raw := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var move := Vector2.ZERO
	var camera := get_viewport().get_camera_3d()
	if camera != null and raw.length() > 0.01:
		var basis := camera.global_transform.basis
		var right := Vector3(basis.x.x, 0.0, basis.x.z).normalized()
		var fwd := Vector3(-basis.z.x, 0.0, -basis.z.z).normalized()
		var world_dir := right * raw.x + fwd * -raw.y
		move = Vector2(world_dir.x, world_dir.z).limit_length(1.0)
	if move.length() > 0.15:
		_aim = move.normalized()

	# Shot charging.
	if Input.is_action_just_pressed("shoot"):
		_charge = 0.0
	if _charge >= 0.0 and Input.is_action_pressed("shoot"):
		_charge = minf(_charge + delta / C.SHOT_CHARGE_TIME, 1.0)
	if _charge >= 0.0 and Input.is_action_just_released("shoot"):
		Net.send_action(C.Action.SHOOT, maxf(_charge, 0.15), _aim)
		_charge = -1.0

	if Input.is_action_just_pressed("pass_ball"):
		Net.send_action(C.Action.PASS, 0.5, _aim)
	if Input.is_action_just_pressed("lob"):
		Net.send_action(C.Action.LOB, 0.7, _aim)
	if Input.is_action_just_pressed("tackle"):
		Net.send_action(C.Action.TACKLE, 1.0, _aim)
	if Input.is_action_just_pressed("switch_player"):
		Net.send_action(C.Action.SWITCH, 0.0, Vector2.ZERO)
	if Input.is_action_just_pressed("rematch"):
		Net.send_action(C.Action.RESET, 0.0, Vector2.ZERO)

	_input_tick += 1
	if _input_tick % C.INPUT_EVERY_N_TICKS == 0:
		var buttons := 0
		if Input.is_action_pressed("sprint"):
			buttons |= C.BTN_SPRINT
		if _charge >= 0.0:
			buttons |= C.BTN_CHARGE
		Net.send_input(move, buttons)


func _register_inputs() -> void:
	var bindings := {
		"move_up": [KEY_W, KEY_UP],
		"move_down": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"sprint": [KEY_SHIFT],
		"shoot": [KEY_SPACE],
		"pass_ball": [KEY_E],
		"lob": [KEY_Q],
		"tackle": [KEY_F],
		"switch_player": [KEY_C],
		"rematch": [KEY_R],
	}
	for action in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in bindings[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)


func _save_screenshot() -> void:
	var dir := str(_args["screenshot-dir"])
	DirAccess.make_dir_recursive_absolute(dir)
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/shot_%d.png" % [dir, Time.get_ticks_msec()])

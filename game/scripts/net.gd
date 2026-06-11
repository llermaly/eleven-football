extends Node
## Autoload "Net" — WebSocket multiplayer. Server: accepts clients, applies
## their inputs to possessed players, broadcasts world snapshots at 20 Hz.
## Client: connects, sends inputs, surfaces snapshots/events via signals.

signal status_changed(text: String)
signal joined(team: int, idx: int)
signal connection_lost
signal game_event(kind: int, data: Dictionary)

var is_server := false
var mgr: MatchManager = null
var humans: Dictionary = {}          # peer_id -> {name, team, idx}
var buffer: SnapshotBuffer = SnapshotBuffer.new()
var my_team := -1
var my_idx := -1

var _tick := 0
var _next_team := 0
var _pending_name := ""


# ---------------------------------------------------------------- server

func start_server() -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(C.SERVER_PORT)
	if err != OK:
		push_error("Failed to listen on port %d: %s" % [C.SERVER_PORT, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	is_server = true
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[server] listening on :%d" % C.SERVER_PORT)
	return OK


func attach_manager(m: MatchManager) -> void:
	mgr = m
	m.sfx_kick.connect(func(s: float) -> void:
		_broadcast_event(C.Event.KICK_SFX, { "s": s }))
	m.sfx_bounce.connect(func(s: float) -> void:
		_broadcast_event(C.Event.BOUNCE, { "s": s }))
	m.sfx_whistle.connect(func(kind: int) -> void:
		_broadcast_event(C.Event.WHISTLE, { "k": kind }))
	m.goal_scored.connect(func(team: int, scorer: String) -> void:
		_broadcast_event(C.Event.GOAL, { "team": team, "scorer": scorer }))
	m.restart_set.connect(func(kind: int, team: int) -> void:
		_broadcast_event(C.Event.RESTART_INFO, { "kind": kind, "team": team }))


func _on_peer_connected(id: int) -> void:
	print("[server] peer %d connected" % id)


func _on_peer_disconnected(id: int) -> void:
	print("[server] peer %d disconnected" % id)
	if humans.has(id):
		var idx: int = humans[id]["idx"]
		if idx >= 0 and mgr != null:
			mgr.players[idx].control_peer = 0
			mgr.players[idx].input_move = Vector2.ZERO
			mgr.players[idx].input_buttons = 0
		var pname: String = humans[id]["name"]
		humans.erase(id)
		_sync_control_map()
		MatchState.server_roster_note("%s left" % pname)


func _physics_process(_delta: float) -> void:
	if not is_server or mgr == null:
		return
	_tick += 1
	if _tick % C.SNAPSHOT_EVERY_N_TICKS != 0:
		return
	if multiplayer.get_peers().is_empty():
		return
	_snapshot.rpc(_tick, _build_snapshot())


func _build_snapshot() -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.resize(SnapshotBuffer.PLAYER0 + 22 * SnapshotBuffer.PLAYER_FLOATS)
	arr[0] = float(_tick)
	arr[1] = float(mgr.phase)
	arr[2] = mgr.clock
	arr[3] = float(mgr.possession_idx)
	var b := mgr.ball
	var bp := b.global_position
	var bv := b.linear_velocity
	var bq := b.global_transform.basis.get_rotation_quaternion()
	var bw := b.angular_velocity
	var vals := [bp.x, bp.y, bp.z, bv.x, bv.y, bv.z, bq.x, bq.y, bq.z, bq.w,
		bw.x, bw.y, bw.z]
	for i in vals.size():
		arr[4 + i] = vals[i]
	for i in 22:
		var p := mgr.players[i]
		var o := SnapshotBuffer.PLAYER0 + i * SnapshotBuffer.PLAYER_FLOATS
		var pp := p.global_position
		arr[o] = pp.x
		arr[o + 1] = pp.y
		arr[o + 2] = pp.z
		arr[o + 3] = p.yaw()
		arr[o + 4] = Vector2(p.velocity.x, p.velocity.z).length()
		arr[o + 5] = float(p.anim)
		arr[o + 6] = p.anim_t
	return arr


func _broadcast_event(kind: int, data: Dictionary) -> void:
	if multiplayer.get_peers().is_empty():
		return
	_event.rpc(kind, data)


func assign_control(peer: int, idx: int) -> void:
	if not humans.has(peer) or mgr == null:
		return
	var old: int = humans[peer]["idx"]
	if old == idx:
		return
	var cur: int = mgr.players[idx].control_peer
	if cur != 0 and cur != peer and humans.has(cur):
		return   # body already possessed by another live human — never steal
	if old >= 0:
		mgr.players[old].control_peer = 0
	var p := mgr.players[idx]
	p.control_peer = peer
	p.input_move = mgr.players[old].input_move if old >= 0 else Vector2.ZERO
	humans[peer]["idx"] = idx
	_sync_control_map()


func switch_control(peer: int) -> void:
	if not humans.has(peer) or mgr == null:
		return
	var team: int = humans[peer]["team"]
	var current: int = humans[peer]["idx"]
	var bp := mgr.ball.global_position
	var best := -1
	var best_d := INF
	for p in mgr.players:
		if p.team != team or p.idx == current:
			continue
		if p.is_human():
			continue
		if p.is_keeper and mgr.possession_idx != p.idx:
			continue
		var d := p.global_position.distance_to(bp)
		if d < best_d:
			best_d = d
			best = p.idx
	if best >= 0:
		assign_control(peer, best)


func maybe_control_taker(team: int, taker_idx: int) -> void:
	if taker_idx < 0 or mgr == null:
		return
	if mgr.players[taker_idx].is_human():
		return   # taker already human-controlled; leave it
	for peer in humans:
		if humans[peer]["team"] == team:
			assign_control(peer, taker_idx)
			return


func _sync_control_map() -> void:
	var map := {}
	for peer in humans:
		map[peer] = humans[peer]["idx"]
	MatchState.server_set_control(map)


# ---------------------------------------------------------------- client

func connect_to(url: String, pname: String) -> void:
	buffer = SnapshotBuffer.new()   # drop stale snapshots from any prior session
	_pending_name = pname
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		connection_lost.emit()
		status_changed.emit("Could not start connection: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	status_changed.emit("Connecting to %s ..." % url)
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
	if not multiplayer.connection_failed.is_connected(_on_conn_failed):
		multiplayer.connection_failed.connect(_on_conn_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_lost):
		multiplayer.server_disconnected.connect(_on_server_lost)


func _on_connected() -> void:
	status_changed.emit("Connected — joining match ...")
	_hello.rpc_id(1, _pending_name)


func _on_conn_failed() -> void:
	multiplayer.multiplayer_peer = null
	connection_lost.emit()
	status_changed.emit("Connection failed. Is the server reachable?")


func _on_server_lost() -> void:
	multiplayer.multiplayer_peer = null
	connection_lost.emit()


func send_input(move: Vector2, buttons: int) -> void:
	if multiplayer.multiplayer_peer != null and not is_server:
		_submit_input.rpc_id(1, move, buttons)


func send_action(kind: int, power: float, aim: Vector2) -> void:
	if multiplayer.multiplayer_peer != null and not is_server:
		_action.rpc_id(1, kind, power, aim)


# ---------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func _hello(pname: String) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if humans.has(sender):
		return
	pname = pname.strip_edges().substr(0, 16)
	if pname.is_empty():
		pname = "Player%d" % (sender % 1000)
	var team := _next_team
	_next_team = 1 - _next_team
	var idx := _pick_start_player(team)
	humans[sender] = { "name": pname, "team": team, "idx": -1 }
	if idx >= 0:
		assign_control(sender, idx)
	_welcome.rpc_id(sender, team, humans[sender]["idx"],
		mgr.score[0], mgr.score[1], mgr.half)
	_sync_control_map()
	MatchState.server_roster_note("%s joined %s" % [pname, C.TEAM_NAMES[team]])
	print("[server] %s joined as team %d player %d" % [pname, team, idx])


func _pick_start_player(team: int) -> int:
	var base := team * 11
	for slot in [9, 10, 6, 7, 5, 8, 1, 2, 3, 4]:
		var p := mgr.players[base + slot]
		if not p.is_human():
			return p.idx
	return -1


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _submit_input(move: Vector2, buttons: int) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not humans.has(sender):
		return
	var idx: int = humans[sender]["idx"]
	if idx < 0 or not move.is_finite():
		return
	var p := mgr.players[idx]
	p.input_move = move.limit_length(1.0)
	p.input_buttons = buttons


@rpc("any_peer", "call_remote", "reliable")
func _action(kind: int, power: float, aim: Vector2) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not humans.has(sender):
		return
	if kind == C.Action.SWITCH:
		switch_control(sender)
		return
	if kind == C.Action.RESET:
		mgr.request_reset(humans[sender]["name"])
		return
	if not (is_finite(power) and aim.is_finite()):
		return
	var idx: int = humans[sender]["idx"]
	if idx >= 0:
		mgr.players[idx].queue_action(kind, power, aim.limit_length(1.0))


@rpc("authority", "call_remote", "reliable")
func _welcome(team: int, idx: int, score_h: int, score_a: int, half: int) -> void:
	my_team = team
	my_idx = idx
	MatchState.score = [score_h, score_a]
	MatchState.half = half
	joined.emit(team, idx)


@rpc("authority", "call_remote", "unreliable_ordered")
func _snapshot(tick: int, data: PackedFloat32Array) -> void:
	buffer.push(tick, data)


@rpc("authority", "call_remote", "reliable")
func _event(kind: int, data: Dictionary) -> void:
	game_event.emit(kind, data)

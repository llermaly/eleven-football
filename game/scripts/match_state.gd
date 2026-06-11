extends Node
## Autoload "MatchState" — replicated scoreboard/lobby state. The server is
## the only writer (via server_* methods); clients receive RPCs and emit
## signals the UI listens to. Exists at the same node path on every peer.

signal score_changed(home: int, away: int)
signal phase_changed(phase: int)
signal big_message(text: String, seconds: float)
signal control_changed(my_idx: int)
signal roster_message(text: String)

var phase: int = C.Phase.LOBBY
var score: Array[int] = [0, 0]
var half: int = 1
var control_map: Dictionary = {}      # peer_id -> player idx
var my_idx: int = -1                  # client: which player I control


func server_set_score(h: int, a: int) -> void:
	_sync_score.rpc(h, a)


func server_set_phase(p_phase: int, p_half: int) -> void:
	_sync_phase.rpc(p_phase, p_half)


func server_message(text: String, seconds: float) -> void:
	_sync_message.rpc(text, seconds)


func server_set_control(map: Dictionary) -> void:
	_sync_control.rpc(map)


func server_roster_note(text: String) -> void:
	_sync_roster_note.rpc(text)


@rpc("authority", "call_local", "reliable")
func _sync_score(h: int, a: int) -> void:
	score = [h, a]
	score_changed.emit(h, a)


@rpc("authority", "call_local", "reliable")
func _sync_phase(p_phase: int, p_half: int) -> void:
	phase = p_phase
	half = p_half
	phase_changed.emit(p_phase)


@rpc("authority", "call_local", "reliable")
func _sync_message(text: String, seconds: float) -> void:
	big_message.emit(text, seconds)


@rpc("authority", "call_local", "reliable")
func _sync_control(map: Dictionary) -> void:
	control_map = map
	var me := multiplayer.get_unique_id()
	my_idx = map.get(me, map.get(str(me), -1))
	control_changed.emit(my_idx)


@rpc("authority", "call_local", "reliable")
func _sync_roster_note(text: String) -> void:
	roster_message.emit(text)

class_name SnapshotBuffer
extends RefCounted
## Client-side snapshot interpolation. Stores decoded server snapshots and
## samples a smooth world state C.INTERP_DELAY behind the newest server time.
##
## Wire format (PackedFloat32Array), see net.gd:
##   [0] tick  [1] phase  [2] clock  [3] possession_idx
##   [4..16]  ball: px py pz vx vy vz qx qy qz qw wx wy wz
##   [17 + i*7 ..] player i: px py pz yaw speed anim anim_t

const HEADER := 4
const BALL_FLOATS := 13
const PLAYER_FLOATS := 7
const PLAYER0 := HEADER + BALL_FLOATS

var _snaps: Array[Dictionary] = []   # {t: float (server seconds), d: PackedFloat32Array}
var _server_time_offset := 0.0       # smoothed: server_time - local_time
var _has_offset := false


func push(tick: int, data: PackedFloat32Array) -> void:
	if data.size() < PLAYER0 + 22 * PLAYER_FLOATS:
		return
	var server_t := float(tick) / 60.0   # 64-bit: exact for any uptime
	var local_t := _now()
	var offset := server_t - local_t
	if not _has_offset:
		_server_time_offset = offset
		_has_offset = true
	else:
		# Slew slowly; jump if wildly off (reconnect, big stall).
		if absf(offset - _server_time_offset) > 1.0:
			_server_time_offset = offset
		else:
			_server_time_offset = lerpf(_server_time_offset, offset, 0.05)
	_snaps.append({ "t": server_t, "d": data })
	while _snaps.size() > 40:
		_snaps.pop_front()


func has_data() -> bool:
	return _snaps.size() >= 1


## Returns the interpolated render state, or empty dict when no data yet.
func sample() -> Dictionary:
	if _snaps.is_empty():
		return {}
	var render_t := _now() + _server_time_offset - C.INTERP_DELAY
	# Find bracketing snapshots.
	var older: Dictionary = _snaps[0]
	var newer: Dictionary = _snaps[-1]
	for i in range(_snaps.size() - 1, -1, -1):
		if _snaps[i]["t"] <= render_t:
			older = _snaps[i]
			newer = _snaps[mini(i + 1, _snaps.size() - 1)]
			break
	var a: PackedFloat32Array = older["d"]
	var b: PackedFloat32Array = newer["d"]
	var ta: float = older["t"]
	var tb: float = newer["t"]
	var f := 0.0
	if tb > ta:
		f = clampf((render_t - ta) / (tb - ta), 0.0, 1.0)

	var ball_pos := Vector3(
		lerpf(a[4], b[4], f), lerpf(a[5], b[5], f), lerpf(a[6], b[6], f))
	var ball_vel := Vector3(
		lerpf(a[7], b[7], f), lerpf(a[8], b[8], f), lerpf(a[9], b[9], f))
	var qa := Quaternion(a[10], a[11], a[12], a[13]).normalized()
	var qb := Quaternion(b[10], b[11], b[12], b[13]).normalized()
	var ball_quat := qa.slerp(qb, f) if qa.dot(qb) != 0.0 else qb

	var players: Array[Dictionary] = []
	for i in 22:
		var o := PLAYER0 + i * PLAYER_FLOATS
		players.append({
			"pos": Vector3(lerpf(a[o], b[o], f), lerpf(a[o + 1], b[o + 1], f),
				lerpf(a[o + 2], b[o + 2], f)),
			"yaw": lerp_angle(a[o + 3], b[o + 3], f),
			"speed": lerpf(a[o + 4], b[o + 4], f),
			"anim": int(b[o + 5]),
			"anim_t": b[o + 6],
		})
	return {
		"phase": int(b[1]),
		"clock": lerpf(a[2], b[2], f),
		"possession": int(b[3]),
		"ball_pos": ball_pos,
		"ball_vel": ball_vel,
		"ball_quat": ball_quat,
		"players": players,
	}


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

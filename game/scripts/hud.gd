class_name Hud
extends CanvasLayer
## Broadcast-TV style match HUD: scoreboard with team color chips, MM:SS clock +
## half indicator, fading center messages, gradient shot-power bar, status & hint
## lines. Fully self-contained: builds every control in _ready and reads/connects
## NOTHING external — main.gd drives it through the public API below.

const PANEL_BG := Color(0.055, 0.065, 0.095, 0.86)
const PANEL_EDGE := Color(1.0, 1.0, 1.0, 0.10)
const ACCENT := Color(0.55, 0.95, 0.45)
const TEXT_DIM := Color(1.0, 1.0, 1.0, 0.72)

var _root: Control

# --- scoreboard ---
var _home_name: Label
var _away_name: Label
var _home_score: Label
var _away_score: Label
var _home_chip_sb: StyleBoxFlat
var _away_chip_sb: StyleBoxFlat
var _clock_label: Label
var _last_home := -1
var _last_away := -1
var _home_pop: Tween
var _away_pop: Tween

# --- center message ---
var _message: Label
var _msg_tween: Tween

# --- charge bar ---
var _charge_box: Control
var _charge_bar: TextureProgressBar

# --- corner / hint text ---
var _status: Label
var _hint: Label


func _ready() -> void:
	layer = 10
	_root = Control.new()
	_root.name = "HudRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	_build_scoreboard()
	_build_center_message()
	_build_charge_bar()
	_build_status()
	_build_hint()
	_set_mouse_ignore(_root)

	# Sensible defaults until main.gd pushes real data.
	set_teams(C.TEAM_NAMES[0], C.TEAM_NAMES[1], C.KITS[0]["shirt"], C.KITS[1]["shirt"])
	set_score(0, 0)
	set_clock(0.0, 1)
	set_charge(-1.0)
	set_status("")
	set_hint("")


# ============================== public API ==================================

func set_teams(home: String, away: String, home_col: Color, away_col: Color) -> void:
	_home_name.text = home.to_upper()
	_away_name.text = away.to_upper()
	_home_chip_sb.bg_color = home_col
	_away_chip_sb.bg_color = away_col


func set_score(home: int, away: int) -> void:
	_home_score.text = str(home)
	_away_score.text = str(away)
	if _last_home >= 0 and home != _last_home:
		_home_pop = _pop_label(_home_score, _home_pop)
	if _last_away >= 0 and away != _last_away:
		_away_pop = _pop_label(_away_score, _away_pop)
	_last_home = home
	_last_away = away


func set_clock(seconds: float, half: int) -> void:
	var s := maxi(0, int(seconds))
	var half_txt := "2ND" if half >= 2 else "1ST"
	_clock_label.text = "%02d:%02d · %s" % [s / 60, s % 60, half_txt]


func set_charge(v: float) -> void:
	if v < 0.0:
		_charge_box.visible = false
		return
	_charge_box.visible = true
	var cv := clampf(v, 0.0, 1.0)
	_charge_bar.value = cv
	# Brighten at full power so the player feels the max.
	_charge_bar.tint_progress = Color(1.35, 1.25, 1.25) if cv >= 0.999 else Color.WHITE


func show_message(text: String, seconds: float) -> void:
	_message.text = text
	_message.reset_size()
	_message.pivot_offset = _message.size * 0.5
	if _msg_tween and _msg_tween.is_valid():
		_msg_tween.kill()
	_message.modulate.a = 0.0
	_message.scale = Vector2(1.18, 1.18)
	_msg_tween = create_tween()
	_msg_tween.set_parallel(true)
	_msg_tween.tween_property(_message, "modulate:a", 1.0, 0.16)
	_msg_tween.tween_property(_message, "scale", Vector2.ONE, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_msg_tween.set_parallel(false)
	_msg_tween.tween_interval(maxf(0.1, seconds))
	_msg_tween.tween_property(_message, "modulate:a", 0.0, 0.5)


func set_status(text: String) -> void:
	_status.text = text


func set_hint(text: String) -> void:
	_hint.text = text


# ============================== builders ====================================

func _build_scoreboard() -> void:
	var row := HBoxContainer.new()
	row.name = "Scoreboard"
	row.set_anchors_preset(Control.PRESET_TOP_LEFT)
	row.position = Vector2(18.0, 14.0)
	row.add_theme_constant_override("separation", 6)
	_root.add_child(row)

	# Score panel: [chip][HOME][n]  –  [n][AWAY][chip]
	var score_panel := PanelContainer.new()
	score_panel.add_theme_stylebox_override("panel", _panel_sb())
	row.add_child(score_panel)

	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 9)
	score_panel.add_child(inner)

	_home_chip_sb = _chip_sb()
	inner.add_child(_chip(_home_chip_sb))
	_home_name = _label(18, Color.WHITE)
	inner.add_child(_home_name)
	_home_score = _label(23, Color.WHITE)
	_home_score.custom_minimum_size = Vector2(24.0, 0.0)
	_home_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(_home_score)

	var dash := _label(18, TEXT_DIM)
	dash.text = "–"
	inner.add_child(dash)

	_away_score = _label(23, Color.WHITE)
	_away_score.custom_minimum_size = Vector2(24.0, 0.0)
	_away_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(_away_score)
	_away_name = _label(18, Color.WHITE)
	inner.add_child(_away_name)
	_away_chip_sb = _chip_sb()
	inner.add_child(_chip(_away_chip_sb))

	# Clock panel with green accent edge — broadcast style.
	var clock_panel := PanelContainer.new()
	var csb := _panel_sb()
	csb.border_width_left = 3
	csb.border_color = ACCENT
	clock_panel.add_theme_stylebox_override("panel", csb)
	row.add_child(clock_panel)

	_clock_label = _label(18, Color.WHITE)
	_clock_label.custom_minimum_size = Vector2(104.0, 0.0)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clock_panel.add_child(_clock_label)


func _build_center_message() -> void:
	_message = Label.new()
	_message.name = "CenterMessage"
	_message.anchor_left = 0.0
	_message.anchor_right = 1.0
	_message.anchor_top = 0.16
	_message.anchor_bottom = 0.42
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.add_theme_font_size_override("font_size", 64)
	_message.add_theme_color_override("font_color", Color.WHITE)
	_message.add_theme_color_override("font_outline_color", Color(0.04, 0.05, 0.08, 0.92))
	_message.add_theme_constant_override("outline_size", 12)
	_message.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.45))
	_message.add_theme_constant_override("shadow_offset_x", 0)
	_message.add_theme_constant_override("shadow_offset_y", 4)
	_message.modulate.a = 0.0
	_message.resized.connect(func() -> void: _message.pivot_offset = _message.size * 0.5)
	_root.add_child(_message)


func _build_charge_bar() -> void:
	_charge_box = Control.new()
	_charge_box.name = "ChargeBox"
	_charge_box.anchor_left = 0.5
	_charge_box.anchor_right = 0.5
	_charge_box.anchor_top = 1.0
	_charge_box.anchor_bottom = 1.0
	_charge_box.offset_left = -150.0
	_charge_box.offset_right = 150.0
	_charge_box.offset_top = -96.0
	_charge_box.offset_bottom = -56.0
	_root.add_child(_charge_box)

	var panel := Panel.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", _panel_sb())
	_charge_box.add_child(panel)

	var caption := _label(10, TEXT_DIM)
	caption.text = "SHOT POWER"
	caption.anchor_right = 1.0
	caption.offset_left = 8.0
	caption.offset_top = 3.0
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_charge_box.add_child(caption)

	_charge_bar = TextureProgressBar.new()
	_charge_bar.anchor_left = 0.0
	_charge_bar.anchor_right = 1.0
	_charge_bar.anchor_top = 1.0
	_charge_bar.anchor_bottom = 1.0
	_charge_bar.offset_left = 8.0
	_charge_bar.offset_right = -8.0
	_charge_bar.offset_top = -20.0
	_charge_bar.offset_bottom = -6.0
	_charge_bar.min_value = 0.0
	_charge_bar.max_value = 1.0
	_charge_bar.step = 0.0
	_charge_bar.fill_mode = TextureProgressBar.FILL_LEFT_TO_RIGHT
	_charge_bar.texture_under = _flat_tex(Color(0.0, 0.0, 0.0, 0.55))
	_charge_bar.texture_progress = _power_gradient_tex()
	_charge_box.add_child(_charge_bar)

	# Tick marks at 25/50/75% for power judgement.
	for f: float in [0.25, 0.5, 0.75]:
		var tick := ColorRect.new()
		tick.color = Color(0.0, 0.0, 0.0, 0.35)
		tick.anchor_left = f
		tick.anchor_right = f
		tick.anchor_bottom = 1.0
		tick.offset_left = -1.0
		tick.offset_right = 1.0
		_charge_bar.add_child(tick)


func _build_status() -> void:
	_status = _label(13, Color(1.0, 1.0, 1.0, 0.82))
	_status.name = "Status"
	_status.anchor_left = 0.0
	_status.anchor_right = 1.0
	_status.offset_left = 18.0
	_status.offset_right = -18.0
	_status.offset_top = 16.0
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.7))
	_status.add_theme_constant_override("shadow_offset_x", 1)
	_status.add_theme_constant_override("shadow_offset_y", 1)
	_root.add_child(_status)


func _build_hint() -> void:
	_hint = _label(14, TEXT_DIM)
	_hint.name = "Hint"
	_hint.anchor_left = 0.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_left = 18.0
	_hint.offset_right = -18.0
	_hint.offset_top = -34.0
	_hint.offset_bottom = -12.0
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_hint.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.55))
	_hint.add_theme_constant_override("outline_size", 5)
	_root.add_child(_hint)


# ============================== helpers =====================================

func _panel_sb() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.set_corner_radius_all(6)
	sb.border_width_bottom = 1
	sb.border_color = PANEL_EDGE
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


func _chip_sb() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.WHITE
	sb.set_corner_radius_all(2)
	return sb


func _chip(sb: StyleBoxFlat) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(10.0, 24.0)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_theme_stylebox_override("panel", sb)
	return p


func _label(font_size: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col)
	return l


func _pop_label(label: Label, prev: Tween) -> Tween:
	if prev and prev.is_valid():
		prev.kill()
	label.reset_size()
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2(1.7, 1.7)
	var t := create_tween()
	t.tween_property(label, "scale", Vector2.ONE, 0.4) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return t


func _power_gradient_tex() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([
		Color(0.20, 0.85, 0.35), Color(0.95, 0.85, 0.20), Color(0.95, 0.22, 0.14),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 284
	tex.height = 14
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(1.0, 0.0)
	return tex


func _flat_tex(col: Color) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([col, col])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 284
	tex.height = 14
	return tex


func _set_mouse_ignore(n: Node) -> void:
	if n is Control:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in n.get_children():
		_set_mouse_ignore(child)

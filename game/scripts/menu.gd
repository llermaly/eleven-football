class_name GameMenu
extends CanvasLayer
## Main menu: dark-green gradient card UI. Self-contained — builds everything in
## _ready and only emits `join_pressed`; main.gd drives status/busy state.

signal join_pressed(player_name: String, url: String)

const ACCENT := Color(0.30, 0.78, 0.38)
const ACCENT_DIM := Color(0.55, 0.85, 0.60, 0.85)
const TEXT_DIM := Color(0.78, 0.86, 0.80)
const CAPTION_COL := Color(0.62, 0.74, 0.65, 0.9)

const CONTROL_ROWS := [
	["WASD", "Move (or arrows)"],
	["SHIFT", "Sprint"],
	["SPACE", "Shoot · hold = power"],
	["E", "Ground pass"],
	["Q", "Lofted pass / cross"],
	["F", "Slide tackle"],
	["C", "Switch player"],
]

var _name_edit: LineEdit
var _url_edit: LineEdit
var _url_caption: Label
var _join_button: Button
var _status_label: Label


func _ready() -> void:
	layer = 20
	var root := Control.new()
	root.name = "MenuRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	_build_background(root)
	_build_card(root)
	_name_edit.call_deferred("grab_focus")


# ============================== public API ==================================

func set_status(text: String) -> void:
	_status_label.text = text


func set_busy(b: bool) -> void:
	_join_button.disabled = b
	_name_edit.editable = not b
	_url_edit.editable = not b
	_join_button.text = "CONNECTING…" if b else "JOIN MATCH"


# ============================== builders ====================================

func _build_background(root: Control) -> void:
	# Mowing-stripe base — a hint of pitch under the gradient.
	var stripes := TextureRect.new()
	stripes.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stripes.stretch_mode = TextureRect.STRETCH_SCALE
	stripes.texture = _stripe_tex()
	root.add_child(stripes)

	# Dark-green vertical gradient overlay.
	var grad := TextureRect.new()
	grad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grad.stretch_mode = TextureRect.STRETCH_SCALE
	grad.texture = _linear_tex(
		Color(0.01, 0.07, 0.03, 0.35), Color(0.0, 0.02, 0.01, 0.85),
		Vector2(0.5, 0.0), Vector2(0.5, 1.0))
	root.add_child(grad)

	# Soft radial glow behind the card.
	var glow := TextureRect.new()
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([Color(0.22, 0.55, 0.30, 0.30), Color(0.0, 0.0, 0.0, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.45)
	gt.fill_to = Vector2(1.0, 0.45)
	glow.texture = gt
	root.add_child(glow)


func _build_card(root: Control) -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.035, 0.075, 0.05, 0.96)
	sb.set_corner_radius_all(14)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(0.30, 0.55, 0.35, 0.45)
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.5)
	sb.shadow_size = 26
	sb.content_margin_left = 38.0
	sb.content_margin_right = 38.0
	sb.content_margin_top = 26.0
	sb.content_margin_bottom = 26.0
	card.add_theme_stylebox_override("panel", sb)
	center.add_child(card)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(440.0, 0.0)
	box.add_theme_constant_override("separation", 8)
	card.add_child(box)

	# --- title block ---
	var kicker := _label("ONLINE MULTIPLAYER · 11 V 11", 12, ACCENT_DIM)
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(kicker)

	var title := _label("GODOT SOCCER", 42, Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0.0, 0.15, 0.05, 0.8))
	title.add_theme_constant_override("outline_size", 6)
	box.add_child(title)

	var underline_holder := CenterContainer.new()
	var underline := ColorRect.new()
	underline.color = ACCENT
	underline.custom_minimum_size = Vector2(72.0, 3.0)
	underline_holder.add_child(underline)
	box.add_child(underline_holder)
	box.add_child(_spacer(8.0))

	# --- name field ---
	box.add_child(_caption("PLAYER NAME"))
	_name_edit = _line_edit("Player%d" % randi_range(100, 999), "Your name")
	_name_edit.max_length = 16
	box.add_child(_name_edit)

	# --- server URL field (native builds only) ---
	_url_caption = _caption("SERVER URL")
	box.add_child(_url_caption)
	_url_edit = _line_edit(C.DEFAULT_WS_URL, "ws://host:port")
	box.add_child(_url_edit)
	if OS.has_feature("web"):
		_url_caption.visible = false
		_url_edit.visible = false

	box.add_child(_spacer(10.0))

	# --- join button ---
	_join_button = _build_join_button()
	box.add_child(_join_button)

	# --- status ---
	_status_label = _label("", 13, Color(0.95, 0.82, 0.45))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(0.0, 20.0)
	box.add_child(_status_label)
	box.add_child(_spacer(6.0))

	# --- controls cheat-sheet ---
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", Color(1.0, 1.0, 1.0, 0.12))
	box.add_child(sep)
	var controls_title := _caption("CONTROLS")
	controls_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(controls_title)

	var grid_holder := CenterContainer.new()
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 7)
	for row: Array in CONTROL_ROWS:
		grid.add_child(_key_chip(row[0]))
		var desc := _label(row[1], 13, TEXT_DIM)
		desc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(desc)
	grid_holder.add_child(grid)
	box.add_child(grid_holder)


func _build_join_button() -> Button:
	var b := Button.new()
	b.text = "JOIN MATCH"
	b.custom_minimum_size = Vector2(0.0, 52.0)
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color(0.85, 0.95, 0.88))
	b.add_theme_color_override("font_disabled_color", Color(1.0, 1.0, 1.0, 0.45))
	b.add_theme_color_override("font_focus_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", _btn_sb(Color(0.12, 0.58, 0.26)))
	b.add_theme_stylebox_override("hover", _btn_sb(Color(0.16, 0.68, 0.32)))
	b.add_theme_stylebox_override("pressed", _btn_sb(Color(0.09, 0.46, 0.21)))
	b.add_theme_stylebox_override("disabled", _btn_sb(Color(0.18, 0.26, 0.20, 0.8)))
	var focus_sb := _btn_sb(Color(0.14, 0.62, 0.28))
	focus_sb.border_width_left = 2
	focus_sb.border_width_right = 2
	focus_sb.border_width_top = 2
	focus_sb.border_width_bottom = 2
	focus_sb.border_color = Color(0.75, 1.0, 0.8, 0.7)
	b.add_theme_stylebox_override("focus", focus_sb)
	b.pressed.connect(_on_join)
	return b


# ============================== behavior ====================================

func _on_join() -> void:
	var pname := _name_edit.text.strip_edges()
	if pname.is_empty():
		pname = "Player%d" % randi_range(100, 999)
		_name_edit.text = pname
	var url := ""
	if not OS.has_feature("web"):
		url = _url_edit.text.strip_edges()
		if url.is_empty():
			url = C.DEFAULT_WS_URL
	join_pressed.emit(pname, url)


# ============================== helpers =====================================

func _label(text: String, font_size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col)
	return l


func _caption(text: String) -> Label:
	return _label(text, 11, CAPTION_COL)


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0.0, h)
	return c


func _line_edit(default_text: String, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = default_text
	e.placeholder_text = placeholder
	e.custom_minimum_size = Vector2(0.0, 40.0)
	e.add_theme_font_size_override("font_size", 17)
	e.add_theme_color_override("font_color", Color(0.94, 0.98, 0.95))
	e.add_theme_color_override("caret_color", ACCENT)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.04, 0.03, 0.9)
	sb.set_corner_radius_all(8)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(1.0, 1.0, 1.0, 0.14)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	e.add_theme_stylebox_override("normal", sb)

	var sbf: StyleBoxFlat = sb.duplicate()
	sbf.border_color = ACCENT
	e.add_theme_stylebox_override("focus", sbf)
	e.text_submitted.connect(func(_t: String) -> void:
		if not _join_button.disabled:
			_on_join())
	return e


func _key_chip(text: String) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 1.0, 1.0, 0.08)
	sb.set_corner_radius_all(5)
	sb.border_width_bottom = 2
	sb.border_color = Color(1.0, 1.0, 1.0, 0.18)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var l := _label(text, 12, Color.WHITE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


func _btn_sb(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(10)
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.3)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0.0, 2.0)
	return sb


func _stripe_tex() -> ImageTexture:
	var img := Image.create(512, 2, false, Image.FORMAT_RGB8)
	var a := Color(0.045, 0.135, 0.07)
	var b := Color(0.034, 0.105, 0.055)
	for x in 512:
		var c := a if ((x >> 6) & 1) == 0 else b
		img.set_pixel(x, 0, c)
		img.set_pixel(x, 1, c)
	return ImageTexture.create_from_image(img)


func _linear_tex(c0: Color, c1: Color, from: Vector2, to: Vector2) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([c0, c1])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill_from = from
	tex.fill_to = to
	return tex

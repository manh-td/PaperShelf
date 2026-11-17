extends Control
## Contents drawer on the left. Up/Down to choose, Enter or a click to jump,
## Esc / C / Tab or a click outside to close.

signal picked(index: int)

var _backdrop: ColorRect
var _drawer: PanelContainer
var _list: ItemList
var _tween: Tween
var is_open := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	_backdrop = ColorRect.new()
	_backdrop.color = Color(0, 0, 0, 0.0)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			close())
	add_child(_backdrop)

	_drawer = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.12, 0.15)
	sb.set_content_margin_all(14)
	_drawer.add_theme_stylebox_override("panel", sb)
	add_child(_drawer)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_drawer.add_child(col)
	var title := Label.new()
	title.text = "Contents"
	title.add_theme_font_size_override("font_size", 22)
	col.add_child(title)
	var hint := Label.new()
	hint.text = "↑/↓ choose · Enter jump · Esc close"
	hint.modulate = Color(1, 1, 1, 0.5)
	col.add_child(hint)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.auto_height = false
	_list.allow_search = true
	_list.item_activated.connect(_pick)
	_list.item_clicked.connect(func(i, _pos, button):
		if button == MOUSE_BUTTON_LEFT:
			_pick(i))
	col.add_child(_list)

	resized.connect(_layout)


## entries: [{"t": text}] ; current: index to mark.
func set_entries(entries: Array, current: int) -> void:
	_list.clear()
	if entries.is_empty():
		_list.add_item("No headings found in this paper.", null, false)
		return
	for i in entries.size():
		_list.add_item(String(entries[i]["t"]))
		if i == current:
			_list.set_item_custom_fg_color(i, Color(1.0, 0.8, 0.2))
	var sel: int = max(current, 0)
	_list.select(sel)
	_list.ensure_current_is_visible.call_deferred()


func _pick(i: int) -> void:
	if _list.is_item_selectable(i):
		picked.emit(i)
		close()


func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	_layout()
	_drawer.position.x = -_drawer.size.x
	_animate(0.0, 0.35)
	_list.grab_focus()


func close() -> void:
	if not is_open:
		return
	is_open = false
	_list.release_focus()
	_animate(-_drawer.size.x, 0.0)
	_tween.finished.connect(func():
		if not is_open:
			visible = false)


func _input(event: InputEvent) -> void:
	# Tab would move focus out of the list; treat it as "close".
	if is_open and event is InputEventKey and event.pressed and event.keycode in [KEY_TAB, KEY_ESCAPE]:
		close()
		get_viewport().set_input_as_handled()


func _layout() -> void:
	var w: float = clamp(size.x * 0.3, 280.0, 460.0)
	_drawer.size = Vector2(w, size.y)
	_drawer.position = Vector2(0.0 if is_open else -w, 0)


func _animate(x: float, backdrop_alpha: float) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_drawer, "position:x", x, 0.2)
	_tween.tween_property(_backdrop, "color:a", backdrop_alpha, 0.2)

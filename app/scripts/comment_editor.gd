extends PanelContainer
## Comment editor shown beside the highlight.
##
## Typing goes into the comment. Enter adds a point under the comment (always one level:
## Enter in a point adds the next point). Tab opens the category list; typing filters it
## ("pre" -> Presentation), Enter or Tab picks. Ctrl+Enter saves, Esc discards the changes.
## Backspace in an empty point removes it. Up/Down at the first/last line move between items.

signal saved(comment: Dictionary)
signal deleted(comment_id: String)
signal closed

const ReviewBuilder := preload("res://scripts/review_builder.gd")

const CATEGORIES := [
	"Paper summary", "Strength", "Weakness", "Question",
	"Presentation", "Rigor/Soundness", "Verifiability", "Novelty", "Significance", "Others",
]
const CATEGORY_COLORS := {
	"Paper summary": Color(1.0, 0.55, 0.8),
	"Strength": Color(0.4, 0.85, 0.45),
	"Weakness": Color(1.0, 0.42, 0.42),
	"Question": Color(0.35, 0.85, 0.95),
	"Presentation": Color(0.35, 0.6, 1.0),
	"Rigor/Soundness": Color(1.0, 0.62, 0.25),
	"Verifiability": Color(0.95, 0.82, 0.3),
	"Novelty": Color(0.75, 0.5, 1.0),
	"Significance": Color(0.3, 0.78, 0.7),
	"Others": Color(0.72, 0.72, 0.75),
}
const NO_CATEGORY_COLOR := Color(0.92, 0.92, 0.92)

var _comment := {}
var _category := ""
var _quote: Label
var _cat_button: Button
var _items: VBoxContainer
var _delete: Button
var _chooser: VBoxContainer
var _filter: LineEdit
var _choices: ItemList
var _return_focus: TextEdit = null


static func color_for(category: String) -> Color:
	return CATEGORY_COLORS.get(category, NO_CATEGORY_COLOR)


func _ready() -> void:
	visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.12, 0.15, 0.97)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(12)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	add_theme_stylebox_override("panel", sb)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	add_child(col)

	_quote = Label.new()
	_quote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quote.add_theme_font_size_override("font_size", 13)
	_quote.modulate = Color(1, 1, 1, 0.6)
	_quote.max_lines_visible = 3
	_quote.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_quote)

	_cat_button = Button.new()
	_cat_button.focus_mode = Control.FOCUS_NONE
	_cat_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_cat_button.pressed.connect(_open_chooser)
	col.add_child(_cat_button)

	_chooser = VBoxContainer.new()
	_chooser.visible = false
	col.add_child(_chooser)
	_filter = LineEdit.new()
	_filter.placeholder_text = "Type to filter, Enter to pick"
	_filter.text_changed.connect(func(_t): _refresh_choices())
	_filter.gui_input.connect(_on_filter_key)
	_chooser.add_child(_filter)
	_choices = ItemList.new()
	_choices.auto_height = true
	_choices.focus_mode = Control.FOCUS_NONE
	_choices.item_clicked.connect(func(i, _p, _b): _choose(i))
	_chooser.add_child(_choices)

	_items = VBoxContainer.new()
	_items.add_theme_constant_override("separation", 4)
	col.add_child(_items)

	var foot := HBoxContainer.new()
	col.add_child(foot)
	var hint := Label.new()
	hint.text = "Enter: add point   Tab: category   Ctrl+Enter: done   Esc: discard"
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.45)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	foot.add_child(hint)
	_delete = Button.new()
	_delete.text = "Delete"
	_delete.focus_mode = Control.FOCUS_NONE
	_delete.pressed.connect(func():
		visible = false
		deleted.emit(String(_comment.get("id", ""))))
	foot.add_child(_delete)


## Opens the editor for `comment` ({} fields for a new one: s, e, quote, kind).
## `first_text` is what the user typed to start a new comment.
func open(comment: Dictionary, first_text := "") -> void:
	_comment = comment.duplicate(true)
	_category = String(_comment.get("category", ""))
	_quote.text = "“%s”" % ReviewBuilder.pretty_quote(String(_comment.get("quote", "")), 400)
	_update_category()
	_chooser.visible = false
	for c in _items.get_children():
		_items.remove_child(c)
		c.queue_free()
	var main := _add_item(String(_comment.get("text", "")) + first_text, false, -1)
	for s in _comment.get("subs", []):
		_add_item(String(s), true, -1)
	_delete.visible = not String(_comment.get("id", "")).is_empty()
	visible = true
	_focus_end.call_deferred(main)


func is_editing() -> bool:
	return visible


# ------------------------------------------------------------------ items

func _add_item(text: String, is_sub: bool, at: int) -> TextEdit:
	var row := HBoxContainer.new()
	var bullet := Label.new()
	bullet.text = "    •" if is_sub else ""
	bullet.custom_minimum_size.x = 26 if is_sub else 0
	bullet.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(bullet)
	var te := TextEdit.new()
	te.text = text
	te.placeholder_text = "A point about this comment…" if is_sub else "Your comment…"
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.scroll_fit_content_height = true
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.custom_minimum_size.y = 30
	te.set_meta("sub", is_sub)
	te.gui_input.connect(_on_item_key.bind(te))
	row.add_child(te)
	_items.add_child(row)
	if at >= 0:
		_items.move_child(row, at)
	return te


func _editors() -> Array:
	var out := []
	for row in _items.get_children():
		if row.is_queued_for_deletion():
			continue
		out.append(row.get_child(1))
	return out


func _index_of(te: TextEdit) -> int:
	return _editors().find(te)


func _focus_end(te: TextEdit) -> void:
	if not is_instance_valid(te):
		return
	te.grab_focus()
	te.set_caret_line(te.get_line_count() - 1)
	te.set_caret_column(te.get_line(te.get_line_count() - 1).length())


func _on_item_key(event: InputEvent, te: TextEdit) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	match k.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			if k.is_command_or_control_pressed():
				_finish()
			elif k.shift_pressed:
				return   # a line break inside this item
			else:
				# A new point right after this item (points are never nested deeper).
				var next := _add_item("", true, _index_of(te) + 1)
				_focus_end.call_deferred(next)
			te.accept_event()
		KEY_TAB:
			_return_focus = te
			_open_chooser()
			te.accept_event()
		KEY_ESCAPE:
			_cancel()
			te.accept_event()
		KEY_BACKSPACE:
			if te.get_meta("sub", false) and te.text.is_empty():
				var eds := _editors()
				var i := eds.find(te)
				te.get_parent().queue_free()
				if i > 0:
					_focus_end.call_deferred(eds[i - 1])
				te.accept_event()
		KEY_UP:
			if te.get_caret_line() == 0 and _index_of(te) > 0:
				_focus_end(_editors()[_index_of(te) - 1])
				te.accept_event()
		KEY_DOWN:
			var eds := _editors()
			if te.get_caret_line() == te.get_line_count() - 1 and _index_of(te) < eds.size() - 1:
				_focus_end(eds[_index_of(te) + 1])
				te.accept_event()


func _finish() -> void:
	var texts := []
	for te in _editors():
		var t := String(te.text).strip_edges()
		if not t.is_empty():
			texts.append(t)
	visible = false
	if texts.is_empty():
		var id := String(_comment.get("id", ""))
		if id.is_empty():
			closed.emit()
		else:
			deleted.emit(id)
		return
	var c := _comment.duplicate(true)
	c["category"] = _category
	c["text"] = texts[0]
	c["subs"] = texts.slice(1)
	saved.emit(c)


func _cancel() -> void:
	visible = false
	closed.emit()


# ------------------------------------------------------------------ category

func _update_category() -> void:
	var name := _category if not _category.is_empty() else "No category"
	_cat_button.text = "●  %s   (Tab to change)" % name
	_cat_button.add_theme_color_override("font_color", color_for(_category))
	_cat_button.add_theme_color_override("font_hover_color", color_for(_category))


func _open_chooser() -> void:
	if _return_focus == null:
		for te in _editors():
			if te.has_focus():
				_return_focus = te
	_chooser.visible = true
	_filter.text = ""
	_refresh_choices()
	_filter.grab_focus()


## Categories matching the filter: name starts first, then anywhere ("sound" -> Rigor/Soundness).
func _matches() -> Array:
	var f := _filter.text.strip_edges().to_lower()
	if f.is_empty():
		return CATEGORIES.duplicate()
	var starts := []
	var inside := []
	for c in CATEGORIES:
		var name := String(c).to_lower()
		var words := name.replace("/", " ").split(" ")
		var word_start := false
		for w in words:
			if w.begins_with(f):
				word_start = true
		if name.begins_with(f):
			starts.append(c)
		elif word_start or name.contains(f):
			inside.append(c)
	return starts + inside


func _refresh_choices() -> void:
	_choices.clear()
	for c in _matches():
		var i := _choices.add_item(c)
		_choices.set_item_custom_fg_color(i, color_for(c))
	if _choices.item_count > 0:
		_choices.select(0)


func _on_filter_key(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	var sel := _choices.get_selected_items()
	var cur: int = sel[0] if not sel.is_empty() else 0
	match k.keycode:
		KEY_DOWN:
			if _choices.item_count > 0:
				_choices.select(mini(cur + 1, _choices.item_count - 1))
			_filter.accept_event()
		KEY_UP:
			if _choices.item_count > 0:
				_choices.select(maxi(cur - 1, 0))
			_filter.accept_event()
		KEY_ENTER, KEY_KP_ENTER, KEY_TAB:
			if _choices.item_count > 0:
				_choose(cur)
			else:
				_close_chooser()
			_filter.accept_event()
		KEY_ESCAPE:
			_close_chooser()
			_filter.accept_event()


func _choose(i: int) -> void:
	_category = _choices.get_item_text(i)
	_update_category()
	_close_chooser()


func _close_chooser() -> void:
	_chooser.visible = false
	var back := _return_focus
	_return_focus = null
	if back == null or not is_instance_valid(back):
		var eds := _editors()
		back = eds[0] if not eds.is_empty() else null
	if back:
		_focus_end.call_deferred(back)

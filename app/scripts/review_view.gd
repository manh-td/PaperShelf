extends Control
## Review screen for one paper: the overall merit and the review sections, filled from the
## paper's comments (review_builder.gd) and edited freely. Saved as you type.
## Sections you have not edited follow the comments automatically (category changes, edits,
## new comments) each time the screen opens. An edited section is kept; when its comments
## change, a note offers "Update from comments". "Rebuild…" refreshes every comment section.
## "Export Markdown…" saves the review as a .md file. Esc goes back.

signal closed

const Builder := preload("res://scripts/review_builder.gd")

var paper_id := ""
var _review: Dictionary = {}
var _edits := {}            # section key -> TextEdit
var _notes := {}            # section key -> note row ("edited; comments changed")
var _title: Label
var _merit: OptionButton
var _quotes: CheckBox
var _status: Label
var _save_timer: Timer
var _confirm: ConfirmationDialog
var _confirm_action: Callable
var _export: FileDialog
var _loading := false


func _ready() -> void:
	visible = false
	_build()


## Shows the review of a paper, brought up to date with its comments.
func open(id: String) -> void:
	paper_id = id
	var p := Library.paper(id)
	_title.text = "Review: " + Library.display_title(p)
	_review = Builder.sync(Library.review(id), Library.comments(id))
	Library.save_review(id, _review)
	_fill()
	visible = true
	var n: int = _review.get("included", []).size()
	var stale := Builder.stale_sections(_review, Library.comments(id))
	_status.text = "%d comment%s. Sections you haven't edited follow your comments automatically%s." % [
		n, "" if n == 1 else "s",
		"" if stale.is_empty() else "; %d edited section%s can be updated (see the notes)" % [stale.size(), "" if stale.size() == 1 else "s"]]
	var first: TextEdit = _edits["summary"]
	first.grab_focus.call_deferred()


func close() -> void:
	_save_now()
	visible = false
	closed.emit()


func _fill() -> void:
	_loading = true
	var sections: Dictionary = _review.get("sections", {})
	for key in _edits:
		_edits[key].text = String(sections.get(key, ""))
	_merit.select(maxi(Builder.MERITS.find(String(_review.get("merit", ""))), 0))
	_quotes.button_pressed = bool(_review.get("quotes", true))
	_loading = false
	_update_notes()


## Shows the "edited; comments changed" note on the sections that need it.
func _update_notes() -> void:
	var stale := Builder.stale_sections(_review, Library.comments(paper_id))
	for key in _notes:
		_notes[key].visible = key in stale


# ------------------------------------------------------------------ saving

func _changed() -> void:
	if _loading:
		return
	_save_timer.start()


func _save_now() -> void:
	if paper_id.is_empty():
		return
	_save_timer.stop()
	var sections := {}
	for key in _edits:
		sections[key] = _edits[key].text
	_review["sections"] = sections
	_review["merit"] = Builder.MERITS[maxi(_merit.selected, 0)]
	_review["quotes"] = _quotes.button_pressed
	Library.save_review(paper_id, _review)


## Quotes on/off: regenerate the sections that follow the comments.
func _on_quotes_toggled(_on: bool) -> void:
	if _loading:
		return
	_save_now()
	_review = Builder.sync(_review, Library.comments(paper_id))
	Library.save_review(paper_id, _review)
	_fill()


func _update_section(key: String) -> void:
	_save_now()
	_review = Builder.update_section(_review, Library.comments(paper_id), key)
	Library.save_review(paper_id, _review)
	_fill()
	_status.text = "Updated \"%s\" from the current comments." % Builder._title(key)


func _rebuild() -> void:
	_save_now()
	_review = Builder.sync(_review, Library.comments(paper_id), true)
	Library.save_review(paper_id, _review)
	_fill()
	_status.text = "Rebuilt the sections from all %d comments (merit, introduction and references kept)." % _review["included"].size()


func _ask(text: String, ok: String, action: Callable) -> void:
	_confirm.dialog_text = text
	_confirm.ok_button_text = ok
	_confirm_action = action
	_confirm.popup_centered()


func _export_to(path: String) -> void:
	_save_now()
	var md := Builder.to_markdown(_review, Library.display_title(Library.paper(paper_id)))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status.text = "Could not write %s (error %d)." % [path, FileAccess.get_open_error()]
		return
	f.store_string(md)
	f.close()
	_status.text = "Saved the review to " + path


func export_dialog() -> void:
	_save_now()
	var name := Library.display_title(Library.paper(paper_id)).left(80)
	name = name.replace("/", "-").replace("\\", "-").replace(":", " -").replace("?", "").replace("*", "") \
		.replace("\"", "").replace("<", "").replace(">", "").replace("|", "-").strip_edges()
	_export.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	_export.current_file = name + " - review.md"
	_export.popup_centered_ratio(0.6)


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	var k := event as InputEventKey
	if k and k.pressed and k.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ layout

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.12, 0.14)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("separation", 0)
	add_child(outer)

	var bar := PanelContainer.new()
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = Color(0.08, 0.08, 0.10)
	bsb.set_content_margin_all(8)
	bar.add_theme_stylebox_override("panel", bsb)
	outer.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	bar.add_child(row)
	row.add_child(_button("← Back", close, "Back (Esc)"))
	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_title)
	_quotes = CheckBox.new()
	_quotes.text = "Quote text and location"
	_quotes.tooltip_text = "Items collected from now on quote the commented text and where it is\n(e.g. Section 2 (Methodology), Subsection 2.1 (Study Setup), sentence 2, p. 4)"
	_quotes.focus_mode = Control.FOCUS_NONE
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		_quotes.add_theme_color_override(c, Color(0.88, 0.88, 0.9))
	_quotes.toggled.connect(_on_quotes_toggled)
	row.add_child(_quotes)
	row.add_child(_button("Rebuild…", func():
		_ask("Rebuild every section from the current comments?
Your edits in the sections filled from comments are replaced; the overall merit, introduction and references are kept.",
			"Rebuild", _rebuild), "Refill all comment sections, also the ones you edited"))
	row.add_child(_button("Export Markdown…", export_dialog, "Save the review as a .md file"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var col := VBoxContainer.new()
	col.custom_minimum_size.x = 860
	col.add_theme_constant_override("separation", 6)
	center.add_child(col)
	col.add_child(_spacer(10))

	var merit_row := HBoxContainer.new()
	merit_row.add_child(_heading("Overall merit", 20))
	merit_row.add_child(_spacer_h(12))
	_merit = OptionButton.new()
	for m in Builder.MERITS:
		_merit.add_item(m if not m.is_empty() else "— not set —")
	_merit.item_selected.connect(func(_i): _changed())
	merit_row.add_child(_merit)
	col.add_child(merit_row)

	var hints := {
		"summary": "What the paper does and finds (from your Paper summary comments).",
		"strengths": "From your Strength comments.",
		"weaknesses": "From your Weakness comments.",
		"intro": "Your overall impression and main concerns (written here).",
		"questions": "From your Question comments.",
		"references": "Papers you cite in the review (written here).",
	}
	for s in Builder.SECTIONS:
		var key: String = s[0]
		var detail: bool = s[2] == "detail"
		col.add_child(_spacer(6))
		var head := _heading(s[1], 15 if detail else 20)
		if detail:
			head.modulate = Color(0.8, 0.85, 1.0)
		col.add_child(head)
		if hints.has(key):
			var h := Label.new()
			h.text = hints[key]
			h.add_theme_font_size_override("font_size", 13)
			h.modulate = Color(1, 1, 1, 0.45)
			col.add_child(h)
		if key in Builder.comment_sections():
			# Shown when you edited this section and its comments changed since.
			var note := HBoxContainer.new()
			note.visible = false
			var nl := Label.new()
			nl.text = "You edited this section, and its comments have changed since (new, edited or re-categorized)."
			nl.add_theme_font_size_override("font_size", 13)
			nl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.35))
			nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			note.add_child(nl)
			var section_title: String = s[1]
			note.add_child(_button("Update from comments", func():
				_ask("Replace \"%s\" with what your comments give now?\nYour edits in this section are replaced." % section_title,
					"Update", _update_section.bind(key)), "Replace this section with the current comments"))
			_notes[key] = note
			if detail:
				var nm := MarginContainer.new()
				nm.add_theme_constant_override("margin_left", 18)
				nm.add_child(note)
				col.add_child(nm)
			else:
				col.add_child(note)
		var te := TextEdit.new()
		te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		te.scroll_fit_content_height = true
		te.custom_minimum_size.y = 56
		te.placeholder_text = "Nothing yet" if not key in ["intro", "references"] else "Write here…"
		te.text_changed.connect(_changed)
		_edits[key] = te
		if detail:
			var m := MarginContainer.new()
			m.add_theme_constant_override("margin_left", 18)
			m.add_child(te)
			col.add_child(m)
		else:
			col.add_child(te)
	col.add_child(_spacer(40))

	var foot := PanelContainer.new()
	foot.add_theme_stylebox_override("panel", bsb)
	outer.add_child(foot)
	_status = Label.new()
	_status.modulate = Color(1, 1, 1, 0.7)
	foot.add_child(_status)

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.8
	_save_timer.timeout.connect(_save_now)
	add_child(_save_timer)

	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(func():
		if _confirm_action.is_valid():
			_confirm_action.call())
	add_child(_confirm)

	_export = FileDialog.new()
	_export.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_export.access = FileDialog.ACCESS_FILESYSTEM
	_export.filters = PackedStringArray(["*.md ; Markdown"])
	_export.use_native_dialog = true
	_export.title = "Export review"
	_export.file_selected.connect(_export_to)
	add_child(_export)


func _button(text: String, action: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	b.pressed.connect(action)
	return b


func _heading(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = h
	return c


func _spacer_h(w: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size.x = w
	return c

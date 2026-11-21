extends SceneTree
## Windowed test of selecting text in Free mode and commenting on it, plus the new categories.
##   Godot --path app --script res://tests/selection_test.gd -- <file.pdf> <scratch_dir> <shots_dir>

var main: Control
var reader: Control
var Library
var paper_id := ""
var fails := 0
var shots := ""


func _initialize() -> void:
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	print(("ok    " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _key(code: Key, ctrl := false, shift := false, unicode := 0) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		e.ctrl_pressed = ctrl
		e.shift_pressed = shift
		if pressed:
			e.unicode = unicode
		Input.parse_input_event(e)
		await process_frame


func _type(text: String) -> void:
	for ch in text:
		var code: Key = KEY_SPACE if ch == " " else (OS.find_keycode_from_string(ch.to_upper()) as Key)
		await _key(code, false, ch != ch.to_lower(), ch.unicode_at(0))


func _mouse(pos: Vector2, pressed: bool) -> void:
	_last_mouse = pos
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	Input.parse_input_event(e)
	await process_frame


var _last_mouse := Vector2.ZERO


func _move(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.relative = pos - _last_mouse   # real mouse events carry how far they moved
	_last_mouse = pos
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(e)
	await process_frame


func _drag(a: Vector2, b: Vector2) -> void:
	await _mouse(a, true)
	for i in range(1, 9):
		await _move(a.lerp(b, i / 8.0))
	await _mouse(b, false)
	await _wait(0.2)


func _click(pos: Vector2) -> void:
	await _mouse(pos, true)
	await _mouse(pos, false)
	await _wait(0.2)


## Screen center of word wi of reading-order line li.
func _word_pos(li: int, wi: int) -> Vector2:
	return reader._to_screen(reader._words_rect(li, wi, wi)).get_center()


func _comments() -> Array:
	return Library.comments(paper_id)


func _filter(text: String) -> Array:
	reader._editor._filter.text = text
	return reader._editor._matches()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	shots = args[2]
	DirAccess.make_dir_recursive_absolute(shots)
	Library = root.get_node("Library")
	DirAccess.make_dir_recursive_absolute(args[1])
	if FileAccess.file_exists(args[1].path_join("library.json")):
		DirAccess.remove_absolute(args[1].path_join("library.json"))
	Library.load_from(args[1])
	var r: Dictionary = Library.import_pdf(args[0])
	paper_id = r.get("paper", r.get("duplicate", {}))["id"]
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	reader = main._reader
	await _wait(0.3)
	main.open_paper(paper_id)
	var t0 := Time.get_ticks_msec()
	while not reader.visible and Time.get_ticks_msec() - t0 < 20000:
		await process_frame
	await _key(KEY_4, true)
	await _key(KEY_HOME)
	await _wait(0.6)

	# A long body line in view: select its words 1..5 by dragging.
	var li := -1
	for l in reader.all_lines:
		if l["k"] == "body" and int(l["p"]) == 0 and String(l["t"]).split(" ").size() >= 8:
			var sr: Rect2 = reader._to_screen(reader._line_rect(l))
			if sr.position.y > 120 and sr.end.y < 800:
				li = int(l["i"])
				break
	check(li >= 0, "found a body line on screen")
	var ws: Array = reader._all_words[li]
	var expected := " ".join(ws.slice(1, 6).map(func(w): return String(w["t"])))

	# Typing with nothing selected does not open the editor.
	await _type("x")
	check(not reader._editor.visible, "typing without a selection does not start a comment")

	await _drag(_word_pos(li, 1), _word_pos(li, 5))
	check(reader.has_selection(), "dragging across words selects them")
	check(reader._range_text(reader._sel_s, reader._sel_e) == expected, "selected: \"%s\"" % reader._range_text(reader._sel_s, reader._sel_e))
	await _wait(0.3)
	root.get_texture().get_image().save_png(shots.path_join("01_selection.png"))

	# Type to comment on the selection; Tab + "str" picks Strength.
	await _type("Nice result")
	check(reader._editor.visible, "typing on a selection starts a comment")
	await _key(KEY_TAB)
	check(_filter("str") == ["Strength"], "'str' filters to Strength")
	reader._editor._refresh_choices()
	await _key(KEY_ENTER)
	await _key(KEY_ENTER, true)
	var cs := _comments()
	check(cs.size() == 1 and cs[0]["category"] == "Strength", "comment saved with category Strength")
	check(cs.size() == 1 and cs[0]["quote"] == expected, "the comment covers exactly the selection")
	check(reader._side.visible, "its card shows in Free mode")
	await _wait(0.3)
	root.get_texture().get_image().save_png(shots.path_join("02_comment_card.png"))

	# Clicking elsewhere clears; clicking the commented text selects it again.
	await _click(Vector2(60, 450))
	check(not reader.has_selection() and not reader._side.visible, "a click outside clears the selection and the card")
	await _click(_word_pos(li, 3))
	check(reader.has_selection() and reader._sel_s == int(cs[0]["s"]) and reader._sel_e == int(cs[0]["e"]),
		"clicking commented text selects that comment")
	check(reader._side.visible, "and shows its card")
	await _key(KEY_ESCAPE)
	check(not reader.has_selection() and reader.visible, "Esc clears the selection and stays in the paper")

	# Ctrl+Down finds the comment from the top, staying in Free mode.
	await _key(KEY_HOME)
	await _wait(0.4)
	await _key(KEY_DOWN, true)
	await _wait(0.4)
	check(reader._active_mode == "free" and reader.has_selection() and reader._sel_s == int(cs[0]["s"]),
		"Ctrl+Down selects the next comment without leaving Free mode")

	# Dragging from a blank area still scrolls the page.
	await _key(KEY_ESCAPE)
	var cam_y: float = reader.cam.y
	await _drag(Vector2(60, 600), Vector2(60, 300))
	check(reader.cam.y > cam_y and not reader.has_selection(), "dragging a blank area scrolls instead of selecting")

	# New categories in the list.
	await _key(KEY_HOME)   # the blank-area drag scrolled the line out of view
	await _wait(0.5)
	await _drag(_word_pos(li, 1), _word_pos(li, 2))
	await _type("Q")
	await _key(KEY_TAB)
	check(reader._editor.visible and reader._editor._chooser.visible, "a new comment with its category list is open")
	check(_filter("") == ["Paper summary", "Strength", "Weakness", "Question", "Presentation",
		"Rigor/Soundness", "Verifiability", "Novelty", "Significance", "Others"], "all ten categories listed in order")
	check(_filter("pa")[0] == "Paper summary", "'pa' picks Paper summary")
	check(_filter("we")[0] == "Weakness", "'we' picks Weakness")
	check(_filter("q")[0] == "Question", "'q' picks Question")
	check(_filter("sum")[0] == "Paper summary", "'sum' finds Paper summary (word start)")
	# First Esc closes the category list, the second discards the comment.
	await _key(KEY_ESCAPE)
	await _wait(0.2)
	await _key(KEY_ESCAPE)
	await _wait(0.2)
	check(not reader._editor.visible, "Esc closes the category list, then the editor")

	# Switching modes drops the Free-mode selection.
	await _drag(_word_pos(li, 1), _word_pos(li, 3))
	check(reader.has_selection(), "selected again before switching modes")
	await _key(KEY_1, true)
	check(reader._active_mode == "sentence", "Ctrl+1 switched to Sentence mode")
	check(not reader.has_selection(), "switching to Sentence mode clears the selection")

	print("PASS" if fails == 0 else "FAILED: %d" % fails)
	quit(0 if fails == 0 else 1)

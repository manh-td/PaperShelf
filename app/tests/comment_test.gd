extends SceneTree
## Windowed test of commenting by typing in the reader. Run from the PaperShelf folder:
##   Godot --path app --script res://tests/comment_test.gd -- <file.pdf> <scratch_dir> <shots_dir>

var main: Control
var reader: Control
var Library
var paper_id := ""
var shots := ""
var fails := 0
var shot_n := 0


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


## Types text one character at a time, like a keyboard does.
func _type(text: String) -> void:
	for ch in text:
		var u := ch.unicode_at(0)
		var code: Key = KEY_SPACE if ch == " " else (OS.find_keycode_from_string(ch.to_upper()) as Key)
		await _key(code, false, ch != ch.to_lower(), u)


func _shot(label: String) -> void:
	await _wait(0.5)
	shot_n += 1
	root.get_texture().get_image().save_png(shots.path_join("%02d_%s.png" % [shot_n, label]))


func _comments() -> Array:
	return Library.comments(paper_id)


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
	await _key(KEY_HOME)
	for i in 8:
		await _key(KEY_RIGHT)
	await _wait(0.4)
	var step_before: int = reader.current

	# 1. Typing starts a comment; Tab + "rig" picks Rigor/Soundness; Enter adds points.
	await _type("Unclear notation")
	check(reader._editor.visible, "typing opens the comment editor")
	check(reader.current == step_before, "typing does not move the reading position")
	await _key(KEY_TAB)
	check(reader._editor._chooser.visible, "Tab opens the category list")
	await _type("rig")
	check(reader._editor._choices.item_count == 1 and reader._editor._choices.get_item_text(0) == "Rigor/Soundness",
		"typing 'rig' filters the list to Rigor/Soundness")
	await _shot("category_filter")
	await _key(KEY_ENTER)
	check(not reader._editor._chooser.visible and reader._editor._category == "Rigor/Soundness", "Enter picks the category")
	await _key(KEY_ENTER)
	await _type("Eq 3 is never defined")
	await _key(KEY_ENTER)
	await _type("Same for eq 4")
	await _shot("editor_with_points")
	await _key(KEY_ENTER, true)
	check(not reader._editor.visible, "Ctrl+Enter closes the editor")
	var cs := _comments()
	check(cs.size() == 1, "one comment saved")
	if cs.size() == 1:
		var c: Dictionary = cs[0]
		check(c["text"] == "Unclear notation", "comment text: %s" % c["text"])
		check(c["category"] == "Rigor/Soundness", "category saved")
		check(c["subs"] == ["Eq 3 is never defined", "Same for eq 4"], "two points at one level: %s" % str(c["subs"]))
		check(String(c["quote"]).length() > 10, "quote: %s" % String(c["quote"]).left(60))
	check(reader._side.visible and reader._side.get_child_count() == 1, "the comment card shows beside the highlight")
	await _shot("card")

	# 2. The card goes away on the next sentence and returns; Ctrl+Down/Up jump to it.
	await _key(KEY_RIGHT)
	await _key(KEY_RIGHT)
	await _wait(0.3)
	check(not reader._side.visible, "no card on a sentence without comments")
	await _key(KEY_HOME)
	await _key(KEY_DOWN, true)
	await _wait(0.3)
	check(reader._side.visible, "Ctrl+Down jumps to the next comment")

	# 3. Edit: append to the text, keep the points.
	reader._edit_comment(_comments()[0])
	await _wait(0.2)
	await _type(" in section 2")
	await _key(KEY_ENTER, true)
	check(_comments()[0]["text"] == "Unclear notation in section 2", "edit updates the text")
	check(_comments()[0]["subs"].size() == 2, "edit keeps the points")

	# 4. "pre" picks Presentation on another sentence; Esc discards; emptying deletes.
	await _key(KEY_RIGHT)
	await _wait(0.3)
	await _type("Typo")
	await _key(KEY_TAB)
	await _type("pre")
	await _key(KEY_ENTER)
	await _key(KEY_ENTER, true)
	check(_comments().size() == 2, "second comment saved")
	var pres := _comments().filter(func(x): return x["text"] == "Typo")
	check(not pres.is_empty() and pres[0]["category"] == "Presentation", "'pre' picks Presentation")
	await _key(KEY_RIGHT)
	await _wait(0.3)
	await _type("zzz")
	await _key(KEY_ESCAPE)
	check(not reader._editor.visible and _comments().size() == 2, "Esc discards a new comment")
	check(reader.visible, "Esc in the editor does not leave the document")
	reader._edit_comment(pres[0])
	await _wait(0.2)
	await _key(KEY_A, true)
	await _key(KEY_BACKSPACE)
	await _key(KEY_ENTER, true)
	check(_comments().size() == 1, "emptying a comment and Ctrl+Enter deletes it")

	# 5. Moved shortcuts: "1" starts a comment now; Ctrl+2 switches to Line mode.
	await _type("1")
	check(reader._editor.visible, "'1' starts a comment")
	await _key(KEY_ESCAPE)
	await _key(KEY_2, true)
	check(reader._active_mode == "line", "Ctrl+2 switches to Line mode")
	await _key(KEY_1, true)

	# 6. Re-attach: a comment with stale positions finds its sentence again.
	var c0: Dictionary = _comments()[0].duplicate(true)
	var good_s := int(c0["s"])
	c0["s"] = good_s + 3 * 10000
	c0["e"] = int(c0["e"]) + 3 * 10000
	Library.save_comment(paper_id, c0)
	reader._load_comments()
	check(int(reader._comments[0]["s"]) == good_s, "a comment with stale positions is re-attached by its text")

	await _key(KEY_HOME)
	await _key(KEY_DOWN, true)
	await _shot("final_card")
	print("PASS" if fails == 0 else "FAILED: %d" % fails)
	quit(0 if fails == 0 else 1)

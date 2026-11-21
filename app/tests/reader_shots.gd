extends SceneTree
## Opens a PDF in the real app window, presses reader keys and saves screenshots.
## Run (not headless) from the PaperShelf folder:
##   Godot --path app --script res://tests/reader_shots.gd -- <file.pdf> <out_dir>

var main: Control
var out_dir := ""
var shot := 0


func _initialize() -> void:
	_run.call_deferred()


func _key(code: Key, shift := false, ctrl := false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		e.ctrl_pressed = ctrl
		e.shift_pressed = shift
		Input.parse_input_event(e)
		await process_frame


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _shot(label: String) -> void:
	await _wait(0.9)
	var img := root.get_texture().get_image()
	shot += 1
	var path := out_dir.path_join("%02d_%s.png" % [shot, label])
	img.save_png(path)
	print("shot ", path)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	out_dir = args[1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	# A scratch library next to the screenshots, so the real library is untouched.
	var lib_dir := out_dir.path_join("library")
	DirAccess.make_dir_recursive_absolute(lib_dir)
	var Library = root.get_node("Library")
	Library.load_from(lib_dir)
	var r: Dictionary = Library.import_pdf(args[0])
	var paper: Dictionary = r.get("paper", r.get("duplicate", {}))
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _wait(0.5)
	await _shot("library")
	main.open_paper(paper["id"])
	var reader: Control = main._reader
	var t0 := Time.get_ticks_msec()
	while not reader.visible and Time.get_ticks_msec() - t0 < 30000:
		await process_frame
	if not reader.visible:
		printerr("FAIL: reader did not open: ", main._library._status.text)
		quit(1)
		return
	await _key(KEY_HOME)
	await _shot("sentence_first")
	for i in 6:
		await _key(KEY_RIGHT)
		await _wait(0.05)
	await _shot("sentence_after_6")
	print("status: ", reader._status.text)
	await _key(KEY_2, false, true)
	await _shot("line_mode")
	await _key(KEY_PAGEDOWN)
	await _shot("page_down")
	print("status: ", reader._status.text)
	await _key(KEY_3, false, true)
	await _shot("figures_mode")
	print("status: ", reader._status.text)
	await _key(KEY_1, false, true)
	await _key(KEY_TAB)
	await _shot("contents")
	await _key(KEY_DOWN)
	await _key(KEY_DOWN)
	await _key(KEY_ENTER)
	await _shot("after_contents_jump")
	print("status: ", reader._status.text)
	await _key(KEY_COMMA, false, true)
	await _shot("settings")
	await _key(KEY_ESCAPE)
	await _key(KEY_4, false, true)
	await _shot("free_mode")
	await _key(KEY_1, false, true)
	await _key(KEY_EQUAL, false, true)
	await _key(KEY_EQUAL, false, true)
	await _shot("zoomed_in")
	await _key(KEY_0, false, true)
	await _key(KEY_ESCAPE)
	await _shot("back_to_library")
	print("PASS")
	quit(0)

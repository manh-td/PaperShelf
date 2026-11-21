extends SceneTree
## Checks that mouse wheel / touchpad scrolling over an open Contents or Settings panel
## does not move the page behind it. Run (not headless) from the PaperShelf folder:
##   Godot --path app --script res://tests/panel_scroll_test.gd -- <file.pdf> <scratch_dir>

var main: Control
var reader: Control
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	print(("ok    " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _wheel(pos: Vector2, down := true, count := 4) -> void:
	for i in count:
		for pressed in [true, false]:
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
			e.pressed = pressed
			e.position = pos
			e.global_position = pos
			e.factor = 1.0
			Input.parse_input_event(e)
		await process_frame
	var g := InputEventPanGesture.new()
	g.position = pos
	g.delta = Vector2(0, 3)
	Input.parse_input_event(g)
	await process_frame
	await _wait(0.4)


func _key(code: Key, ctrl := false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		e.ctrl_pressed = ctrl
		Input.parse_input_event(e)
		await process_frame


func _state() -> Array:
	return [reader.current, reader.cam]


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var Library = root.get_node("Library")
	DirAccess.make_dir_recursive_absolute(args[1])
	Library.load_from(args[1])
	var r: Dictionary = Library.import_pdf(args[0])
	var paper: Dictionary = r.get("paper", r.get("duplicate", {}))
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	reader = main._reader
	await _wait(0.3)
	main.open_paper(paper["id"])
	var t0 := Time.get_ticks_msec()
	while not reader.visible and Time.get_ticks_msec() - t0 < 20000:
		await process_frame
	await _key(KEY_HOME)
	await _wait(0.4)
	var center := Vector2(root.size) / 2.0
	var left := Vector2(150, 450)

	# Sanity: the wheel does step when nothing is open.
	var before := _state()
	await _wheel(center, true, 2)
	check(_state()[0] != before[0], "wheel moves the reader when no panel is open")

	await _key(KEY_COMMA, true)
	await _wait(0.3)
	check(reader._settings.visible, "settings open")
	for spot in [center, left, Vector2(1300, 450)]:
		before = _state()
		await _wheel(spot)
		check(_state() == before, "settings open: wheel at %s leaves the page alone" % str(spot))
	await _key(KEY_ESCAPE)
	await _wait(0.3)
	check(not reader._settings.visible, "Esc closes settings")
	check(reader.visible, "Esc on settings keeps the document open")

	await _key(KEY_TAB)
	await _wait(0.4)
	check(reader._contents.is_open, "contents open")
	for spot in [left, center, Vector2(1300, 450)]:
		before = _state()
		await _wheel(spot)
		await _wheel(spot, false)
		check(_state() == before, "contents open: wheel at %s leaves the page alone" % str(spot))
	await _key(KEY_ESCAPE)
	await _wait(0.4)

	before = _state()
	await _wheel(center, true, 2)
	check(_state()[0] != before[0], "wheel moves the reader again after closing panels")

	print("PASS" if fails == 0 else "FAILED: %d" % fails)
	quit(0 if fails == 0 else 1)

extends SceneTree
## Windowed check that zooming (Ctrl+wheel, Ctrl+=, the top-bar control) survives moving
## to the next sentence, and that Figures mode keeps its own zoom.
##   Godot --path app --script res://tests/zoom_test.gd -- <file.pdf> <scratch_dir>

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


func _key(code: Key, ctrl := false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		e.ctrl_pressed = ctrl
		Input.parse_input_event(e)
		await process_frame


func _ctrl_wheel(up: bool, count: int) -> void:
	var pos := Vector2(root.size) / 2.0
	for i in count:
		for pressed in [true, false]:
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
			e.pressed = pressed
			e.ctrl_pressed = true
			e.position = pos
			e.global_position = pos
			e.factor = 1.0
			Input.parse_input_event(e)
		await process_frame
	await _wait(0.4)


## view_scale once the step animation has finished.
func _scale() -> float:
	await _wait(0.5)
	print("      scale %.0f  zoom %.2f  %s" % [reader.view_scale, float(reader.cfg[reader._zoom_key()]), reader._status.text])
	return reader.view_scale


func near(a: float, b: float) -> bool:
	return absf(a - b) <= 0.03 * maxf(absf(b), 1.0)


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
	reader.cfg["zoom"] = 1.0
	reader.cfg["float_zoom"] = 1.0
	await _key(KEY_HOME)
	for i in 12:
		await _key(KEY_RIGHT)
	var s0: float = await _scale()

	# Ctrl+wheel zoom must survive the next sentences.
	await _ctrl_wheel(true, 3)
	var s1: float = reader.view_scale
	check(s1 > s0 * 1.2, "Ctrl+wheel zooms in (%.0f -> %.0f)" % [s0, s1])
	await _key(KEY_RIGHT)
	var s2: float = await _scale()
	check(near(s2, s1), "zoom kept on the next sentence (%.0f vs %.0f)" % [s2, s1])
	await _key(KEY_RIGHT)
	await _key(KEY_RIGHT)
	var s3: float = await _scale()
	check(near(s3, s1), "zoom kept two sentences later (%.0f vs %.0f)" % [s3, s1])
	check(reader._zoom_label.text == "%d%%" % int(round(float(reader.cfg["zoom"]) * 100)), "top bar shows the zoom: %s" % reader._zoom_label.text)

	# Ctrl+wheel out, then Ctrl+0 resets.
	await _ctrl_wheel(false, 6)
	var s4: float = reader.view_scale
	check(s4 < s1, "Ctrl+wheel zooms out")
	var z_out: float = reader.cfg["zoom"]
	await _key(KEY_RIGHT)
	var s_out: float = await _scale()
	await _key(KEY_0, true)
	var s_100: float = await _scale()
	# "Fit column" sizes each page by its own text width, so compare on the same page:
	# the scale there must be exactly the zoom times the 100% scale.
	check(near(s_out, s_100 * z_out), "zoomed-out level kept on the next sentence (%.0f = %.2f x %.0f)" % [s_out, z_out, s_100])
	check(is_equal_approx(float(reader.cfg["zoom"]), 1.0) and reader._zoom_label.text == "100%", "Ctrl+0 goes back to 100%")

	# Top-bar buttons.
	reader._zoom_plus.pressed.emit()
	var s5: float = await _scale()
	check(s5 > s0 * 1.05, "the + button zooms in")
	await _key(KEY_RIGHT)
	check(near(await _scale(), s5), "+ button zoom kept on the next sentence")
	reader._zoom_label.pressed.emit()
	check(is_equal_approx(float(reader.cfg["zoom"]), 1.0), "clicking the percentage resets to 100%")

	# Figures mode has its own zoom.
	await _key(KEY_3, true)
	var f0: float = await _scale()
	await _ctrl_wheel(true, 3)
	var f1: float = reader.view_scale
	await _key(KEY_RIGHT)
	var f2: float = await _scale()
	check(f1 > f0 * 1.2 and float(reader.cfg["float_zoom"]) > 1.2, "Figures mode zooms with its own setting")
	check(is_equal_approx(float(reader.cfg["zoom"]), 1.0), "text zoom untouched by figure zoom")
	await _key(KEY_1, true)
	await _scale()
	check(reader._zoom_label.text == "100%", "back in Sentence mode the label shows the text zoom, not the figure zoom (%s)" % reader._zoom_label.text)

	# The zoom is remembered for the next session.
	var saved := ConfigFile.new()
	saved.load(reader._settings_path)
	check(saved.has_section_key("reader", "float_zoom"), "zoom levels are saved in settings")

	print("PASS" if fails == 0 else "FAILED: %d" % fails)
	quit(0 if fails == 0 else 1)

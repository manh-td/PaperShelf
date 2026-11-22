extends SceneTree
## Windowed check: double-clicking a paper in the library opens it (on each column).
##   Godot --path app --script res://tests/double_click_test.gd -- <scratch_dir> <pdf> <pdf2>

var main: Control
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	print(("ok    " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _click(pos: Vector2, double := false) -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.double_click = double and pressed
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)
		await process_frame


## A real double-click: click, then a second press flagged as double click.
func _double_click(pos: Vector2) -> void:
	await _click(pos)
	await _wait(0.05)
	await _click(pos, true)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var Library = root.get_node("Library")
	DirAccess.make_dir_recursive_absolute(args[0])
	if FileAccess.file_exists(args[0].path_join("library.json")):
		DirAccess.remove_absolute(args[0].path_join("library.json"))
	Library.load_from(args[0])
	for pdf in args.slice(1):
		Library.import_pdf(pdf)
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _wait(0.5)
	var lib: Control = main._library
	var list: Tree = lib._list
	var reader: Control = main._reader
	for col in [0, 1, 2]:
		var item: TreeItem = list.get_root().get_child(col % list.get_root().get_child_count())
		var r: Rect2 = list.get_item_area_rect(item, col)
		var pos: Vector2 = list.get_global_rect().position + r.get_center()
		# Remember the paper: opening it refreshes the list, which replaces its rows.
		var want_id := String(item.get_metadata(0))
		var want_title := item.get_text(0).left(40)
		await _double_click(pos)
		var t0 := Time.get_ticks_msec()
		while not reader.visible and Time.get_ticks_msec() - t0 < 20000:
			await process_frame
		check(reader.visible and reader.doc_id == want_id, "double-click on column %d opens \"%s\"" % [col, want_title])
		if reader.visible:
			reader.close_document()
			await _wait(0.4)
	# A single click only selects.
	var first: TreeItem = list.get_root().get_child(0)
	await _click(list.get_global_rect().position + list.get_item_area_rect(first, 0).get_center())
	await _wait(0.4)
	check(not reader.visible, "a single click does not open the paper")
	print("PASS" if fails == 0 else "FAILED: %d" % fails)
	quit(0 if fails == 0 else 1)

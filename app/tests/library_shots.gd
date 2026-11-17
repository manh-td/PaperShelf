extends SceneTree
## Windowed library check in a scratch library folder: imports PDFs, files them into
## collections, tags them, opens one with Enter, comes back with Esc, saves screenshots.
##   Godot --path app --script res://tests/library_shots.gd -- <scratch_dir> <out_dir> <pdf>...

var main: Control
var lib_view: Control
var out_dir := ""
var shot := 0


func _initialize() -> void:
	_run.call_deferred()


func _key(code: Key, ctrl := false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		e.ctrl_pressed = ctrl
		Input.parse_input_event(e)
		await process_frame


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _shot(label: String) -> void:
	await _wait(0.6)
	shot += 1
	var path := out_dir.path_join("%02d_%s.png" % [shot, label])
	root.get_texture().get_image().save_png(path)
	print("shot ", path)


func _select_rows(indexes: Array) -> void:
	var list: Tree = lib_view._list
	list.deselect_all()
	var item := list.get_root().get_first_child()
	var i := 0
	while item:
		if i in indexes:
			lib_view._select_row(item)
		item = item.get_next()
		i += 1
	lib_view._update_details()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var scratch: String = args[0]
	out_dir = args[1]
	var pdfs: Array = args.slice(2)
	DirAccess.make_dir_recursive_absolute(out_dir)
	for sub in ["papers", "cache"]:
		var d := scratch.path_join(sub)
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(d.path_join(f))
	DirAccess.remove_absolute(scratch.path_join("library.json"))
	DirAccess.make_dir_recursive_absolute(scratch)

	var Library = root.get_node("Library")
	Library.load_from(scratch)
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	lib_view = main._library
	await _wait(0.3)
	await _shot("empty_library")

	lib_view._queue_import(pdfs)
	while not lib_view._import_queue.is_empty():
		await process_frame
	print("status: ", lib_view._status.text)
	lib_view._queue_import([pdfs[0]])   # a duplicate
	while not lib_view._import_queue.is_empty():
		await process_frame
	print("status after duplicate: ", lib_view._status.text)

	var thesis: String = Library.add_collection("Thesis")
	var related: String = Library.add_collection("Related work", thesis)
	var crypto: String = Library.add_collection("Crypto")
	var ids: Array = Library.papers.map(func(p): return p["id"])
	Library.add_to_collection([ids[0], ids[1]], related)
	Library.add_to_collection([ids[2]], crypto)
	Library.add_tags([ids[0], ids[1]], ["physics", "to read"])
	Library.add_tags([ids[2]], ["crypto", "classic"])
	Library.add_tags([ids[3]], ["to read"])
	await _wait(0.3)
	_select_rows([0])
	await _shot("library_one_selected")

	lib_view._select_view("c:" + related)
	await _wait(0.2)
	_select_rows([0, 1])
	await _shot("collection_two_selected")

	lib_view._select_view("all")
	lib_view._tag_filter = ["to read"]
	lib_view._build_tags()
	lib_view._build_list()
	await _shot("tag_filter")
	lib_view._tag_filter = []
	lib_view._build_tags()
	lib_view._build_list()

	# Open the arXiv paper with Enter, read a little, come back with Esc.
	var target := -1
	var item: TreeItem = lib_view._list.get_root().get_first_child()
	var i := 0
	while item:
		if String(Library.paper(item.get_metadata(0))["orig_name"]).begins_with("recognizePDF_test_arXiv"):
			target = i
		item = item.get_next()
		i += 1
	_select_rows([target])
	lib_view._list.grab_focus()
	await _key(KEY_ENTER)
	var t0 := Time.get_ticks_msec()
	while not main._reader.visible and Time.get_ticks_msec() - t0 < 20000:
		await process_frame
	print("reader open: ", main._reader.visible)
	for k in 12:
		await _key(KEY_RIGHT)
	await _shot("reader")
	await _key(KEY_ESCAPE)
	await _wait(0.3)
	await _shot("back_in_library")

	_select_rows([1])
	await _key(KEY_DELETE)
	print("after delete: view=", lib_view._view, " trash=", Library.count("trash"))
	lib_view._select_view("trash")
	await _wait(0.2)
	print("trash view: view=", lib_view._view, " rows=", lib_view._list.get_root().get_child_count(),
		" tree selected=", lib_view._coll_tree.get_selected().get_metadata(0) if lib_view._coll_tree.get_selected() else "none")
	_select_rows([0])
	await _shot("trash")
	print("PASS")
	quit(0)

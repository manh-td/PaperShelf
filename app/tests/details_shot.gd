extends SceneTree
## Screenshot of the details pane for a paper with no tags and no collections.
##   Godot --path app --script res://tests/details_shot.gd -- <file.pdf> <scratch_dir> <out.png>

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var Library = root.get_node("Library")
	DirAccess.make_dir_recursive_absolute(args[1])
	Library.load_from(args[1])
	var r: Dictionary = Library.import_pdf(args[0])
	var paper: Dictionary = r.get("paper", r.get("duplicate", {}))
	Library.remove_tag([paper["id"]], "")
	for t in paper["tags"].duplicate():
		Library.remove_tag([paper["id"]], t)
	for c in paper["collections"].duplicate():
		Library.remove_from_collection([paper["id"]], c)
	root.size = Vector2i(1440, 900)
	var main: Control = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(0.4).timeout
	var lib: Control = main._library
	var item: TreeItem = lib._list.get_root().get_first_child()
	lib._select_row(item)
	lib._update_details()
	await create_timer(0.8).timeout
	root.get_texture().get_image().save_png(args[2])
	# Report the height of the empty-state labels (a word-per-line label is very tall).
	for c in lib._details.get_children():
		if c is HFlowContainer:
			for l in c.get_children():
				if l is Label:
					print("label '%s': size %s" % [l.text, str(l.size)])
	quit(0)

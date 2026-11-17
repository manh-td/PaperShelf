extends SceneTree
## Headless check of the library model in a scratch folder.
##   Godot --headless --path app --script res://tests/library_test.gd -- <scratch_dir> <pdf> <pdf2>

var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	print(("ok    " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var dir: String = args[0]
	if DirAccess.dir_exists_absolute(dir):
		for sub in ["papers", "cache"]:
			for f in DirAccess.get_files_at(dir.path_join(sub)) if DirAccess.dir_exists_absolute(dir.path_join(sub)) else PackedStringArray():
				DirAccess.remove_absolute(dir.path_join(sub).path_join(f))
		DirAccess.remove_absolute(dir.path_join("library.json"))
	DirAccess.make_dir_recursive_absolute(dir)

	var lib = root.get_node("Library")
	lib.load_from(dir)
	check(lib.papers.is_empty(), "starts empty")

	var thesis: String = lib.add_collection("Thesis")
	var related: String = lib.add_collection("Related work", thesis)
	var other: String = lib.add_collection("Other")
	check(lib.collection_path(related) == "Thesis / Related work", "nested collection path")
	check(not lib.move_collection(thesis, related), "refuses to move a collection into its own child")

	var r1: Dictionary = lib.import_pdf(args[1], related)
	check(r1.has("paper"), "import first PDF")
	var p1: Dictionary = r1.get("paper", {})
	print("      title: ", p1.get("title"), " | pages: ", p1.get("pages"))
	check(FileAccess.file_exists(lib.paper_path(p1)), "PDF copied into papers/")
	var r_dup: Dictionary = lib.import_pdf(args[1])
	check(r_dup.has("duplicate"), "same file again is a duplicate")
	var r2: Dictionary = lib.import_pdf(args[2])
	check(r2.has("paper"), "import second PDF")
	var p2: Dictionary = r2.get("paper", {})

	check(lib.query("all").size() == 2, "My Library has 2")
	check(lib.query("unfiled").size() == 1, "Unfiled has 1")
	check(lib.query("c:" + related).size() == 1, "Related work has 1")

	lib.add_tags([p1["id"], p2["id"]], ["to read", "lattice"])
	lib.add_tags([p2["id"]], ["crypto"])
	check(lib.tag_counts() == {"to read": 2, "lattice": 2, "crypto": 1}, "tag counts")
	check(lib.query("all", ["crypto"]).size() == 1, "filter by tag")
	check(lib.query("all", ["to read", "crypto"]).size() == 1, "filter by two tags (AND)")
	lib.rename_tag("lattice", "physics")
	check(lib.tag_counts().has("physics") and not lib.tag_counts().has("lattice"), "rename tag")
	lib.remove_tag([p2["id"]], "physics")
	check(lib.tag_counts()["physics"] == 1, "remove tag from one paper")

	lib.set_title(p1["id"], "My own title")
	check(lib.query("all", [], "own TITLE").size() == 1, "search by title, case-insensitive")

	lib.add_to_collection([p1["id"], p2["id"]], other)
	check(lib.query("c:" + other).size() == 2, "add to second collection")
	check(lib.query("unfiled").is_empty(), "nothing unfiled now")

	lib.trash([p2["id"]])
	check(lib.query("all").size() == 1 and lib.query("trash").size() == 1, "trash")
	lib.restore([p2["id"]])
	check(lib.query("trash").is_empty(), "restore")

	lib.delete_collection(thesis)
	check(lib.collection(related).is_empty(), "deleting a collection deletes its subcollections")
	check(lib.query("all").size() == 2, "papers stay after deleting a collection")

	# Reload from disk.
	lib.load_from(dir)
	check(lib.papers.size() == 2 and lib.collections.size() == 1, "reload from library.json")
	check(lib.paper(p1["id"])["title"] == "My own title", "title kept after reload")

	var path2: String = lib.paper_path(lib.paper(p2["id"]))
	lib.trash([p2["id"]])
	lib.empty_trash()
	check(lib.papers.size() == 1 and not FileAccess.file_exists(path2), "empty trash deletes the file")

	print("PASS" if fails == 0 else "FAILED: %d" % fails)
	quit(0 if fails == 0 else 1)

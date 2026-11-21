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

	# Nesting: top level > 1 > 2, and no deeper.
	var deep: String = lib.add_collection("LLM repair", related)
	check(not deep.is_empty() and lib.depth(deep) == 2, "a sub-subcollection (2 levels down) is allowed")
	check(lib.add_collection("Too deep", deep).is_empty(), "a third nested level is refused")
	check(not lib.can_add_subcollection(deep) and lib.can_add_subcollection(related), "can_add_subcollection follows the limit")
	var side: String = lib.add_collection("Side")
	var side_child: String = lib.add_collection("Side child", side)
	check(not lib.move_collection(side, related), "moving a 2-level collection under a level-1 one is refused (would be 3 deep)")
	check(lib.move_collection(side, thesis), "moving it under a top-level collection is fine (2 deep)")
	check(lib.depth(side_child) == 2, "its subcollection moved along (now 2 deep)")
	check(lib.move_collection(side, ""), "moving it back to the top level")
	lib.delete_collection(side)
	lib.delete_collection(deep)

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

	# Cached data: per paper, everything (incl. leftovers of deleted papers and tmp images).
	DirAccess.make_dir_recursive_absolute(dir.path_join("cache"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("tmp"))
	var cache_files := [String(p1["file"]).get_file() + "_100_v18.json", String(p2["file"]).get_file() + "_200_v18.json",
		"p999.pdf_5_v18.json"]
	for f in cache_files:
		FileAccess.open(dir.path_join("cache").path_join(f), FileAccess.WRITE).store_string("{}")
	FileAccess.open(dir.path_join("tmp/render_1.rgba"), FileAccess.WRITE).store_string("xx")
	check(int(lib.cache_info()["files"]) == 4, "cache_info counts analysis files and tmp images")
	check(int(lib.cache_info([p1["id"]])["files"]) == 1, "cache_info for one paper counts only its file")
	lib.save_comment(p1["id"], {"kind": "text", "s": 0, "e": 0, "quote": "x", "text": "keep me", "subs": []})
	var c_before: int = lib.comments(p1["id"]).size()
	check(int(lib.clear_cache([p1["id"]])["files"]) == 1 and int(lib.cache_info()["files"]) == 3, "clearing one paper's cache leaves the others")
	check(int(lib.clear_cache()["files"]) == 3 and int(lib.cache_info()["files"]) == 0, "clearing everything removes the rest (incl. leftovers)")
	check(FileAccess.file_exists(lib.paper_path(p1)) and lib.papers.size() == 2 and lib.comments(p1["id"]).size() == c_before,
		"papers and comments are kept")

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

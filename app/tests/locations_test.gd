extends SceneTree
## Windowed check of comment locations in the front matter and the first section.
##   Godot --path app --script res://tests/locations_test.gd -- <scratch_dir> <acm.pdf> <arxiv.pdf> <test_paper.pdf>
## For each PDF: the location of a comment on the step whose text starts with a given phrase.

var main: Control
var reader: Control
var Library
var fails := 0

## file name prefix -> [[text the step starts with, sentence offset, expected location start], ...]
const CASES := {
	"fse": [
		["Reasoning Patterns for Efficient", 0, "Title and authors, p. 1"],
		["Large Reasoning Models (LRMs)", 0, "Abstract, sentence 1, p. 1"],
		["Large Reasoning Models (LRMs)", 1, "Abstract, sentence 2, p. 1"],
		["CCS Concepts", 0, "Front matter, p. 1"],
		["1 Introduction", 1, "Section 1 (Introduction), sentence 1, p. 1"],
	],
	"recognizePDF_test_arXiv": [
		["Scaling study of an improved", 0, "Title and authors, p. 1"],
		# The abstract's first sentence runs on from the affiliation line above it (no full stop),
		# so its second sentence is the first one that starts inside the abstract.
		["Lattices of 1/a", 0, "Abstract, sentence 2, p. 1"],
		["The results are compared", 0, "Abstract, sentence 3, p. 1"],
	],
	"test_paper": [
		["Abstract", 1, "Abstract, sentence 1, p. 1"],
		["1 Section Title Number 1", 1, "Section 1 (Section Title Number 1), sentence 1, p. 1"],
	],
}


func _initialize() -> void:
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	print(("ok    " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	Library = root.get_node("Library")
	DirAccess.make_dir_recursive_absolute(args[0])
	if FileAccess.file_exists(args[0].path_join("library.json")):
		DirAccess.remove_absolute(args[0].path_join("library.json"))
	Library.load_from(args[0])
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	reader = main._reader
	await _wait(0.3)
	for pdf in args.slice(1):
		var r: Dictionary = Library.import_pdf(pdf)
		var id: String = r.get("paper", r.get("duplicate", {}))["id"]
		main.open_paper(id)
		var t0 := Time.get_ticks_msec()
		while not reader.visible and Time.get_ticks_msec() - t0 < 30000:
			await process_frame
		await _wait(0.3)
		var cases: Array = []
		for prefix in CASES:
			if String(pdf).get_file().begins_with(prefix):
				cases = CASES[prefix]
		print("== ", String(pdf).get_file())
		for case in cases:
			var found := -1
			for i in reader.steps.size():
				var st: Dictionary = reader.steps[i]
				if reader._range_text(reader._step_key(st), reader._step_end(st)).begins_with(case[0]):
					found = i
					break
			if found < 0:
				check(false, "step starting \"%s\" not found" % case[0])
				continue
			var st: Dictionary = reader.steps[mini(found + int(case[1]), reader.steps.size() - 1)]
			var where: String = reader._location_of({"kind": "text", "s": reader._step_key(st), "e": reader._step_end(st)})
			check(where.begins_with(case[2]), "\"%s\" %+d -> %s" % [case[0], int(case[1]), where])
		reader.close_document()
		await _wait(0.3)
	print("PASS" if fails == 0 else "FAILED: %d" % fails)
	quit(0 if fails == 0 else 1)

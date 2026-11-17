extends SceneTree
## Headless check of the PDF helper through the Pdf bridge.
## Run from the PaperShelf folder:
##   Godot --headless --path app --script res://tests/bridge_test.gd -- <file.pdf> [--fresh]
## --fresh deletes the cached analysis first. Prints page sizes, render timing and
## analysis statistics, and exits with code 1 on failure.

var pdf: Node


func _initialize() -> void:
	_run.call_deferred()


func _fail(msg: String) -> void:
	printerr("FAIL: ", msg, " | ", pdf.last_error() if pdf else "")
	quit(1)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: -- <file.pdf> [--fresh]")
		quit(2)
		return
	var path: String = args[0]
	pdf = root.get_node_or_null("Pdf")
	if pdf == null:
		pdf = load("res://scripts/pdf_bridge.gd").new()
		root.add_child(pdf)
	if not pdf.is_available():
		_fail("helper not available")
		return
	print("helper ok, analyzer version ", pdf.helper_version())

	var t := Time.get_ticks_msec()
	var info: Dictionary = pdf.open_pdf(path)
	if info.is_empty():
		_fail("open_pdf")
		return
	print("opened %s: %d pages, first %s (%d ms)" % [info["name"], info["pages"].size(), str(info["pages"][0]), Time.get_ticks_msec() - t])

	for width in [800, 1600]:
		t = Time.get_ticks_msec()
		var tex: Texture2D = pdf.render_page(0, width)
		if tex == null:
			_fail("render_page width %d" % width)
			return
		print("rendered page 0 at %dx%d (%d ms)" % [tex.get_width(), tex.get_height(), Time.get_ticks_msec() - t])
	var img: Image = pdf.render_page_image(0, 800)
	img.save_png(pdf.storage_dir().path_join("tmp/test_page0.png"))
	print("saved ", pdf.storage_dir().path_join("tmp/test_page0.png"))

	if "--fresh" in args and DirAccess.dir_exists_absolute(pdf.cache_dir()):
		for f in DirAccess.get_files_at(pdf.cache_dir()):
			if f.begins_with(String(info["name"]) + "_"):
				DirAccess.remove_absolute(pdf.cache_dir().path_join(f))

	t = Time.get_ticks_msec()
	pdf.start_analysis()
	var last_shown := -1.0
	while pdf.analysis_state() == "running":
		var p: float = pdf.analysis_progress()
		if p - last_shown >= 0.25:
			print("  analysis %d%%" % int(p * 100))
			last_shown = p
		await process_frame
	if pdf.analysis_state() != "done":
		_fail("analysis state " + pdf.analysis_state())
		return
	var res: Dictionary = pdf.analysis_result()
	var lines: Array = res.get("lines", [])
	var kinds := {}
	var cols := {}
	for l in lines:
		kinds[l["k"]] = kinds.get(l["k"], 0) + 1
		cols[int(l["c"])] = cols.get(int(l["c"]), 0) + 1
	print("analysis done in %d ms: version %s, %d pages, %d lines, %d floats, body size %s" % [
		Time.get_ticks_msec() - t, str(res.get("version")), res.get("pages", []).size(), lines.size(),
		res.get("floats", []).size(), str(res.get("body_size"))])
	print("  kinds: ", kinds)
	print("  columns: ", cols)
	for i in range(min(8, lines.size())):
		var l: Dictionary = lines[i]
		print("  [p%d c%d %s] %s" % [int(l["p"]), int(l["c"]), l["k"], String(l["t"]).left(70)])

	pdf.close_pdf()
	print("PASS")
	quit(0)

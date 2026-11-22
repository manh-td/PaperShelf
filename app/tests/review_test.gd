extends SceneTree
## Windowed test: comment a paper in several categories, then put the review together.
##   Godot --path app --script res://tests/review_test.gd -- <file.pdf> <scratch_dir> <out_dir>
## Expects a paper with numbered sections and a "2.1 ..." subsection.

var main: Control
var reader: Control
var Library
var paper_id := ""
var fails := 0
var out_dir := ""


func _initialize() -> void:
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	print(("ok    " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _key(code: Key, ctrl := false, shift := false, unicode := 0) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		e.ctrl_pressed = ctrl
		e.shift_pressed = shift
		if pressed:
			e.unicode = unicode
		Input.parse_input_event(e)
		await process_frame


func _type(text: String) -> void:
	for ch in text:
		var code: Key = KEY_SPACE if ch == " " else (OS.find_keycode_from_string(ch.to_upper()) as Key)
		if code == KEY_NONE:
			code = KEY_PERIOD
		await _key(code, false, ch != ch.to_lower(), ch.unicode_at(0))


## Comments on the current step: text, category (typed into the filter), points.
func _comment(text: String, category: String, points: Array = []) -> void:
	await _type(text)
	await _key(KEY_TAB)
	await _type(category)
	await _key(KEY_ENTER)
	for p in points:
		await _key(KEY_ENTER)
		await _type(p)
	await _key(KEY_ENTER, true)
	await _wait(0.3)


func _latest() -> Dictionary:
	var cs: Array = Library.comments(paper_id)
	return cs[cs.size() - 1] if not cs.is_empty() else {}


## Goes to sentence n (1 = first) after the heading whose text starts with `head`.
func _go_after_heading(head: String, n: int) -> bool:
	for i in reader.steps.size():
		var st: Dictionary = reader.steps[i]
		if st.get("k", "") == "heading" and reader._range_text(reader._step_key(st), reader._step_end(st)).begins_with(head):
			var sid := int(st["sid"])
			for j in range(i + 1, reader.steps.size()):
				if int(reader.steps[j]["sid"]) == sid + n:
					reader._go_to_step(j)
					await _wait(0.3)
					return true
	return false


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	out_dir = args[2]
	DirAccess.make_dir_recursive_absolute(out_dir)
	Library = root.get_node("Library")
	DirAccess.make_dir_recursive_absolute(args[1])
	if FileAccess.file_exists(args[1].path_join("library.json")):
		DirAccess.remove_absolute(args[1].path_join("library.json"))
	Library.load_from(args[1])
	var r: Dictionary = Library.import_pdf(args[0])
	paper_id = r.get("paper", r.get("duplicate", {}))["id"]
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	reader = main._reader
	await _wait(0.3)
	main.open_paper(paper_id)
	var t0 := Time.get_ticks_msec()
	while not reader.visible and Time.get_ticks_msec() - t0 < 30000:
		await process_frame
	await _wait(0.5)

	# 1. Comments in several categories, with their locations.
	check(await _go_after_heading("2.1", 2), "found sentence 2 of subsection 2.1")
	await _comment("The sampling of traces is not described", "we", ["How many traces per task", "Which temperature"])
	var w: Dictionary = _latest()
	print("      where: ", w.get("where"))
	check(String(w.get("where", "")).begins_with("Section 2 (Methodology), Subsection 2.1 (Study Setup), sentence 2, p. "),
		"location of a Weakness: %s" % w.get("where"))

	check(await _go_after_heading("1 Introduction", 1), "found the first sentence of the Introduction")
	await _comment("Studies reasoning traces of LRMs on four coding tasks", "pa")
	await _comment_on_next("Clear motivation", "str")
	check(await _go_after_heading("2.2", 1), "found subsection 2.2")
	await _comment("Is the taxonomy validated by a second annotator", "q")
	await _comment_on_next("Similar pattern mining exists for code models", "nov")
	await _comment_on_next("Figure fonts are too small to read", "pres")

	# A table comment (Figures mode).
	await _key(KEY_3, true)
	await _wait(0.4)
	await _comment("Report variance across runs", "rig")
	var tw := String(_latest().get("where", ""))
	print("      table where: ", tw)
	check(tw.begins_with("Table ") or tw.begins_with("Figure "), "a figure/table comment is named by its label: %s" % tw)
	await _key(KEY_1, true)
	await _wait(0.3)

	# 2. Ctrl+R opens the review, put together from the comments.
	await _key(KEY_R, true)
	await _wait(0.5)
	var review: Control = main._review
	check(review.visible and not reader.visible, "Ctrl+R opens the review screen")
	var ed: Dictionary = review._edits
	check(String(ed["weaknesses"].text).begins_with("- The sampling of traces is not described (Section 2 (Methodology), Subsection 2.1 (Study Setup), sentence 2"),
		"Weaknesses item quotes its location and text")
	check(String(ed["weaknesses"].text).contains("\n  - How many traces per task"), "points become sub-bullets")
	check(String(ed["summary"].text).begins_with("Studies reasoning traces of LRMs on four coding tasks."), "Paper summary is prose")
	check(String(ed["strengths"].text).begins_with("- Clear motivation"), "Strength listed")
	check(String(ed["questions"].text).begins_with("- Is the taxonomy validated"), "Question listed")
	check(String(ed["novelty"].text).begins_with("> Section 2 (Methodology), Subsection 2.2"), "detailed comments start with the quoted location")
	check(String(ed["presentation"].text).contains("Figure fonts are too small"), "Presentation filled")
	check(String(ed["soundness"].text).contains("Report variance across runs"), "Rigor/Soundness goes to Soundness")

	# 3. Hand-written parts and merit are saved.
	ed["intro"].text = "Overall, a solid empirical study. My main concern is the sampling."
	ed["intro"].text_changed.emit()
	review._merit.select(3)   # Weak reject
	review._merit.item_selected.emit(3)
	await _wait(1.2)
	var saved: Dictionary = Library.review(paper_id)
	check(String(saved["sections"]["intro"]).begins_with("Overall, a solid"), "the introduction is saved as you type")
	check(saved["merit"] == "Weak reject", "merit saved")
	await root.get_texture().get_image().save_png(out_dir.path_join("review_screen.png"))

	# 4. The review follows the comments: a new comment, and a re-categorized one, show up
	#    in the right sections the next time the review opens (sections not edited by hand).
	await _key(KEY_ESCAPE)
	await _wait(0.3)
	check(reader.visible and not review.visible, "Esc goes back to the reader")
	check(await _go_after_heading("2.3", 1), "found subsection 2.3")
	await _comment("Support threshold is arbitrary", "we")
	var motivation: Dictionary = {}
	for c in Library.comments(paper_id):
		if c["text"] == "Clear motivation":
			motivation = c.duplicate(true)
	motivation["category"] = "Weakness"     # was Strength
	Library.save_comment(paper_id, motivation)
	await _key(KEY_R, true)
	await _wait(0.4)
	check(String(ed["weaknesses"].text).contains("\n- Support threshold is arbitrary"), "a new comment appears in Weaknesses by itself")
	check(String(ed["weaknesses"].text).begins_with("- Clear motivation"), "a comment changed to Weakness moves to Weaknesses (reading order)")
	check(String(ed["strengths"].text).strip_edges().is_empty(), "... and leaves Strengths")
	check(String(ed["intro"].text).begins_with("Overall, a solid"), "the introduction is kept")

	# 5. A section edited by hand is kept; when its comments change, a note offers an update.
	ed["weaknesses"].text = "- My own wording of the weaknesses"
	ed["weaknesses"].text_changed.emit()
	await _key(KEY_ESCAPE)
	await _wait(0.3)
	check(await _go_after_heading("2.3", 2), "found sentence 2 of subsection 2.3")
	await _comment("Only two models are studied", "we")
	await _key(KEY_R, true)
	await _wait(0.4)
	check(String(ed["weaknesses"].text) == "- My own wording of the weaknesses", "an edited section is not overwritten")
	check(review._notes["weaknesses"].visible, "its note says the comments changed")
	check(not review._notes["presentation"].visible, "unedited sections show no note")
	review._update_section("weaknesses")
	check(String(ed["weaknesses"].text).contains("Only two models are studied") and not review._notes["weaknesses"].visible,
		"Update from comments refreshes the section and hides the note")

	# 6. Rebuild refreshes every comment section, also edited ones; hand-written parts stay.
	ed["presentation"].text = "edited by hand"
	ed["presentation"].text_changed.emit()
	review._rebuild()
	check(String(ed["presentation"].text).contains("Figure fonts are too small") and String(ed["intro"].text).begins_with("Overall"),
		"Rebuild refreshes edited sections and keeps the introduction")

	# 7. A review made by the earlier version (no record of what was generated): its filled
	#    sections count as edited (kept, with a note if out of date); empty ones are filled.
	await _key(KEY_ESCAPE)   # leave the review first; it saves what is on screen
	await _wait(0.2)
	var old: Dictionary = Library.review(paper_id).duplicate(true)
	old.erase("generated")
	old["sections"]["novelty"] = "old text from before"
	old["sections"]["strengths"] = ""
	old["sections"]["questions"] = ""
	Library.save_review(paper_id, old)
	await _key(KEY_R, true)
	await _wait(0.4)
	check(String(ed["novelty"].text) == "old text from before" and review._notes["novelty"].visible, "old review: filled section kept, with a note")
	check(String(ed["questions"].text).begins_with("- Is the taxonomy validated"), "old review: empty Questions filled from the comments")

	# Export Markdown.
	review._update_section("novelty")
	var md_path := out_dir.path_join("review.md")
	review._export_to(md_path)
	var md := FileAccess.get_file_as_string(md_path)
	var order := ["# Reasoning Patterns", "## Overall merit: Weak reject", "## Paper summary", "## Weaknesses",
		"## Detailed comments for authors", "Overall, a solid", "**Originality/Novelty**", "**Soundness**", "**Presentation**",
		"## Questions for authors’ response"]
	var pos := -1
	var in_order := true
	for h in order:
		var at := md.find(h)
		if at <= pos:
			in_order = false
			print("      out of order or missing: ", h)
		pos = at
	check(in_order, "Markdown has the sections in review order")
	check(not md.contains("**Verifiability**"), "empty parts are left out of the Markdown")
	check(md.contains("Unlike conventional code language models") and not md.contains("conventional 33"), "quotes leave out the margin line numbers")
	check(md.contains("problem-solving") and not md.contains("problem- "), "words split at a line end are joined in quotes")
	check(not md.contains(" tr …"), "long quotes are cut at a word boundary")
	print("----- review.md -----\n", md, "---------------------")
	await _key(KEY_ESCAPE)
	print("PASS" if fails == 0 else "FAILED: %d" % fails)
	quit(0 if fails == 0 else 1)


func _comment_on_next(text: String, category: String) -> void:
	await _key(KEY_RIGHT)
	await _wait(0.2)
	await _comment(text, category)

extends Control
## App shell: the library screen and the reader. Opening a paper analyzes it
## (cached after the first time) and switches to the reader; Esc goes back.
## Global key: F11 fullscreen.

const ReaderView := preload("res://scripts/reader_view.gd")
const LibraryView := preload("res://scripts/library_view.gd")
const ReviewView := preload("res://scripts/review_view.gd")

var _library: LibraryView
var _reader: ReaderView
var _loading_id := ""
var _review: ReviewView
var _review_from: Control = null   # the screen to go back to


func _ready() -> void:
	theme = _make_theme()

	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.12, 0.14)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_library = LibraryView.new()
	_library.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_library.open_requested.connect(open_paper)
	_library.review_requested.connect(open_review)
	add_child(_library)

	_reader = ReaderView.new()
	_reader.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reader.visible = false
	_reader.closed.connect(_on_reader_closed)
	_reader.review_requested.connect(open_review)
	add_child(_reader)

	_review = ReviewView.new()
	_review.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_review.closed.connect(_on_review_closed)
	add_child(_review)


	if not Pdf.is_available():
		_library.set_busy("The PDF helper could not start: %s" % Pdf.last_error())
	_library.focus_list.call_deferred()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and k.keycode == KEY_F11:
		var w := get_window()
		w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ opening

func open_paper(id: String) -> void:
	if not _loading_id.is_empty():
		return
	var p := Library.paper(id)
	if p.is_empty():
		return
	var path := Library.paper_path(p)
	if not FileAccess.file_exists(path):
		_library.set_busy("The PDF file for this paper is missing: " + path)
		return
	_library.set_busy("Opening %s…" % Library.display_title(p))
	var info := Pdf.open_pdf(path)
	if info.is_empty():
		_library.set_busy("Could not open this PDF: " + Pdf.last_error())
		return
	if not Pdf.start_analysis("", Library.root_dir().path_join("cache")):
		_library.set_busy("Could not start text analysis.")
		return
	_loading_id = id


func _process(_delta: float) -> void:
	if _loading_id.is_empty():
		return
	var state := Pdf.analysis_state()
	var p := Library.paper(_loading_id)
	if state == "running":
		_library.set_busy("Analyzing the page layout of \"%s\"…" % Library.display_title(p), Pdf.analysis_progress())
	elif state == "done":
		var result := Pdf.analysis_result()
		var id := _loading_id
		_loading_id = ""
		_library.set_busy("")
		Library.mark_read(id)
		_library.visible = false
		_reader.visible = true
		_reader.open_document(id, Library.display_title(p), result)
	elif state == "error" or state == "idle":
		_loading_id = ""
		_library.set_busy("Text analysis failed: " + Pdf.last_error())
		Pdf.close_pdf()


## Shows the Review screen for a paper, from the library or the reader; Back returns there.
func open_review(id: String) -> void:
	if Library.paper(id).is_empty():
		return
	_review_from = _reader if _reader.visible else _library
	_reader.visible = false
	_library.visible = false
	_review.open(id)


func _on_review_closed() -> void:
	var back: Control = _review_from if _review_from else _library
	back.visible = true
	if back == _library:
		_library.refresh()
		_library.focus_list()


func _on_reader_closed() -> void:
	_reader.visible = false
	_library.visible = true
	_library.refresh()
	_library.focus_list()


# ------------------------------------------------------------------ theme

func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 16

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.22, 0.23, 0.27)
	normal.set_corner_radius_all(6)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 5
	normal.content_margin_bottom = 5
	var hover := normal.duplicate()
	hover.bg_color = Color(0.28, 0.30, 0.35)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.85, 0.65, 0.10)
	var disabled := normal.duplicate()
	disabled.bg_color = Color(0.18, 0.18, 0.20)
	var focus := normal.duplicate()
	focus.draw_center = false
	focus.set_border_width_all(1)
	focus.border_color = Color(0.85, 0.65, 0.10)

	for type in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", type, normal)
		t.set_stylebox("hover", type, hover)
		t.set_stylebox("pressed", type, pressed)
		t.set_stylebox("disabled", type, disabled)
		t.set_stylebox("focus", type, focus)
	# Toggled tag buttons stay highlighted.
	t.set_stylebox("hover_pressed", "Button", pressed)
	t.set_color("font_pressed_color", "Button", Color(0.1, 0.1, 0.1))
	t.set_color("font_hover_pressed_color", "Button", Color(0.1, 0.1, 0.1))
	t.set_color("font_color", "Label", Color(0.93, 0.93, 0.95))
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		t.set_stylebox(state, "CheckBox", StyleBoxEmpty.new())
	t.set_constant("v_separation", "Tree", 6)
	return t

extends Control
## PaperShelf reading view (desktop version of HighReader's reader).
## Pages are stacked vertically in "doc units" (page width = 1.0). `view_scale` is
## screen pixels per doc unit, and `cam` the doc point at the view's top-left.
##
## Modes:
##   sentence - one sentence per step (default)
##   line     - one text line per step
##   floats   - one figure / table per step
##   free     - no highlight; scroll, drag and Ctrl+wheel zoom to look around
##
## Keys: Right/Down/Space/Enter next, Left/Up/Shift+Space/Backspace back, PageDown/PageUp
## next/previous page, Home/End, Ctrl+1-4 mode, Ctrl+=/-/0 zoom, Tab contents, Ctrl+, settings,
## Ctrl+Down/Up next/previous comment, Esc back.
## Comments: typing any character starts a comment on the highlighted step (comment_editor.gd).
## Mouse: wheel steps (scrolls in Free mode), click a word to jump there, drag to look around.

signal closed

const Steps := preload("res://scripts/steps_builder.gd")
const SettingsPanel := preload("res://scripts/settings_panel.gd")
const ContentsPanel := preload("res://scripts/contents_panel.gd")
const CommentEditor := preload("res://scripts/comment_editor.gd")

const MODES := ["sentence", "line", "floats", "free"]
const MODE_NAMES := ["Sentence", "Line", "Figures", "Free"]
const PAGE_GAP := 0.02
const FOCUS_Y := 0.40          # where the highlight sits, as a share of the usable height
const MAX_TEXTURE_WIDTH := 4096
const READ_WIDTH := 720.0      # comfortable width (px) for a column or highlight at zoom 1
const PAGE_WIDTH := 1100.0     # page width (px) for "Fit page width" at zoom 1
const KEY_SCALE := 10000
const MAX_RENDERS_IN_FLIGHT := 2

const DEFAULTS := {
	"mode": "sentence",
	"fit": "column",
	"follow": "center",
	"zoom": 1.0,
	"color": Color(1.0, 0.80, 0.10),
	"color_by_kind": true,
	"style": "box",
	"fill": 0.22,
	"dim": 0.42,
	"skip_side": false,
}
const KIND_COLORS := {
	"heading": Color(0.30, 0.65, 1.0),
	"figure": Color(0.35, 0.85, 0.45),
	"table": Color(0.75, 0.50, 1.0),
}

var cam := Vector2.ZERO:
	set(v):
		cam = v
		queue_redraw()
var view_scale := 1000.0:
	set(v):
		view_scale = v
		queue_redraw()

var cfg := DEFAULTS.duplicate()
var doc_id := ""
var page_rects: Array[Rect2] = []
var all_lines: Array = []       # every analyzed line; "i" = reading-order index
var floats: Array = []          # analysis floats, each with "key" = reading-order index
var lines: Array = []           # lines read in text modes
var words: Array = []           # words[li] for lines[li]
var steps: Array = []
var contents: Array = []        # [{"t", "l"}] headings
var current := 0
var text_available := true
var _col_bounds := {}           # "page:col" -> Vector2(x0, x1); "page:all" = all text on the page

var _textures := {}             # page -> {"tex": Texture2D, "w": int}
var _pending := {}              # page -> {"id": request id, "w": int}
var _tween: Tween
var _pressed := false
var _dragging := false
var _press_pos := Vector2.ZERO
var _progress := ConfigFile.new()
var _settings_file := ConfigFile.new()
var _progress_path := ""
var _settings_path := ""

var _anchor := 0
var _active_mode := ""

var _top: PanelContainer
var _bottom: PanelContainer
var _title: Label
var _status: Label
var _hint: Label
var _bar: ProgressBar
var _mode_btn: OptionButton
var _notice: Label
var _settings: SettingsPanel
var _contents: ContentsPanel
var _editor: CommentEditor
var _side: VBoxContainer        # comments on the current step, right of the page

# Comments of this document (Library dicts with "s"/"e" keys) and a flat word index
# for finding commented text: _flat_keys[i] / _flat_words[i], in reading order.
var _comments: Array = []
var _flat_keys: PackedInt64Array = PackedInt64Array()
var _flat_words: PackedStringArray = PackedStringArray()
var _all_words := {}            # reading-order line index -> line_words()


func _ready() -> void:
	clip_contents = true
	_progress_path = Library.root_dir().path_join("progress.cfg")
	_settings_path = Pdf.data_path("settings.cfg")
	_progress.load(_progress_path)
	_settings_file.load(_settings_path)
	for k in DEFAULTS:
		cfg[k] = _settings_file.get_value("reader", k, DEFAULTS[k])
	_build_ui()
	resized.connect(_on_resized)


# ------------------------------------------------------------------ public API

## Opens an analyzed document. `id` keys the saved reading position.
func open_document(id: String, title: String, analysis: Dictionary) -> void:
	doc_id = id
	_title.text = title
	_textures.clear()
	_pending.clear()

	page_rects.clear()
	var y := 0.0
	for size in analysis.get("pages", []):
		var h: float = float(size[1]) / max(float(size[0]), 1.0)
		page_rects.append(Rect2(0, y, 1.0, h))
		y += h + PAGE_GAP

	all_lines = analysis.get("lines", [])
	for i in all_lines.size():
		all_lines[i]["i"] = i
	floats = analysis.get("floats", [])
	for fi in floats.size():
		floats[fi]["key"] = 1 << 30
	for l in all_lines:
		var f := int(l.get("f", -1))
		if f >= 0 and f < floats.size():
			floats[f]["key"] = min(int(floats[f]["key"]), int(l["i"]))

	_rebuild_text()
	_col_bounds.clear()
	for l in all_lines:
		for ck in ["%d:%d" % [int(l["p"]), int(l.get("c", 0))], "%d:all" % int(l["p"])]:
			var b: Vector2 = _col_bounds.get(ck, Vector2(INF, -INF))
			_col_bounds[ck] = Vector2(min(b.x, float(l["x0"])), max(b.y, float(l["x1"])))
	text_available = not lines.is_empty()

	_notice.visible = not text_available
	for i in 3:
		_mode_btn.set_item_disabled(i, not text_available)
	var mode: String = cfg["mode"] if text_available else "free"
	var saved: int = _progress.get_value("progress", doc_id, 0)
	view_scale = _page_fit_scale()
	cam = Vector2.ZERO
	_build_word_index()
	_load_comments()
	_set_mode(mode, saved * KEY_SCALE, false)


## Esc: close Settings or Contents if open, otherwise leave the document.
func go_back() -> void:
	if _editor.visible:
		_editor.visible = false
		_refresh_side()
	elif _settings.visible:
		_settings.close()
	elif _contents.is_open:
		_contents.close()
	else:
		close_document()


func close_document() -> void:
	_save_progress()
	_editor.visible = false
	_contents.close()
	_settings.close()
	_textures.clear()
	_pending.clear()
	Pdf.close_pdf()
	closed.emit()


## Saved reading position as 0..1, or -1 if the document was never opened.
static func saved_progress(id: String, progress_path: String) -> float:
	var c := ConfigFile.new()
	if c.load(progress_path) != OK or not c.has_section_key("progress", id):
		return -1.0
	var total: int = c.get_value("totals", id, 0)
	return float(c.get_value("progress", id, 0)) / max(total - 1, 1)


# ------------------------------------------------------------------ modes & steps
#
# Positions are "keys": reading-order line index * KEY_SCALE + word index.
# `_anchor` is the reading position. It only changes when the reader moves,
# never when switching modes, so switching modes always comes back to the same place.

func _mode() -> String:
	return MODES[_mode_btn.selected]


func set_mode(mode: String) -> void:
	if mode != "free" and not text_available:
		return
	var key := _current_key()
	cfg["mode"] = mode
	_save_settings()
	_set_mode(mode, key, true)


func _set_mode(mode: String, key: int, animate: bool) -> void:
	_mode_btn.select(MODES.find(mode))
	_active_mode = mode
	_anchor = key
	match mode:
		"sentence":
			steps = Steps.build_sentence_steps(lines, words)
		"line":
			steps = Steps.build_line_steps(lines, words)
		"floats":
			steps = Steps.build_float_steps(floats)
		_:
			steps = []
	current = _step_at_key(key)
	if mode == "free":
		_update_status()
		_refresh_side()
		queue_redraw()
	else:
		_go_to_current(animate)


## The step containing position `key`, or the first one after it.
func _step_at_key(key: int) -> int:
	for i in steps.size():
		if _step_end(steps[i]) >= key:
			return i
	return max(steps.size() - 1, 0)


func _step_key(step: Dictionary) -> int:
	if step.has("float"):
		return int(floats[int(step["float"])]["key"]) * KEY_SCALE
	var s: Dictionary = step["segs"][0]
	return int(lines[int(s["l"])]["i"]) * KEY_SCALE + int(s["a"])


func _step_end(step: Dictionary) -> int:
	if step.has("float"):
		return int(floats[int(step["float"])]["key"]) * KEY_SCALE
	var segs: Array = step["segs"]
	var s: Dictionary = segs[segs.size() - 1]
	return int(lines[int(s["l"])]["i"]) * KEY_SCALE + int(s["b"])


func _step_page(step: Dictionary) -> int:
	return _step_rects(step)[0][0]


## The reading position now (Free mode: what is in view).
func _current_key() -> int:
	if _active_mode == "free":
		return _key_at_view()
	return _anchor


## Key of the earliest line in view (Free mode).
func _key_at_view() -> int:
	var top := cam.y + _usable().position.y / view_scale
	var bottom := cam.y + size.y / view_scale
	var best := -1
	for l in all_lines:
		var y := _line_rect(l).position.y
		if y >= top and y <= bottom and (best < 0 or int(l["i"]) < best):
			best = int(l["i"])
	if best < 0:
		# Nothing in view (e.g. an image page): the first line on the page in view.
		var p := _page_at_view()
		for l in all_lines:
			if int(l["p"]) >= p:
				return int(l["i"]) * KEY_SCALE
	return max(best, 0) * KEY_SCALE


func _go_to_step(index: int) -> void:
	if steps.is_empty():
		return
	current = clampi(index, 0, steps.size() - 1)
	_anchor = _step_key(steps[current])
	_go_to_current(true)


func next_step() -> void:
	if _active_mode == "free":
		_pan(Vector2(0, _usable().size.y * 0.15))
	elif current < steps.size() - 1:
		_go_to_step(current + 1)
	else:
		_status.text = "End of document"


func prev_step() -> void:
	if _active_mode == "free":
		_pan(Vector2(0, -_usable().size.y * 0.15))
	elif current > 0:
		_go_to_step(current - 1)


## First step on the next page (dir = 1) or the previous one (dir = -1).
func page_step(dir: int) -> void:
	if _active_mode == "free" or steps.is_empty():
		_pan(Vector2(0, dir * _usable().size.y * 0.9))
		return
	var page := _step_page(steps[current])
	if dir > 0:
		for i in range(current + 1, steps.size()):
			if _step_page(steps[i]) > page:
				_go_to_step(i)
				return
		_go_to_step(steps.size() - 1)
	else:
		# Back to the start of this page, or to the start of the previous one.
		var target_page := page
		var first := current
		while first > 0 and _step_page(steps[first - 1]) == page:
			first -= 1
		if first == current:
			target_page = page - 1
			while first > 0 and _step_page(steps[first - 1]) >= target_page:
				first -= 1
		_go_to_step(first)


func go_to_start() -> void:
	if _active_mode == "free":
		_animate_to(Vector2(cam.x, -_usable().position.y / view_scale), view_scale)
	else:
		_go_to_step(0)


func go_to_end() -> void:
	if _active_mode == "free":
		var last := page_rects[page_rects.size() - 1]
		_animate_to(Vector2(cam.x, last.end.y - size.y / view_scale + 0.02), view_scale)
	else:
		_go_to_step(steps.size() - 1)


func jump_to_contents(index: int) -> void:
	if index < 0 or index >= contents.size():
		return
	var line: Dictionary = lines[int(contents[index]["l"])]
	if _active_mode == "free":
		var r := _line_rect(line)
		_animate_to(Vector2(cam.x, r.position.y - _usable().position.y / view_scale - 0.02), view_scale)
	else:
		if _active_mode == "floats":
			set_mode("sentence")
		_go_to_step(_step_at_key(int(line["i"]) * KEY_SCALE))


## Zoom: +1 bigger, -1 smaller, 0 back to normal.
func change_zoom(dir: int) -> void:
	if _active_mode == "free":
		var center := size / 2.0
		var before := cam + center / view_scale
		view_scale = clamp(view_scale * (1.15 if dir > 0 else 1.0 / 1.15) if dir != 0 else _page_fit_scale(), 50.0, 30000.0)
		cam = before - center / view_scale
		return
	var z: float = cfg["zoom"]
	z = 1.0 if dir == 0 else clamp(z * (1.1 if dir > 0 else 1.0 / 1.1), 0.4, 4.0)
	cfg["zoom"] = z
	_save_settings()
	_go_to_current(true)
	_flash("Zoom %d%%" % int(round(z * 100)))


# ------------------------------------------------------------------ framing

## Doc-space rectangles the step highlights, each with its page: [[page, Rect2], ...].
func _step_rects(step: Dictionary) -> Array:
	var out := []
	if step.has("float"):
		var f: Dictionary = floats[int(step["float"])]
		out.append([int(f["p"]), _norm_rect(int(f["p"]), f)])
		return out
	for s in step["segs"]:
		out.append([int(lines[int(s["l"])]["p"]), _seg_rect(s)])
	return out


## Scale at which a whole page fits the usable area.
func _page_fit_scale() -> float:
	var usable := _usable()
	var h := page_rects[0].size.y if not page_rects.is_empty() else 1.3
	return max(min(usable.size.x * 0.98, usable.size.y * 0.98 / h), 50.0)


func _go_to_current(animate: bool) -> void:
	if steps.is_empty():
		_status.text = "No figures or tables found." if _mode() == "floats" else "Nothing to read here."
		queue_redraw()
		return
	var step: Dictionary = steps[current]
	var is_float := step.has("float")
	var rects := _step_rects(step)

	# Frame the part of the step on the first piece's page and column.
	var col := 0
	var page: int = rects[0][0]
	if not is_float:
		col = int(lines[int(step["segs"][0]["l"])].get("c", 0))
	var focus: Rect2 = rects[0][1]
	for i in range(1, rects.size()):
		var li := int(step["segs"][i]["l"])
		if rects[i][0] == page and int(lines[li].get("c", 0)) == col:
			focus = focus.merge(rects[i][1])

	var usable := _usable()
	var zoom: float = cfg["zoom"]
	var read_w: float = min(usable.size.x * 0.96, READ_WIDTH * zoom)
	var pr := page_rects[page]
	var s := view_scale
	var center_x := focus.get_center().x
	var fit := "float" if is_float else String(cfg["fit"])
	var whole_page := false
	match fit:
		"float":
			s = min(usable.size.x * 0.92 / max(focus.size.x, 0.01), usable.size.y * 0.85 / max(focus.size.y, 0.01))
			s = min(s, READ_WIDTH * 2.5 * zoom)
		"text":
			# The highlight fills the reading width. Very tall steps are fitted by height.
			var line_h: float = rects[0][1].size.y
			s = read_w / max(focus.size.x + line_h * 0.5, 0.01)
			s = min(s, usable.size.y * 0.85 / max(focus.size.y, 0.001))
		"column":
			var cb: Vector2 = _col_bounds.get("%d:%d" % [page, col], _col_bounds.get("%d:all" % page, Vector2(0.05, 0.95)))
			if col == 0:
				cb = _col_bounds.get("%d:all" % page, cb)
			s = read_w / max(cb.y - cb.x + 0.03, 0.1)
			center_x = pr.position.x + (cb.x + cb.y) / 2.0 * pr.size.x
		"width":
			s = min(usable.size.x * 0.98, PAGE_WIDTH * zoom)
			center_x = 0.5
		_:   # "page"
			s = _page_fit_scale() * zoom
			center_x = 0.5
			whole_page = zoom <= 1.0
	s = clamp(s, 50.0, 30000.0)

	var x := center_x - size.x / (2.0 * s)
	var y: float
	if whole_page:
		y = pr.get_center().y - (usable.position.y + usable.size.y / 2.0) / s
	elif focus.size.y * s > usable.size.y * 0.6:
		y = focus.position.y - (usable.position.y + usable.size.y * 0.08) / s
	else:
		y = focus.get_center().y - (usable.position.y + usable.size.y * FOCUS_Y) / s
		if String(cfg["follow"]) == "minimal" and absf(s - view_scale) < 0.5 and not is_float:
			# Only scroll once the highlight gets near the top or bottom.
			var top_y := (focus.position.y - cam.y) * s
			var bottom_y := (focus.end.y - cam.y) * s
			if top_y >= usable.position.y + usable.size.y * 0.08 and bottom_y <= usable.end.y - usable.size.y * 0.15:
				y = cam.y
			elif bottom_y > usable.end.y - usable.size.y * 0.15:
				y = focus.position.y - (usable.position.y + usable.size.y * 0.12) / s

	if animate:
		_animate_to(Vector2(x, y), s)
	else:
		if _tween:
			_tween.kill()
		view_scale = s
		cam = Vector2(x, y)
	_update_status()
	_save_progress()
	_refresh_side()
	queue_redraw()


var _target_scale := 1000.0

func _animate_to(target_cam: Vector2, target_scale: float) -> void:
	_target_scale = target_scale
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "cam", target_cam, 0.22)
	_tween.tween_property(self, "view_scale", target_scale, 0.22)


## Screen area between the top and bottom bars.
func _usable() -> Rect2:
	var top := _top.size.y if _top else 0.0
	var bottom := _bottom.size.y if _bottom else 0.0
	return Rect2(0, top, size.x, max(size.y - top - bottom, 1.0))


func _update_status() -> void:
	var mode := _mode()
	if mode == "free" or steps.is_empty():
		var p := _page_at_view()
		_status.text = "Free view   ·   Page %d / %d   ·   %d%%" % [p + 1, page_rects.size(), int(round(view_scale / _page_fit_scale() * 100))]
		_bar.max_value = max(page_rects.size() - 1, 1)
		_bar.value = p
		return
	var step: Dictionary = steps[current]
	var page := _step_page(step)
	var noun: String = {"sentence": "Sentence", "line": "Line", "floats": "Figure/Table"}[mode]
	var number := current + 1
	var total := steps.size()
	var part := ""
	if step.has("sid"):
		# Sentences split across columns/pages count once; show which part this is.
		number = int(step["sid"]) + 1
		total = int(steps[steps.size() - 1]["sid"]) + 1
		if int(step["parts"]) > 1:
			part = " (part %d of %d)" % [int(step["part"]), int(step["parts"])]
	_status.text = "%s %d / %d%s   ·   Page %d / %d" % [noun, number, total, part, page + 1, page_rects.size()]
	_bar.max_value = max(steps.size() - 1, 1)
	_bar.value = current


func _page_at_view() -> int:
	var mid := cam.y + size.y * 0.5 / view_scale
	for i in page_rects.size():
		if mid <= page_rects[i].end.y + PAGE_GAP:
			return i
	return max(page_rects.size() - 1, 0)


func _save_progress() -> void:
	if doc_id.is_empty():
		return
	_progress.set_value("progress", doc_id, _current_key() / KEY_SCALE)
	_progress.set_value("totals", doc_id, all_lines.size())
	_progress.save(_progress_path)


func _save_settings() -> void:
	for k in cfg:
		_settings_file.set_value("reader", k, cfg[k])
	_settings_file.save(_settings_path)


var _flash_tween: Tween

## Shows a short message in the status line.
func _flash(text: String) -> void:
	_hint.text = text
	if _flash_tween:
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_interval(1.2)
	_flash_tween.tween_callback(func(): _hint.text = _hint_text())


func _hint_text() -> String:
	return "Type to comment   →/← next/back   Ctrl+↓/↑ comments   Tab contents   Ctrl+, settings   Esc library"


# ------------------------------------------------------------------ geometry

func _to_screen(r: Rect2) -> Rect2:
	return Rect2((r.position - cam) * view_scale, r.size * view_scale)


func _to_doc(screen_pos: Vector2) -> Vector2:
	return cam + screen_pos / view_scale


func _norm_rect(page: int, d: Dictionary) -> Rect2:
	var pr := page_rects[page]
	var x0 := float(d["x0"])
	var y0 := float(d["y0"])
	return Rect2(pr.position.x + x0 * pr.size.x, pr.position.y + y0 * pr.size.y,
		(float(d["x1"]) - x0) * pr.size.x, (float(d["y1"]) - y0) * pr.size.y)


func _line_rect(line: Dictionary) -> Rect2:
	var p := int(line["p"])
	if p < 0 or p >= page_rects.size():
		return Rect2()
	return _norm_rect(p, line)


## Doc-space rectangle covering words a..b of one text line.
func _seg_rect(seg: Dictionary) -> Rect2:
	var li := int(seg["l"])
	var line: Dictionary = lines[li]
	var r := _line_rect(line)
	var ws: Array = words[li]
	if ws.is_empty():
		return r
	var pr := page_rects[int(line["p"])]
	var x0 := pr.position.x + float(ws[int(seg["a"])]["x0"]) * pr.size.x
	var x1 := pr.position.x + float(ws[int(seg["b"])]["x1"]) * pr.size.x
	return Rect2(x0, r.position.y, x1 - x0, r.size.y)


func _visible_pages() -> Array[int]:
	var out: Array[int] = []
	var top := cam.y
	var bottom := cam.y + size.y / view_scale
	for i in page_rects.size():
		var r := page_rects[i]
		if r.end.y >= top and r.position.y <= bottom:
			out.append(i)
	return out


## Key of the word under a screen position, or -1.
func _key_at(screen_pos: Vector2) -> int:
	var p := _to_doc(screen_pos)
	var best := -1
	var best_d := INF
	for li in lines.size():
		var r := _line_rect(lines[li])
		var grown := r.grow_individual(0.004, r.size.y * 0.3, 0.004, r.size.y * 0.3)
		if not grown.has_point(p):
			continue
		var pr := page_rects[int(lines[li]["p"])]
		var ws: Array = words[li]
		for wi in ws.size():
			var x0: float = pr.position.x + float(ws[wi]["x0"]) * pr.size.x
			var x1: float = pr.position.x + float(ws[wi]["x1"]) * pr.size.x
			var d: float = 0.0 if p.x >= x0 and p.x <= x1 else min(absf(p.x - x0), absf(p.x - x1))
			d += absf(p.y - r.get_center().y)
			if d < best_d:
				best_d = d
				best = int(lines[li]["i"]) * KEY_SCALE + wi
	return best


# ------------------------------------------------------------------ textures

func _process(_delta: float) -> void:
	if page_rects.is_empty() or not visible:
		return
	# Collect finished renders.
	for p in _pending.keys():
		var r: Dictionary = Pdf.take_render(int(_pending[p]["id"]))
		if r.is_empty():
			continue
		var w: int = _pending[p]["w"]
		_pending.erase(p)
		if r["image"] != null:
			_textures[p] = {"tex": ImageTexture.create_from_image(r["image"]), "w": w}
			queue_redraw()

	var vis := _visible_pages()
	var wanted := {}
	for p in vis:
		wanted[p] = true
	# Prefetch the pages of the next and previous steps, and the page after the view.
	if _mode() != "free" and not steps.is_empty():
		for i in [current + 1, current - 1]:
			if i >= 0 and i < steps.size():
				for r in _step_rects(steps[i]):
					wanted[r[0]] = true
	if not vis.is_empty() and vis[vis.size() - 1] + 1 < page_rects.size():
		wanted[vis[vis.size() - 1] + 1] = true

	for p in _textures.keys():
		if not wanted.has(p) and not wanted.has(p - 1) and not wanted.has(p + 1):
			_textures.erase(p)

	# Request renders, visible pages first.
	var need_w := _needed_texture_width()
	var order: Array = []
	order.append_array(vis)
	order.append_array(wanted.keys())
	for p in order:
		if _pending.size() >= MAX_RENDERS_IN_FLIGHT:
			break
		if _pending.has(p):
			continue
		var entry = _textures.get(p)
		if entry == null or int(entry["w"]) < need_w * 0.85:
			var id := Pdf.request_render(p, need_w)
			if id >= 0:
				_pending[p] = {"id": id, "w": need_w}

	if _mode() == "free" and _dragging:
		_update_status()


func _needed_texture_width() -> int:
	var win := DisplayServer.window_get_size()
	var phys_per_logical: float = float(win.x) / max(get_viewport_rect().size.x, 1.0)
	# Use the target scale while animating, so the sharp version is ready on arrival.
	var s := view_scale
	if _tween and _tween.is_running():
		s = max(s, _target_scale)
	var w := int(ceil(s * phys_per_logical / 256.0)) * 256
	return clamp(w, 256, MAX_TEXTURE_WIDTH)


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.12, 0.14))
	for p in _visible_pages():
		var r := _to_screen(page_rects[p])
		var entry = _textures.get(p)
		if entry:
			draw_texture_rect(entry["tex"], r, false)
		else:
			draw_rect(r, Color(0.96, 0.96, 0.96))

	if _mode() == "free" or steps.is_empty():
		_draw_comment_marks()
		return
	var step: Dictionary = steps[current]
	var holes := []   # [page, padded doc rect]
	for pr in _step_rects(step):
		var r: Rect2 = pr[1]
		var pad: float = r.size.y * 0.15 if not step.has("float") else 0.008
		holes.append([pr[0], r.grow_individual(pad * 1.5, pad, pad * 1.5, pad)])

	var dim: float = cfg["dim"]
	if dim > 0.01:
		# Shade everything, then paint the page back inside each highlighted piece.
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, dim))
		for h in holes:
			_draw_page_patch(h[0], h[1])

	var c: Color = cfg["color"]
	if cfg["color_by_kind"] and KIND_COLORS.has(step.get("k", "")):
		c = KIND_COLORS[step["k"]]
	var fill: float = cfg["fill"]
	for h in holes:
		var sr := _to_screen(h[1])
		match String(cfg["style"]):
			"fill":
				draw_rect(sr, Color(c, fill), true)
			"outline":
				draw_rect(sr, Color(c, 0.95), false, 2.0)
			"underline":
				var t: float = max(2.0, sr.size.y * 0.08)
				draw_rect(Rect2(sr.position.x, sr.end.y - t, sr.size.x, t), Color(c, max(fill * 3.0, 0.6)))
			_:
				draw_rect(sr, Color(c, fill), true)
				draw_rect(sr, Color(c, 0.95), false, 2.0)
	_draw_comment_marks()


## Commented text is underlined in its category's color (figures get a corner mark).
func _draw_comment_marks() -> void:
	if _comments.is_empty():
		return
	var top := cam.y
	var bottom := cam.y + size.y / view_scale
	for c in _comments:
		var col := CommentEditor.color_for(String(c.get("category", "")))
		for r in _comment_rects(c):
			if r.end.y < top or r.position.y > bottom:
				continue
			var sr := _to_screen(r)
			var t: float = clampf(sr.size.y * 0.09, 2.0, 4.0)
			if c.get("kind", "") == "float":
				draw_rect(Rect2(sr.position, Vector2(t * 3.0, sr.size.y)), Color(col, 0.9))
			else:
				draw_rect(Rect2(sr.position.x, sr.end.y + t * 0.5, sr.size.x, t), Color(col, 0.9))


func _draw_page_patch(page: int, doc_rect: Rect2) -> void:
	var pr := page_rects[page]
	var clip := doc_rect.intersection(pr)
	if not clip.has_area():
		return
	var entry = _textures.get(page)
	if entry == null:
		draw_rect(_to_screen(clip), Color(0.96, 0.96, 0.96))
		return
	var tex: Texture2D = entry["tex"]
	var tsize := tex.get_size()
	var src := Rect2((clip.position - pr.position) / pr.size * tsize, clip.size / pr.size * tsize)
	draw_texture_rect_region(tex, _to_screen(clip), src)


# ------------------------------------------------------------------ input

func _gui_input(event: InputEvent) -> void:
	# Events a panel doesn't use (e.g. the wheel over Settings) bubble up to the reader;
	# the page must not move under an open panel.
	if _settings.visible or _contents.is_open or _editor.visible:
		_pressed = false
		_dragging = false
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_pressed = true
				_dragging = mb.button_index == MOUSE_BUTTON_MIDDLE
				_press_pos = mb.position
			else:
				if _pressed and not _dragging and mb.button_index == MOUSE_BUTTON_LEFT:
					_on_click(mb.position)
				_pressed = false
				_dragging = false
			accept_event()
		elif mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var dir := -1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1
			if mb.ctrl_pressed:
				_zoom_at(mb.position, 1.1 if dir < 0 else 1.0 / 1.1)
			elif _mode() == "free" or steps.is_empty():
				if mb.shift_pressed:
					_pan(Vector2(dir * 60.0, 0))
				else:
					_pan(Vector2(0, dir * 60.0))
			elif dir > 0:
				next_step()
			else:
				prev_step()
			accept_event()
	elif event is InputEventMouseMotion and _pressed:
		var mm := event as InputEventMouseMotion
		if not _dragging and mm.position.distance_to(_press_pos) > 6.0:
			_dragging = true
		if _dragging:
			_pan(-mm.relative)
		accept_event()
	elif event is InputEventMagnifyGesture:
		var g := event as InputEventMagnifyGesture
		_zoom_at(g.position, g.factor)
		accept_event()
	elif event is InputEventPanGesture:
		var pg := event as InputEventPanGesture
		_pan(pg.delta * 20.0)
		accept_event()


## A click on a word moves the reading position there (in Figures mode: to the figure clicked).
func _on_click(pos: Vector2) -> void:
	if _mode() == "free" or steps.is_empty():
		return
	if _active_mode == "floats":
		var p := _to_doc(pos)
		for i in steps.size():
			var f: Dictionary = floats[int(steps[i]["float"])]
			if _norm_rect(int(f["p"]), f).has_point(p):
				_go_to_step(i)
				return
		return
	var key := _key_at(pos)
	if key >= 0:
		current = _step_at_key(key)
		_anchor = key
		_go_to_current(true)


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	if _tween:
		_tween.kill()
	var before := _to_doc(screen_pos)
	view_scale = clamp(view_scale * factor, 50.0, 30000.0)
	cam = before - screen_pos / view_scale
	if _mode() == "free":
		_update_status()


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or page_rects.is_empty() or _contents.is_open or _editor.visible:
		return
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	# The reader routes keys for Settings too, so one key press never does two things
	# (e.g. Esc closing Settings and then also leaving the document).
	if _settings.visible:
		if k.keycode == KEY_ESCAPE or (k.keycode == KEY_COMMA and k.is_command_or_control_pressed()):
			_settings.close()
			get_viewport().set_input_as_handled()
		return
	var ctrl := k.is_command_or_control_pressed()
	# Typing any character on a highlighted step starts a comment on it.
	if not ctrl and not k.alt_pressed and k.unicode > 32 and _can_comment():
		_start_comment(String.chr(k.unicode))
		get_viewport().set_input_as_handled()
		return
	var handled := true
	if ctrl:
		match k.keycode:
			KEY_1:
				set_mode("sentence")
			KEY_2:
				set_mode("line")
			KEY_3:
				set_mode("floats")
			KEY_4:
				set_mode("free")
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				change_zoom(1)
			KEY_MINUS, KEY_KP_SUBTRACT:
				change_zoom(-1)
			KEY_0, KEY_KP_0:
				change_zoom(0)
			KEY_COMMA:
				_open_settings()
			KEY_DOWN:
				_jump_to_comment(1)
			KEY_UP:
				_jump_to_comment(-1)
			_:
				handled = false
	else:
		match k.keycode:
			KEY_RIGHT, KEY_DOWN, KEY_ENTER, KEY_KP_ENTER:
				next_step()
			KEY_LEFT, KEY_UP, KEY_BACKSPACE:
				prev_step()
			KEY_SPACE:
				if k.shift_pressed:
					prev_step()
				else:
					next_step()
			KEY_PAGEDOWN:
				page_step(1)
			KEY_PAGEUP:
				page_step(-1)
			KEY_HOME:
				go_to_start()
			KEY_END:
				go_to_end()
			KEY_TAB:
				_open_contents()
			KEY_ESCAPE:
				go_back()
			_:
				handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _pan(screen_delta: Vector2) -> void:
	if _tween:
		_tween.kill()
	cam += screen_delta / view_scale
	if _mode() == "free":
		_update_status()


func _on_resized() -> void:
	if page_rects.is_empty():
		return
	if _mode() != "free" and not steps.is_empty():
		_go_to_current(false)


# ------------------------------------------------------------------ UI

# ------------------------------------------------------------------ comments
#
# A comment covers the keys s..e (a whole sentence, a line, or a figure). Its "quote" is the
# commented text; if a newer analyzer numbers lines differently, the comment is re-attached
# to the same words nearest its old place.

var _rect_cache := {}   # comment id -> Array[Rect2]


func _build_word_index() -> void:
	_flat_keys = PackedInt64Array()
	_flat_words = PackedStringArray()
	_all_words.clear()
	for l in all_lines:
		var i := int(l["i"])
		var ws: Array = Steps.line_words(l)
		_all_words[i] = ws
		for wi in ws.size():
			_flat_keys.append(i * KEY_SCALE + wi)
			_flat_words.append(String(ws[wi]["t"]))


func _range_text(s: int, e: int) -> String:
	var out: PackedStringArray = PackedStringArray()
	var i := _flat_keys.bsearch(s)
	while i < _flat_keys.size() and _flat_keys[i] <= e:
		out.append(_flat_words[i])
		i += 1
	return " ".join(out)


func _load_comments() -> void:
	_rect_cache.clear()
	_comments = []
	for c in Library.comments(doc_id):
		_comments.append(_reattach(c))
	_comments.sort_custom(func(a, b): return int(a["s"]) < int(b["s"]))


func _reattach(c: Dictionary) -> Dictionary:
	var quote := String(c.get("quote", ""))
	if c.get("kind", "") == "float":
		var key := int(c["s"])
		for f in floats:
			if String(f.get("t", "")) == quote and int(f["key"]) * KEY_SCALE != key:
				var moved := c.duplicate(true)
				moved["s"] = int(f["key"]) * KEY_SCALE
				moved["e"] = moved["s"]
				return Library.save_comment(doc_id, moved)
		return c
	if quote.is_empty() or _range_text(int(c["s"]), int(c["e"])) == quote:
		return c
	var q := quote.split(" ", false)
	var best := -1
	for i in _flat_words.size() - q.size() + 1:
		if _flat_words[i] != q[0]:
			continue
		var ok := true
		for j in range(1, q.size()):
			if _flat_words[i + j] != q[j]:
				ok = false
				break
		if ok and (best < 0 or absi(_flat_keys[i] - int(c["s"])) < absi(_flat_keys[best] - int(c["s"]))):
			best = i
	if best < 0:
		return c   # the text is gone; keep the comment where it was
	var moved := c.duplicate(true)
	moved["s"] = _flat_keys[best]
	moved["e"] = _flat_keys[best + q.size() - 1]
	return Library.save_comment(doc_id, moved)


## Doc-space rectangles of the commented text (one per line), or the figure region.
func _comment_rects(c: Dictionary) -> Array:
	var id := String(c.get("id", ""))
	if _rect_cache.has(id):
		return _rect_cache[id]
	var out := []
	if c.get("kind", "") == "float":
		for f in floats:
			if int(f["key"]) * KEY_SCALE == int(c["s"]):
				out.append(_norm_rect(int(f["p"]), f))
	else:
		var i := _flat_keys.bsearch(int(c["s"]))
		var cur_line := -1
		var a := 0
		var b := 0
		while true:
			var done := i >= _flat_keys.size() or _flat_keys[i] > int(c["e"])
			var li := -1 if done else int(_flat_keys[i] / KEY_SCALE)
			if li != cur_line:
				if cur_line >= 0:
					out.append(_words_rect(cur_line, a, b))
				cur_line = li
				a = int(_flat_keys[i] % KEY_SCALE) if not done else 0
			if done:
				break
			b = int(_flat_keys[i] % KEY_SCALE)
			i += 1
	_rect_cache[id] = out
	return out


## Doc-space rectangle of words a..b of a line (reading-order index).
func _words_rect(li: int, a: int, b: int) -> Rect2:
	var line: Dictionary = all_lines[li]
	var r := _line_rect(line)
	var ws: Array = _all_words.get(li, [])
	if ws.is_empty() or b >= ws.size():
		return r
	var pr := page_rects[int(line["p"])]
	var x0 := pr.position.x + float(ws[a]["x0"]) * pr.size.x
	var x1 := pr.position.x + float(ws[b]["x1"]) * pr.size.x
	return Rect2(x0, r.position.y, x1 - x0, r.size.y)


func _comments_on_step(step: Dictionary) -> Array:
	var s := _step_key(step)
	var e := _step_end(step)
	var is_float := step.has("float")
	return _comments.filter(func(c):
		if (c.get("kind", "") == "float") != is_float:
			return false
		return int(c["s"]) == s if is_float else (int(c["s"]) <= e and int(c["e"]) >= s))


func _can_comment() -> bool:
	return _active_mode != "free" and not steps.is_empty()


## Starts a new comment on the highlighted step with the first typed character.
func _start_comment(first: String) -> void:
	var step: Dictionary = steps[current]
	var c := {}
	if step.has("float"):
		var f: Dictionary = floats[int(step["float"])]
		var key := _step_key(step)
		c = {"kind": "float", "s": key, "e": key, "quote": String(f.get("t", ""))}
	else:
		# The whole sentence, also when it is split across columns or pages.
		var lo := current
		var hi := current
		if step.has("sid"):
			while lo > 0 and steps[lo - 1].get("sid", -1) == step["sid"]:
				lo -= 1
			while hi < steps.size() - 1 and steps[hi + 1].get("sid", -1) == step["sid"]:
				hi += 1
		var s := _step_key(steps[lo])
		var e := _step_end(steps[hi])
		c = {"kind": "text", "s": s, "e": e, "quote": _range_text(s, e)}
	_open_editor(c, first)


func _edit_comment(c: Dictionary) -> void:
	_open_editor(c, "")


func _open_editor(c: Dictionary, first: String) -> void:
	_side.visible = false
	_place_right_column()
	_editor.open(c, first)


func _on_comment_saved(c: Dictionary) -> void:
	Library.save_comment(doc_id, c)
	_after_comment_change()


func _on_comment_deleted(comment_id: String) -> void:
	if not comment_id.is_empty():
		Library.delete_comment(doc_id, comment_id)
	_after_comment_change()


func _after_comment_change() -> void:
	_load_comments()
	_refresh_side()
	queue_redraw()


## Next (dir = 1) or previous (dir = -1) comment from the reading position.
func _jump_to_comment(dir: int) -> void:
	if _comments.is_empty() or steps.is_empty():
		_flash("No comments in this paper")
		return
	var here_s := _step_key(steps[current]) if _active_mode != "free" else _current_key()
	var here_e := _step_end(steps[current]) if _active_mode != "free" else here_s
	var target: Dictionary = {}
	if dir > 0:
		for c in _comments:
			if int(c["s"]) > here_e:
				target = c
				break
	else:
		for i in range(_comments.size() - 1, -1, -1):
			if int(_comments[i]["e"]) < here_s:
				target = _comments[i]
				break
	if target.is_empty():
		_flash("No more comments " + ("below" if dir > 0 else "above"))
		return
	if target.get("kind", "") == "float" and _active_mode != "floats":
		set_mode("floats")
	elif target.get("kind", "") != "float" and _active_mode in ["floats", "free"]:
		set_mode("sentence")
	current = _step_at_key(int(target["s"]))
	_anchor = int(target["s"])
	_go_to_current(true)


func _place_right_column() -> void:
	var right: Control = _side.get_parent()
	right.offset_top = (_top.size.y if _top else 40.0) + 10.0


## Cards for the comments on the highlighted step, right of the page. Click one to edit it.
func _refresh_side() -> void:
	if _side == null:
		return
	for ch in _side.get_children():
		_side.remove_child(ch)
		ch.queue_free()
	if _editor.visible or _active_mode == "free" or steps.is_empty():
		_side.visible = false
		return
	var list := _comments_on_step(steps[current])
	_side.visible = not list.is_empty()
	_place_right_column()
	for c in list:
		_side.add_child(_comment_card(c))


func _comment_card(c: Dictionary) -> Control:
	var col := CommentEditor.color_for(String(c.get("category", "")))
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.12, 0.15, 0.94)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	sb.border_width_left = 4
	sb.border_color = col
	card.add_theme_stylebox_override("panel", sb)
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.tooltip_text = "Click to edit"
	card.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_edit_comment(c)
			card.accept_event())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(v)
	var head := Label.new()
	var cat := String(c.get("category", ""))
	head.text = cat if not cat.is_empty() else "Comment"
	head.add_theme_color_override("font_color", col)
	head.add_theme_font_size_override("font_size", 13)
	v.add_child(head)
	var body := Label.new()
	body.text = String(c.get("text", ""))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(body)
	for s in c.get("subs", []):
		var sub := Label.new()
		sub.text = "•  " + String(s)
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.add_theme_font_size_override("font_size", 15)
		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_left", 14)
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.add_child(sub)
		v.add_child(m)
	for l in [head, body]:
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return card


func _open_contents() -> void:
	var cur := -1
	var key := _current_key()
	for i in contents.size():
		if int(lines[int(contents[i]["l"])]["i"]) * KEY_SCALE <= key:
			cur = i
	_contents.set_entries(contents, cur)
	_contents.open()


func _open_settings() -> void:
	_settings.open(cfg, Pdf.storage_dir())


func _on_setting_changed(key: String, value: Variant) -> void:
	cfg[key] = value
	_save_settings()
	if key in ["fit", "follow", "zoom"] and _mode() != "free":
		_go_to_current(true)
	elif key == "skip_side":
		var anchor := _current_key()
		_rebuild_text()
		_set_mode(_active_mode, anchor, true)
	queue_redraw()


## Recomputes the lines read in text modes (and Contents) from the current settings.
func _rebuild_text() -> void:
	lines = Steps.text_lines(all_lines, bool(cfg["skip_side"]))
	words.clear()
	for l in lines:
		words.append(Steps.line_words(l))
	contents = Steps.build_contents(lines)


func _build_ui() -> void:
	_top = PanelContainer.new()
	_top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_top.add_theme_stylebox_override("panel", _bar_style())
	add_child(_top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_top.add_child(row)

	var back := _bar_button("← Library", close_document)
	back.tooltip_text = "Back to the library (Esc)"
	row.add_child(back)

	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_title)

	_mode_btn = OptionButton.new()
	_mode_btn.focus_mode = Control.FOCUS_NONE
	for i in MODE_NAMES.size():
		_mode_btn.add_item("%s  (Ctrl+%d)" % [MODE_NAMES[i], i + 1])
	_mode_btn.item_selected.connect(func(i): set_mode(MODES[i]))
	row.add_child(_mode_btn)

	var contents_btn := _bar_button("Contents", _open_contents)
	contents_btn.tooltip_text = "Headings (Tab)"
	row.add_child(contents_btn)
	var settings_btn := _bar_button("Settings", _open_settings)
	settings_btn.tooltip_text = "Reader settings (Ctrl+,)"
	row.add_child(settings_btn)

	_bottom = PanelContainer.new()
	_bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bottom.add_theme_stylebox_override("panel", _bar_style())
	add_child(_bottom)
	var col := VBoxContainer.new()
	_bottom.add_child(col)
	var line_row := HBoxContainer.new()
	col.add_child(line_row)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_FILL
	line_row.add_child(_status)
	_hint = Label.new()
	_hint.text = _hint_text()
	_hint.modulate = Color(1, 1, 1, 0.5)
	# Never push into the status text: shrink with "…" on narrow windows.
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hint.tooltip_text = "Keys: →/↓/Space/Enter next, ←/↑/Shift+Space/Backspace back, PgDn/PgUp page, Home/End, Ctrl+1-4 mode, Ctrl+=/−/0 zoom, Tab contents, Ctrl+, settings, Ctrl+↓/↑ next/previous comment, Esc library. Type to comment on the highlight."
	_hint.mouse_filter = Control.MOUSE_FILTER_PASS
	line_row.add_child(_hint)
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size.y = 4
	col.add_child(_bar)

	_notice = Label.new()
	_notice.text = "This PDF has no text layer (it looks scanned). Only Free mode is available."
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_notice.position.y = 70
	var nb := StyleBoxFlat.new()
	nb.bg_color = Color(0.55, 0.15, 0.15, 0.92)
	nb.set_corner_radius_all(8)
	nb.set_content_margin_all(12)
	_notice.add_theme_stylebox_override("normal", nb)
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.visible = false
	add_child(_notice)

	# Right column: the comment editor, or the comments on the highlighted step.
	var right := VBoxContainer.new()
	right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right.offset_left = -400
	right.offset_right = -12
	right.offset_top = 60
	right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	right.add_theme_constant_override("separation", 8)
	add_child(right)
	_editor = CommentEditor.new()
	_editor.saved.connect(_on_comment_saved)
	_editor.deleted.connect(_on_comment_deleted)
	_editor.closed.connect(_refresh_side)
	right.add_child(_editor)
	_side = VBoxContainer.new()
	_side.add_theme_constant_override("separation", 8)
	_side.visible = false
	right.add_child(_side)

	_contents = ContentsPanel.new()
	_contents.picked.connect(jump_to_contents)
	add_child(_contents)

	_settings = SettingsPanel.new()
	_settings.changed.connect(_on_setting_changed)
	add_child(_settings)


func _bar_button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	return b


func _bar_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.94)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb

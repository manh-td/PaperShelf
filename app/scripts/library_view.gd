extends Control
## Library screen: collections and tags (left), papers (middle), details (right).
##
## Keys: Enter open, Delete trash, F2 rename, Ctrl+O import PDFs, Ctrl+Shift+O import folder,
## Ctrl+F search, Ctrl+N new collection, Ctrl+A select all.
## Drag papers onto a collection (or Trash); drag a collection onto another to nest it.
## Drop PDF files or folders on the window to import them into the selected collection.

signal open_requested(id: String)
signal review_requested(id: String)

const ReaderView := preload("res://scripts/reader_view.gd")

const COL_TITLE := 0
const COL_TAGS := 1
const COL_ADDED := 2
const COL_READ := 3

var _view := "all"
var _tag_filter: Array = []
var _search := ""
var _sort_col := COL_ADDED
var _sort_asc := false
var _collapsed := {}
var _progress_cfg := ConfigFile.new()

var _coll_tree: Tree
var _tag_flow: HFlowContainer
var _tag_clear: Button
var _search_edit: LineEdit
var _list: Tree
var _count_label: Label
var _status: Label
var _progress: ProgressBar
var _details: VBoxContainer
var _title_edit: LineEdit

var _coll_menu: PopupMenu
var _paper_menu: PopupMenu
var _add_menu: PopupMenu
var _tag_menu: PopupMenu
var _confirm: ConfirmationDialog
var _confirm_action: Callable
var _rename_dialog: ConfirmationDialog
var _rename_edit: LineEdit
var _rename_action: Callable
var _files_dialog: FileDialog
var _dir_dialog: FileDialog

var _menu_collections: Array = []   # collection ids, by index in _add_menu
var _tag_menu_tag := ""
var _coll_menu_view := ""

var _import_queue: Array = []       # [[path, collection id], ...]
var _import_total := 0
var _import_added := 0
var _import_dupes := 0
var _import_errors: Array = []
var _last_added_ids: Array = []

var _refresh_pending := false
var _selection_pending := false
var _busy_text := ""


func _ready() -> void:
	_build()
	Library.changed.connect(_queue_refresh)
	get_window().files_dropped.connect(_on_files_dropped)
	_refresh_all()


# ------------------------------------------------------------------ public API

func refresh() -> void:
	_refresh_all()


## Shows a message and progress while a paper opens (value < 0 hides the bar).
func set_busy(text: String, value := -1.0) -> void:
	_busy_text = text
	_status.text = text
	_progress.visible = value >= 0.0
	_progress.value = max(value, 0.0)


func focus_list() -> void:
	if _list.get_root() and _list.get_root().get_first_child():
		_list.grab_focus()
		if _list.get_next_selected(null) == null:
			var first := _list.get_root().get_first_child()
			_list.set_selected(first, 0)
			_select_row(first)
			_queue_selection()


# ------------------------------------------------------------------ refresh

func _queue_refresh() -> void:
	if not _refresh_pending:
		_refresh_pending = true
		_refresh_all.call_deferred()


func _refresh_all() -> void:
	_refresh_pending = false
	_progress_cfg = ConfigFile.new()
	_progress_cfg.load(Library.root_dir().path_join("progress.cfg"))
	if _view.begins_with("c:") and Library.collection(_view.substr(2)).is_empty():
		_view = "all"
	_build_collections()
	_build_tags()
	_build_list()
	_update_details()


func _build_collections() -> void:
	_coll_tree.clear()
	var root := _coll_tree.create_item()
	var all := _coll_item(root, "My Library", "all", Library.count("all"))
	_add_collection_items(all, "")
	_coll_item(root, "Unfiled", "unfiled", Library.count("unfiled"))
	_coll_item(root, "Trash", "trash", Library.count("trash"))


func _add_collection_items(parent: TreeItem, parent_id: String) -> void:
	for c in Library.children(parent_id):
		var item := _coll_item(parent, String(c["name"]), "c:" + String(c["id"]), Library.count("c:" + String(c["id"])))
		_add_collection_items(item, c["id"])
		item.collapsed = _collapsed.get(c["id"], false)


func _coll_item(parent: TreeItem, text: String, view: String, n: int) -> TreeItem:
	var item := _coll_tree.create_item(parent)
	item.set_text(0, text)
	item.set_metadata(0, view)
	item.set_text(1, str(n) if n > 0 else "")
	item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_custom_color(1, Color(1, 1, 1, 0.45))
	if view == _view:
		item.select(0)
	return item


func _build_tags() -> void:
	for c in _tag_flow.get_children():
		c.queue_free()
	var counts := Library.tag_counts(Library.query(_view, [], _search))
	# Keep selected tags visible even if no paper in this view has them.
	_tag_filter = _tag_filter.filter(func(t): return counts.has(t))
	var names := counts.keys()
	names.sort_custom(func(a, b): return String(a).naturalnocasecmp_to(b) < 0)
	if names.is_empty():
		var none := Label.new()
		none.text = "No tags here yet."
		none.modulate = Color(1, 1, 1, 0.45)
		_tag_flow.add_child(none)
	for t in names:
		var b := Button.new()
		b.text = "%s  %d" % [t, counts[t]]
		b.toggle_mode = true
		b.button_pressed = t in _tag_filter
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 14)
		b.toggled.connect(func(on):
			if on and not t in _tag_filter:
				_tag_filter.append(t)
			elif not on:
				_tag_filter.erase(t)
			_tag_clear.visible = not _tag_filter.is_empty()
			_build_list()
			_update_details())
		b.gui_input.connect(func(e):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
				_tag_menu_tag = t
				_tag_menu.position = Vector2i(get_screen_position() + get_local_mouse_position())
				_tag_menu.popup())
		_tag_flow.add_child(b)
	_tag_clear.visible = not _tag_filter.is_empty()


func _build_list() -> void:
	var keep := _selected_ids()
	if not _last_added_ids.is_empty():
		keep = _last_added_ids
		_last_added_ids = []
	_list.clear()
	var root := _list.create_item()
	var rows := Library.query(_view, _tag_filter, _search)
	rows.sort_custom(_compare_rows)
	var first_kept: TreeItem = null
	for p in rows:
		var item := _list.create_item(root)
		item.set_text(COL_TITLE, Library.display_title(p))
		item.set_tooltip_text(COL_TITLE, Library.display_title(p) + "\n" + String(p["orig_name"]))
		item.set_metadata(COL_TITLE, p["id"])
		item.set_text(COL_TAGS, ", ".join(p["tags"]))
		item.set_custom_color(COL_TAGS, Color(0.65, 0.80, 1.0))
		item.set_text(COL_ADDED, _date(int(p["added"])))
		item.set_text(COL_READ, _progress_text(p))
		item.set_text_alignment(COL_READ, HORIZONTAL_ALIGNMENT_RIGHT)
		if p["id"] in keep:
			_select_row(item)
			if first_kept == null:
				first_kept = item
	if first_kept:
		_list.scroll_to_item(first_kept)
	var where: String = {"all": "My Library", "unfiled": "Unfiled", "trash": "Trash"}.get(_view, "")
	if where.is_empty():
		where = Library.collection_path(_view.substr(2))
	var filt := ""
	if not _tag_filter.is_empty():
		filt = "  ·  tags: " + ", ".join(_tag_filter)
	if not _search.is_empty():
		filt += "  ·  search: \"%s\"" % _search
	_count_label.text = "%s  ·  %d paper%s%s" % [where, rows.size(), "" if rows.size() == 1 else "s", filt]


func _compare_rows(a: Dictionary, b: Dictionary) -> bool:
	var c := 0
	match _sort_col:
		COL_TITLE:
			c = Library.display_title(a).naturalnocasecmp_to(Library.display_title(b))
		COL_TAGS:
			c = ", ".join(a["tags"]).naturalnocasecmp_to(", ".join(b["tags"]))
		COL_ADDED:
			c = signi(int(a["added"]) - int(b["added"]))
		COL_READ:
			c = signi(int(a["last_read"]) - int(b["last_read"]))
	if c == 0:
		c = Library.display_title(a).naturalnocasecmp_to(Library.display_title(b))
		return c < 0
	return c < 0 if _sort_asc else c > 0


func _progress_value(p: Dictionary) -> float:
	var id: String = p["id"]
	if not _progress_cfg.has_section_key("progress", id):
		return -1.0
	var total: int = _progress_cfg.get_value("totals", id, 0)
	return float(_progress_cfg.get_value("progress", id, 0)) / max(total - 1, 1)


func _progress_text(p: Dictionary) -> String:
	var v := _progress_value(p)
	return "new" if v < 0 else "%d%%" % int(round(v * 100))


static func _date(unix: int) -> String:
	if unix <= 0:
		return ""
	var bias: int = Time.get_time_zone_from_system().get("bias", 0)
	return Time.get_date_string_from_unix_time(unix + bias * 60)


var _mirroring := false

## Tree selection is per cell in multi-select mode; keep whole rows selected.
func _on_multi_selected(item: TreeItem, _column: int, selected: bool) -> void:
	if not _mirroring:
		_mirroring = true
		for c in _list.columns:
			if selected and not item.is_selected(c):
				item.select(c)
			elif not selected and item.is_selected(c):
				item.deselect(c)
		_mirroring = false
	_queue_selection()


func _select_row(item: TreeItem) -> void:
	_mirroring = true
	for c in _list.columns:
		item.select(c)
	_mirroring = false


func _selected_ids() -> Array:
	var out := []
	if _list == null:
		return out
	var item := _list.get_next_selected(null)
	while item:
		out.append(item.get_metadata(COL_TITLE))
		item = _list.get_next_selected(item)
	return out


# ------------------------------------------------------------------ details pane

func _queue_selection() -> void:
	if not _selection_pending:
		_selection_pending = true
		_update_details.call_deferred()


func _update_details() -> void:
	_selection_pending = false
	for c in _details.get_children():
		c.queue_free()
	_title_edit = null
	var ids := _selected_ids()
	if ids.is_empty():
		_details_empty()
	elif ids.size() == 1:
		_details_one(Library.paper(ids[0]))
	else:
		_details_many(ids)


func _details_empty() -> void:
	var l := _label("%d papers in the library" % Library.count("all"), 18)
	_details.add_child(l)
	var hint := _label("Select a paper to see its details.\n\n" +
		"Enter: open   ·   Delete: move to trash   ·   F2: rename\n" +
		"Ctrl+O: import PDFs   ·   Ctrl+Shift+O: import a folder\n" +
		"Ctrl+F: search   ·   Ctrl+N: new collection\n\n" +
		"Drop PDFs or folders on the window to import them. Drag papers onto a collection to file them.", 14)
	hint.modulate = Color(1, 1, 1, 0.6)
	_details.add_child(hint)


func _details_one(p: Dictionary) -> void:
	if p.is_empty():
		return
	var id: String = p["id"]
	_title_edit = LineEdit.new()
	_title_edit.text = String(p["title"])
	_title_edit.placeholder_text = Library.display_title(p)
	_title_edit.tooltip_text = "Title (F2). Enter to save."
	_title_edit.text_submitted.connect(func(t):
		Library.set_title(id, t)
		_list.grab_focus())
	_title_edit.focus_exited.connect(func():
		if is_instance_valid(_title_edit) and _title_edit.text != String(Library.paper(id).get("title", "")):
			Library.set_title(id, _title_edit.text))
	_details.add_child(_section("Title"))
	_details.add_child(_title_edit)

	var info := "%s\n%s%sadded %s" % [p["orig_name"], ("%d pages  ·  " % int(p["pages"])) if int(p["pages"]) > 0 else "",
		_size_text(int(p.get("size", 0))), _date(int(p["added"]))]
	var v := _progress_value(p)
	info += "\n" + ("Not read yet" if v < 0 else "Read %d%%, last opened %s" % [int(round(v * 100)), _date(int(p["last_read"]))])
	var n_comments: int = p.get("comments", []).size()
	if n_comments > 0:
		info += "  ·  %d comment%s" % [n_comments, "" if n_comments == 1 else "s"]
	var info_l := _label(info, 14)
	info_l.modulate = Color(1, 1, 1, 0.65)
	_details.add_child(info_l)

	var actions := HBoxContainer.new()
	if p["trashed"]:
		actions.add_child(_button("Restore", func(): Library.restore([id])))
		actions.add_child(_button("Delete permanently…", func(): _ask_delete([id])))
	else:
		var open := _button("Open  (Enter)", func(): open_requested.emit(id))
		actions.add_child(open)
		var review_btn := _button("Review" if p.has("review") else "Write review", func(): review_requested.emit(id))
		review_btn.tooltip_text = "Put the %d comment%s together into a review" % [n_comments, "" if n_comments == 1 else "s"]
		actions.add_child(review_btn)
		actions.add_child(_button("Show file", func(): OS.shell_show_in_file_manager(Library.paper_path(p))))
	_details.add_child(actions)

	_details.add_child(_section("Tags"))
	_details.add_child(_tag_chips([id], p["tags"]))
	_details.add_child(_tag_input([id]))

	_details.add_child(_section("Collections"))
	_details.add_child(_collection_chips([id], p["collections"]))
	_details.add_child(_collection_adder([id]))

	if not p["trashed"]:
		var trash := _button("Move to Trash  (Delete)", func(): Library.trash([id]))
		trash.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		_details.add_child(_spacer())
		_details.add_child(trash)


func _details_many(ids: Array) -> void:
	_details.add_child(_label("%d papers selected" % ids.size(), 18))
	var sel := ids.map(func(i): return Library.paper(i))
	var tag_union := []
	var coll_union := []
	var any_trashed := false
	for p in sel:
		for t in p["tags"]:
			if not t in tag_union:
				tag_union.append(t)
		for c in p["collections"]:
			if not c in coll_union:
				coll_union.append(c)
		any_trashed = any_trashed or p["trashed"]
	tag_union.sort_custom(func(a, b): return String(a).naturalnocasecmp_to(b) < 0)
	_details.add_child(_section("Tags (✕ removes from all selected)"))
	_details.add_child(_tag_chips(ids, tag_union))
	_details.add_child(_tag_input(ids))
	_details.add_child(_section("Collections"))
	_details.add_child(_collection_chips(ids, coll_union))
	_details.add_child(_collection_adder(ids))
	_details.add_child(_spacer())
	var actions := HBoxContainer.new()
	if any_trashed:
		actions.add_child(_button("Restore", func(): Library.restore(ids)))
		actions.add_child(_button("Delete permanently…", func(): _ask_delete(ids)))
	else:
		actions.add_child(_button("Move to Trash  (Delete)", func(): Library.trash(ids)))
	_details.add_child(actions)


func _tag_chips(ids: Array, tags: Array) -> Control:
	var flow := HFlowContainer.new()
	if tags.is_empty():
		var none := _label("No tags", 14)
		# Inside a flow container a wrapping label gets almost no width (one letter per line).
		none.autowrap_mode = TextServer.AUTOWRAP_OFF
		none.modulate = Color(1, 1, 1, 0.45)
		flow.add_child(none)
	for t in tags:
		var b := _button(String(t) + "  ✕", func(): Library.remove_tag(ids, t))
		b.tooltip_text = "Remove tag \"%s\"" % t
		b.add_theme_color_override("font_color", Color(0.65, 0.80, 1.0))
		flow.add_child(b)
	return flow


func _tag_input(ids: Array) -> Control:
	var e := LineEdit.new()
	e.placeholder_text = "Add tags (comma separated), Enter"
	e.text_submitted.connect(func(t):
		var tags := Array(String(t).split(",", false))
		Library.add_tags(ids, tags)
		_focus_tag_input.call_deferred())
	return e


## Keeps typing tags after one is added (the details pane is rebuilt).
func _focus_tag_input() -> void:
	for c in _details.get_children():
		if c is LineEdit and c != _title_edit:
			c.grab_focus()
			return


func _collection_chips(ids: Array, cids: Array) -> Control:
	var flow := HFlowContainer.new()
	if cids.is_empty():
		var none := _label("Not in any collection", 14)
		# Inside a flow container a wrapping label gets almost no width (one letter per line).
		none.autowrap_mode = TextServer.AUTOWRAP_OFF
		none.modulate = Color(1, 1, 1, 0.45)
		flow.add_child(none)
	for cid in cids:
		var b := _button(Library.collection_path(cid) + "  ✕", func(): Library.remove_from_collection(ids, cid))
		b.tooltip_text = "Remove from this collection"
		flow.add_child(b)
	return flow


func _collection_adder(ids: Array) -> Control:
	var mb := MenuButton.new()
	mb.text = "Add to collection…"
	mb.flat = false
	var popup := mb.get_popup()
	var order := _flat_collections()
	if order.is_empty():
		popup.add_item("(no collections yet: Ctrl+N)")
		popup.set_item_disabled(0, true)
	for i in order.size():
		popup.add_item("    ".repeat(order[i][1]) + String(Library.collection(order[i][0])["name"]), i)
	popup.id_pressed.connect(func(i):
		if i < order.size():
			Library.add_to_collection(ids, order[i][0]))
	mb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return mb


## [[collection id, depth], ...] in tree order.
func _flat_collections(parent := "", depth := 0) -> Array:
	var out := []
	for c in Library.children(parent):
		out.append([c["id"], depth])
		out.append_array(_flat_collections(c["id"], depth + 1))
	return out


static func _size_text(bytes: int) -> String:
	if bytes <= 0:
		return ""
	if bytes < 1024 * 1024:
		return "%d KB  ·  " % int(bytes / 1024.0)
	return "%.1f MB  ·  " % (bytes / 1048576.0)


func _label(text: String, size := 16) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	return l


func _section(text: String) -> Label:
	var l := _label(text, 14)
	l.modulate = Color(0.75, 0.80, 1.0)
	return l


func _spacer() -> Control:
	var s := Control.new()
	s.custom_minimum_size.y = 8
	return s


func _button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b


# ------------------------------------------------------------------ actions

func _open_selected() -> void:
	var ids := _selected_ids()
	if ids.size() >= 1 and not Library.paper(ids[0]).get("trashed", true):
		open_requested.emit(ids[0])


func _delete_selected() -> void:
	var ids := _selected_ids()
	if ids.is_empty():
		return
	if _view == "trash":
		_ask_delete(ids)
	else:
		Library.trash(ids)


func _ask_delete(ids: Array) -> void:
	_ask("Delete %d paper%s permanently? The PDF copies in the library are removed. This cannot be undone." % [
		ids.size(), "" if ids.size() == 1 else "s"], "Delete", func(): Library.delete_permanently(ids))


func _ask(text: String, ok: String, action: Callable) -> void:
	_confirm.dialog_text = text
	_confirm.ok_button_text = ok
	_confirm_action = action
	_confirm.popup_centered()


func _ask_name(title: String, initial: String, action: Callable) -> void:
	_rename_dialog.title = title
	_rename_edit.text = initial
	_rename_action = action
	_rename_dialog.popup_centered(Vector2i(420, 0))
	_rename_edit.grab_focus()
	_rename_edit.select_all()


func new_collection() -> void:
	var parent := _view.substr(2) if _view.begins_with("c:") else ""
	if not Library.can_add_subcollection(parent):
		set_busy("Can't add a subcollection to \"%s\": collections can be nested at most %d levels deep." % [
			Library.collection(parent)["name"], Library.MAX_NESTING])
		return
	var title := "New collection" if parent.is_empty() else "New subcollection in \"%s\"" % Library.collection(parent)["name"]
	_ask_name(title, "", func(n):
		if not String(n).strip_edges().is_empty():
			var id := Library.add_collection(n, parent)
			if id.is_empty():
				return
			_collapsed[parent] = false
			_view = "c:" + id)


func _rename_current_collection() -> void:
	if not _view.begins_with("c:"):
		return
	var cid := _view.substr(2)
	_ask_name("Rename collection", Library.collection(cid)["name"], func(n): Library.rename_collection(cid, n))


func _select_view(view: String) -> void:
	if view == _view:
		return
	_view = view
	var sel := _coll_tree.get_selected()
	if sel == null or String(sel.get_metadata(0)) != view:
		_build_collections()
	_build_tags()
	_build_list()
	_update_details()


# ------------------------------------------------------------------ import

func import_files_dialog() -> void:
	_files_dialog.popup_centered_ratio(0.6)


func import_folder_dialog() -> void:
	_dir_dialog.popup_centered_ratio(0.6)


func _target_collection() -> String:
	return _view.substr(2) if _view.begins_with("c:") else ""


func _queue_import(paths: Array) -> void:
	var target := _target_collection()
	var found := []
	for p in paths:
		if DirAccess.dir_exists_absolute(p):
			for f in _find_pdfs(p):
				found.append([f, target])
		elif String(p).to_lower().ends_with(".pdf"):
			found.append([p, target])
	if found.is_empty():
		if _import_queue.is_empty():
			set_busy("No PDF files found there.")
		return
	if _import_queue.is_empty():
		# A new import run.
		_import_total = 0
		_import_added = 0
		_import_dupes = 0
		_import_errors = []
		_last_added_ids = []
	_import_queue.append_array(found)
	_import_total += found.size()


func _find_pdfs(dir: String) -> Array:
	var out := []
	for f in DirAccess.get_files_at(dir):
		if f.to_lower().ends_with(".pdf"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			out.append_array(_find_pdfs(dir.path_join(d)))
	return out


func _on_files_dropped(files: PackedStringArray) -> void:
	if is_visible_in_tree():
		_queue_import(Array(files))


func _process(_delta: float) -> void:
	if _import_queue.is_empty():
		return
	var job: Array = _import_queue.pop_front()
	var done := _import_added + _import_dupes + _import_errors.size()
	set_busy("Importing %d of %d: %s" % [done + 1, _import_total, String(job[0]).get_file()], float(done) / max(_import_total, 1))
	var r := Library.import_pdf(job[0], job[1])
	if r.has("paper"):
		_import_added += 1
		_last_added_ids.append(r["paper"]["id"])
	elif r.has("duplicate"):
		_import_dupes += 1
		_last_added_ids.append(r["duplicate"]["id"])
	else:
		_import_errors.append(String(r.get("error", "?")))
	if _import_queue.is_empty():
		var msg := ""
		if _import_added > 0 or _import_dupes == 0:
			msg = "Added %d paper%s." % [_import_added, "" if _import_added == 1 else "s"]
		if _import_dupes > 0:
			msg += (" " if not msg.is_empty() else "") + ("%d already in the library." % _import_dupes if _import_dupes > 1 else "Already in the library.")
		if not _import_errors.is_empty():
			msg += " %d failed: %s" % [_import_errors.size(), _import_errors[0]]
		set_busy(msg)
		_list.grab_focus()


# ------------------------------------------------------------------ input

func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	var ctrl := k.is_command_or_control_pressed()
	var handled := true
	if ctrl and k.keycode == KEY_O:
		if k.shift_pressed:
			import_folder_dialog()
		else:
			import_files_dialog()
	elif ctrl and k.keycode == KEY_F:
		_search_edit.grab_focus()
		_search_edit.select_all()
	elif ctrl and k.keycode == KEY_N:
		new_collection()
	elif ctrl and k.keycode == KEY_A and _list.has_focus():
		var item := _list.get_root().get_first_child() if _list.get_root() else null
		while item:
			_select_row(item)
			item = item.get_next()
		_queue_selection()
	elif k.keycode == KEY_DELETE and _coll_tree.has_focus():
		if _view.begins_with("c:"):
			_ask_delete_collection(_view.substr(2))
	elif k.keycode == KEY_DELETE:
		_delete_selected()
	elif k.keycode == KEY_F2 and _coll_tree.has_focus():
		_rename_current_collection()
	elif k.keycode == KEY_F2 and _title_edit:
		_title_edit.grab_focus()
		_title_edit.select_all()
	elif k.keycode == KEY_ESCAPE and not _search.is_empty():
		_search_edit.text = ""
		_search = ""
		_build_tags()
		_build_list()
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _ask_delete_collection(cid: String) -> void:
	var n := Library.descendants(cid).size()
	_ask("Delete the collection \"%s\"%s? Its papers stay in My Library." % [
		Library.collection(cid)["name"], (" and its %d subcollection%s" % [n, "" if n == 1 else "s"]) if n > 0 else ""],
		"Delete", func(): Library.delete_collection(cid))


# ------------------------------------------------------------------ drag and drop

func _list_get_drag(_pos: Vector2) -> Variant:
	var ids := _selected_ids()
	if ids.is_empty():
		return null
	var l := Label.new()
	l.text = Library.display_title(Library.paper(ids[0])) if ids.size() == 1 else "%d papers" % ids.size()
	_list.set_drag_preview(l)
	return {"type": "papers", "ids": ids}


func _coll_get_drag(_pos: Vector2) -> Variant:
	var item := _coll_tree.get_selected()
	if item == null or not String(item.get_metadata(0)).begins_with("c:"):
		return null
	var l := Label.new()
	l.text = item.get_text(0)
	_coll_tree.set_drag_preview(l)
	return {"type": "collection", "id": String(item.get_metadata(0)).substr(2)}


func _coll_can_drop(pos: Vector2, data: Variant) -> bool:
	if not data is Dictionary:
		return false
	_coll_tree.drop_mode_flags = Tree.DROP_MODE_ON_ITEM
	var item := _coll_tree.get_item_at_position(pos)
	if item == null:
		return false
	var target := String(item.get_metadata(0))
	if data["type"] == "papers":
		return target.begins_with("c:") or target == "trash"
	if data["type"] == "collection":
		if target == "all":
			return Library.can_move_collection(data["id"], "")
		if target.begins_with("c:"):
			# Refuses cycles and nesting deeper than Library.MAX_NESTING.
			return Library.can_move_collection(data["id"], target.substr(2))
	return false


func _coll_drop(pos: Vector2, data: Variant) -> void:
	var item := _coll_tree.get_item_at_position(pos)
	if item == null:
		return
	var target := String(item.get_metadata(0))
	if data["type"] == "papers":
		if target == "trash":
			Library.trash(data["ids"])
		else:
			Library.add_to_collection(data["ids"], target.substr(2))
			set_busy("Added %d paper%s to \"%s\"." % [data["ids"].size(), "" if data["ids"].size() == 1 else "s", item.get_text(0)])
	elif data["type"] == "collection":
		Library.move_collection(data["id"], "" if target == "all" else target.substr(2))
		if target != "all":
			_collapsed[target.substr(2)] = false


# ------------------------------------------------------------------ context menus

func _on_list_rmb(pos: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT:
		return
	var item := _list.get_item_at_position(pos)
	if item and not item.is_selected(COL_TITLE):
		_list.deselect_all()
		_select_row(item)
	var ids := _selected_ids()
	if ids.is_empty():
		return
	_paper_menu.clear()
	_add_menu.clear()
	if _view == "trash":
		_paper_menu.add_item("Restore", 10)
		_paper_menu.add_item("Delete permanently…", 11)
	else:
		_paper_menu.add_item("Open", 0)
		_paper_menu.set_item_disabled(_paper_menu.get_item_index(0), ids.size() != 1)
		_paper_menu.add_item("Show file in folder", 1)
		_paper_menu.add_item("Clear cached analysis", 5)
		_paper_menu.add_separator()
		_menu_collections = _flat_collections()
		for i in _menu_collections.size():
			_add_menu.add_item("    ".repeat(_menu_collections[i][1]) + String(Library.collection(_menu_collections[i][0])["name"]), i)
		_paper_menu.add_submenu_node_item("Add to collection", _add_menu, 2)
		if _menu_collections.is_empty():
			_paper_menu.set_item_disabled(_paper_menu.get_item_index(2), true)
		if _view.begins_with("c:"):
			_paper_menu.add_item("Remove from \"%s\"" % Library.collection(_view.substr(2))["name"], 3)
		_paper_menu.add_separator()
		_paper_menu.add_item("Move to Trash", 4)
	_paper_menu.position = Vector2i(_list.get_screen_position() + pos)
	_paper_menu.reset_size()
	_paper_menu.popup()


func _on_paper_menu(id: int) -> void:
	var ids := _selected_ids()
	match id:
		0:
			_open_selected()
		1:
			if not ids.is_empty():
				OS.shell_show_in_file_manager(Library.paper_path(Library.paper(ids[0])))
		3:
			Library.remove_from_collection(ids, _view.substr(2))
		4:
			Library.trash(ids)
		5:
			var r := Library.clear_cache(ids)
			set_busy("Removed the cached analysis of %d paper%s (%s). %s analyzed again when opened." % [
				ids.size(), "" if ids.size() == 1 else "s", Library.size_text(int(r["bytes"])), "It is" if ids.size() == 1 else "They are"])
		10:
			Library.restore(ids)
		11:
			_ask_delete(ids)


func _on_coll_rmb(pos: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT:
		return
	var item := _coll_tree.get_item_at_position(pos)
	if item == null:
		return
	var view := String(item.get_metadata(0))
	_select_view(view)
	_coll_menu_view = view
	_coll_menu.clear()
	if view == "trash":
		_coll_menu.add_item("Empty Trash…", 3)
		_coll_menu.set_item_disabled(0, Library.count("trash") == 0)
	elif view.begins_with("c:"):
		_coll_menu.add_item("New subcollection…", 0)
		if not Library.can_add_subcollection(view.substr(2)):
			_coll_menu.set_item_disabled(_coll_menu.get_item_index(0), true)
			_coll_menu.set_item_tooltip(_coll_menu.get_item_index(0), "Collections nest at most %d levels deep" % Library.MAX_NESTING)
		_coll_menu.add_item("Rename…", 1)
		_coll_menu.add_item("Delete collection…", 2)
		_coll_menu.add_separator()
		_coll_menu.add_item("Import PDFs here…", 4)
	else:
		_coll_menu.add_item("New collection…", 0)
		_coll_menu.add_item("Import PDFs…", 4)
	_coll_menu.position = Vector2i(_coll_tree.get_screen_position() + pos)
	_coll_menu.reset_size()
	_coll_menu.popup()


func _on_coll_menu(id: int) -> void:
	match id:
		0:
			new_collection()
		1:
			_rename_current_collection()
		2:
			_ask_delete_collection(_coll_menu_view.substr(2))
		3:
			_ask("Delete all %d papers in the Trash permanently? This cannot be undone." % Library.count("trash"),
				"Empty Trash", func(): Library.empty_trash())
		4:
			import_files_dialog()


func _on_tag_menu(id: int) -> void:
	var tag := _tag_menu_tag
	match id:
		0:
			_ask_name("Rename tag \"%s\"" % tag, tag, func(n):
				if tag in _tag_filter:
					_tag_filter.erase(tag)
					_tag_filter.append(Library.clean_tag(n))
				Library.rename_tag(tag, n))
		1:
			_ask("Remove the tag \"%s\" from all papers?" % tag, "Remove", func():
				_tag_filter.erase(tag)
				Library.delete_tag(tag))


# ------------------------------------------------------------------ layout

func _build() -> void:
	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("separation", 0)
	add_child(outer)

	# Toolbar.
	var bar := PanelContainer.new()
	var bar_sb := StyleBoxFlat.new()
	bar_sb.bg_color = Color(0.08, 0.08, 0.10)
	bar_sb.set_content_margin_all(8)
	bar.add_theme_stylebox_override("panel", bar_sb)
	outer.add_child(bar)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 8)
	bar.add_child(tools)
	var app := _label("PaperShelf", 20)
	app.autowrap_mode = TextServer.AUTOWRAP_OFF
	tools.add_child(app)
	tools.add_child(_spacer_h(12))
	for spec in [["Import PDFs…", "Ctrl+O", import_files_dialog], ["Import folder…", "Ctrl+Shift+O", import_folder_dialog],
			["New collection", "Ctrl+N", new_collection], ["Clear cache…", "Remove cached page analysis (papers, comments and reviews are kept)", ask_clear_cache]]:
		var b := _button(spec[0], spec[2])
		b.tooltip_text = spec[1]
		b.focus_mode = Control.FOCUS_NONE
		tools.add_child(b)
	var grow := Control.new()
	grow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tools.add_child(grow)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search titles, tags and comments  (Ctrl+F)"
	_search_edit.custom_minimum_size.x = 320
	_search_edit.clear_button_enabled = true
	_search_edit.text_changed.connect(func(t):
		_search = t.strip_edges()
		_build_tags()
		_build_list()
		_update_details())
	_search_edit.text_submitted.connect(func(_t): focus_list())
	tools.add_child(_search_edit)

	# Three panes.
	var split1 := HSplitContainer.new()
	split1.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split1)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 240
	split1.add_child(left)
	var split2 := HSplitContainer.new()
	split1.add_child(split2)
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_stretch_ratio = 3.0
	split2.add_child(center)
	var right_scroll := ScrollContainer.new()
	right_scroll.custom_minimum_size.x = 320
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split2.add_child(right_scroll)
	var right_margin := MarginContainer.new()
	right_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		right_margin.add_theme_constant_override("margin_" + side, 12)
	right_scroll.add_child(right_margin)
	_details = VBoxContainer.new()
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.add_theme_constant_override("separation", 8)
	right_margin.add_child(_details)

	# Left: collections and tags.
	_coll_tree = Tree.new()
	_coll_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_coll_tree.size_flags_stretch_ratio = 2.0
	_coll_tree.hide_root = true
	_coll_tree.columns = 2
	_coll_tree.set_column_expand(1, false)
	_coll_tree.set_column_custom_minimum_width(1, 44)
	_coll_tree.allow_rmb_select = true
	_coll_tree.select_mode = Tree.SELECT_ROW
	_coll_tree.item_selected.connect(func():
		var it := _coll_tree.get_selected()
		if it:
			_select_view(String(it.get_metadata(0))))
	_coll_tree.item_collapsed.connect(func(it: TreeItem):
		var v := String(it.get_metadata(0))
		if v.begins_with("c:"):
			_collapsed[v.substr(2)] = it.collapsed)
	_coll_tree.item_activated.connect(_rename_current_collection)
	_coll_tree.item_mouse_selected.connect(_on_coll_rmb)
	_coll_tree.set_drag_forwarding(_coll_get_drag, _coll_can_drop, _coll_drop)
	left.add_child(_coll_tree)

	var tag_head := HBoxContainer.new()
	var tag_title := _section("Tags  (click to filter)")
	tag_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag_head.add_child(tag_title)
	_tag_clear = _button("Clear", func():
		_tag_filter.clear()
		_build_tags()
		_build_list()
		_update_details())
	_tag_clear.focus_mode = Control.FOCUS_NONE
	_tag_clear.visible = false
	tag_head.add_child(_tag_clear)
	left.add_child(tag_head)
	var tag_scroll := ScrollContainer.new()
	tag_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tag_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(tag_scroll)
	_tag_flow = HFlowContainer.new()
	_tag_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag_scroll.add_child(_tag_flow)

	# Middle: paper list.
	_count_label = _label("", 14)
	_count_label.modulate = Color(1, 1, 1, 0.6)
	var count_margin := MarginContainer.new()
	count_margin.add_theme_constant_override("margin_left", 6)
	count_margin.add_child(_count_label)
	center.add_child(count_margin)
	_list = Tree.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.hide_root = true
	_list.columns = 4
	_list.column_titles_visible = true
	_list.select_mode = Tree.SELECT_MULTI
	_list.allow_rmb_select = true
	for spec in [[COL_TITLE, "Title", 0], [COL_TAGS, "Tags", 0], [COL_ADDED, "Added", 110], [COL_READ, "Read", 64]]:
		_list.set_column_title(spec[0], spec[1])
		_list.set_column_title_alignment(spec[0], HORIZONTAL_ALIGNMENT_LEFT)
		if spec[2] > 0:
			_list.set_column_expand(spec[0], false)
			_list.set_column_custom_minimum_width(spec[0], spec[2])
	_list.set_column_expand_ratio(COL_TITLE, 3)
	_list.set_column_clip_content(COL_TITLE, true)
	_list.set_column_clip_content(COL_TAGS, true)
	_list.column_title_clicked.connect(func(col, button):
		if button != MOUSE_BUTTON_LEFT:
			return
		if col == _sort_col:
			_sort_asc = not _sort_asc
		else:
			_sort_col = col
			_sort_asc = col in [COL_TITLE, COL_TAGS]
		_update_sort_titles()
		_build_list())
	_list.multi_selected.connect(_on_multi_selected)
	_list.item_activated.connect(_open_selected)
	_list.item_mouse_selected.connect(_on_list_rmb)
	_list.set_drag_forwarding(_list_get_drag, Callable(), Callable())
	center.add_child(_list)
	_update_sort_titles()

	var status_row := HBoxContainer.new()
	center.add_child(status_row)
	_status = _label("", 14)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(220, 0)
	_progress.max_value = 1.0
	_progress.step = 0.001
	_progress.show_percentage = false
	_progress.visible = false
	status_row.add_child(_progress)

	# Menus and dialogs.
	_paper_menu = PopupMenu.new()
	_paper_menu.id_pressed.connect(_on_paper_menu)
	add_child(_paper_menu)
	_add_menu = PopupMenu.new()
	_add_menu.id_pressed.connect(func(i):
		if i < _menu_collections.size():
			Library.add_to_collection(_selected_ids(), _menu_collections[i][0]))
	_paper_menu.add_child(_add_menu)
	_coll_menu = PopupMenu.new()
	_coll_menu.id_pressed.connect(_on_coll_menu)
	add_child(_coll_menu)
	_tag_menu = PopupMenu.new()
	_tag_menu.add_item("Rename tag…", 0)
	_tag_menu.add_item("Remove tag from all papers…", 1)
	_tag_menu.id_pressed.connect(_on_tag_menu)
	add_child(_tag_menu)

	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(func():
		if _confirm_action.is_valid():
			_confirm_action.call())
	_confirm.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm.min_size = Vector2i(420, 0)
	add_child(_confirm)

	_rename_dialog = ConfirmationDialog.new()
	_rename_edit = LineEdit.new()
	_rename_dialog.add_child(_rename_edit)
	_rename_dialog.register_text_enter(_rename_edit)
	_rename_dialog.confirmed.connect(func():
		if _rename_action.is_valid():
			_rename_action.call(_rename_edit.text))
	add_child(_rename_dialog)

	_files_dialog = FileDialog.new()
	_files_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_files_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_files_dialog.filters = PackedStringArray(["*.pdf ; PDF documents"])
	_files_dialog.use_native_dialog = true
	_files_dialog.title = "Import PDFs"
	_files_dialog.files_selected.connect(func(files): _queue_import(Array(files)))
	add_child(_files_dialog)
	_dir_dialog = FileDialog.new()
	_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dir_dialog.use_native_dialog = true
	_dir_dialog.title = "Import all PDFs in a folder"
	_dir_dialog.dir_selected.connect(func(d): _queue_import([d]))
	add_child(_dir_dialog)


func _update_sort_titles() -> void:
	var names := ["Title", "Tags", "Added", "Read"]
	for c in names.size():
		var t: String = names[c]
		if c == _sort_col:
			t += "  ▲" if _sort_asc else "  ▼"
		_list.set_column_title(c, t)


func _spacer_h(w: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size.x = w
	return s


# ------------------------------------------------------------------ cache

## Asks before removing all cached data (page analysis and leftover page images).
func ask_clear_cache() -> void:
	var info := Library.cache_info()
	if int(info["files"]) == 0:
		set_busy("There is no cached data to remove.")
		return
	_ask("Remove the cached data (%d file%s, %s)?\n\nYour papers, comments, reviews, tags and reading positions are kept. Each paper's page layout is analyzed again the next time you open it." % [
		int(info["files"]), "" if int(info["files"]) == 1 else "s", Library.size_text(int(info["bytes"]))],
		"Remove", func():
			var r := Library.clear_cache()
			set_busy("Removed %d cached file%s (%s)." % [int(r["files"]), "" if int(r["files"]) == 1 else "s", Library.size_text(int(r["bytes"]))]))

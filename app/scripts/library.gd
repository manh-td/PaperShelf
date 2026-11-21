extends Node
## Autoload "Library": papers, collections and tags, stored in library.json.
##
## A paper: {"id", "title", "file" (relative to the storage folder), "orig_name", "size",
##   "md5", "pages", "added" (unix time), "last_read" (unix time, 0 = never),
##   "collections": [collection ids], "tags": [names], "trashed": bool}
## A collection: {"id", "name", "parent" ("" = top level)}
## Like Zotero, a paper can be in several collections; deleting a collection
## keeps its papers in the library.
##
## Views for query(): "all", "unfiled", "trash" or "c:<collection id>".

signal changed

const FILE_NAME := "library.json"
const FORMAT := 1

var papers: Array = []
var collections: Array = []
var _next_id := 1
var _papers_by_id := {}
var _collections_by_id := {}
var _root := ""


func _ready() -> void:
	load_from(Pdf.storage_dir())


## Loads the library from a folder (used by tests to point at a scratch folder).
func load_from(root: String) -> void:
	_root = root
	papers = []
	collections = []
	_next_id = 1
	var path := _root.path_join(FILE_NAME)
	if FileAccess.file_exists(path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary:
			papers = data.get("papers", [])
			collections = data.get("collections", [])
			_next_id = int(data.get("next_id", 1))
		else:
			push_error("library.json could not be read; keeping a copy as library.json.bad")
			DirAccess.copy_absolute(path, path + ".bad")
	# Fill fields added in later versions.
	var defaults := {"title": "", "orig_name": "", "md5": "", "pages": 0, "added": 0, "last_read": 0,
		"tags": [], "collections": [], "trashed": false, "comments": []}
	for p in papers:
		for k in defaults:
			if not p.has(k):
				p[k] = defaults[k].duplicate() if defaults[k] is Array else defaults[k]
	_reindex()


func save() -> void:
	var data := {"format": FORMAT, "next_id": _next_id, "papers": papers, "collections": collections}
	var path := _root.path_join(FILE_NAME)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write " + tmp)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	DirAccess.rename_absolute(tmp, path)


func _commit() -> void:
	_reindex()
	save()
	changed.emit()


func _reindex() -> void:
	_papers_by_id.clear()
	for p in papers:
		_papers_by_id[p["id"]] = p
	_collections_by_id.clear()
	for c in collections:
		_collections_by_id[c["id"]] = c


func _new_id(prefix: String) -> String:
	var id := "%s%d" % [prefix, _next_id]
	_next_id += 1
	return id


func root_dir() -> String:
	return _root


func paper(id: String) -> Dictionary:
	return _papers_by_id.get(id, {})


func collection(id: String) -> Dictionary:
	return _collections_by_id.get(id, {})


func paper_path(p: Dictionary) -> String:
	return _root.path_join(String(p["file"]))


func display_title(p: Dictionary) -> String:
	var t := String(p.get("title", "")).strip_edges()
	return t if not t.is_empty() else String(p.get("orig_name", "Untitled")).get_basename()


# ------------------------------------------------------------------ papers

## Copies a PDF into the library. Returns {"paper": Dictionary} on success,
## {"duplicate": Dictionary} if the same file is already there, or {"error": String}.
func import_pdf(src: String, collection_id := "") -> Dictionary:
	if not FileAccess.file_exists(src):
		return {"error": "File not found: " + src}
	var md5 := FileAccess.get_md5(src)
	for p in papers:
		if p["md5"] == md5:
			var changed_any := false
			if p["trashed"]:
				p["trashed"] = false
				changed_any = true
			if not collection_id.is_empty() and not collection_id in p["collections"]:
				p["collections"].append(collection_id)
				changed_any = true
			if changed_any:
				_commit()
			return {"duplicate": p}
	var id := _new_id("p")
	var rel := "papers/%s.pdf" % id
	DirAccess.make_dir_recursive_absolute(_root.path_join("papers"))
	var err := DirAccess.copy_absolute(src, _root.path_join(rel))
	if err != OK:
		return {"error": "Could not copy %s (error %d)" % [src.get_file(), err]}
	var info: Dictionary = Pdf.pdf_info(_root.path_join(rel)) if Pdf.is_available() else {}
	var title := String(info.get("title", ""))
	if title.is_empty():
		title = _title_from_file_name(src.get_file())
	var p := {
		"id": id, "title": title, "file": rel, "orig_name": src.get_file(),
		"size": FileAccess.get_size(src), "md5": md5, "pages": int(info.get("pages", 0)),
		"added": int(Time.get_unix_time_from_system()), "last_read": 0,
		"collections": [] if collection_id.is_empty() else [collection_id],
		"tags": [], "trashed": false, "comments": [],
	}
	papers.append(p)
	_commit()
	return {"paper": p}


## "attention_is_all_you_need-v2.pdf" -> "attention is all you need-v2"
static func _title_from_file_name(name: String) -> String:
	return name.get_basename().replace("_", " ").strip_edges()


func set_title(id: String, title: String) -> void:
	var p := paper(id)
	if p.is_empty() or String(p["title"]) == title.strip_edges():
		return
	p["title"] = title.strip_edges()
	_commit()


# ------------------------------------------------------------------ comments
#
# A comment: {"id", "s", "e" (reading-position keys of the commented text, see reader_view.gd),
#   "quote" (the commented text, used to re-attach the comment if a newer analyzer
#   numbers lines differently), "category", "text", "subs": [point texts], "created", "updated"}


func comments(id: String) -> Array:
	return paper(id).get("comments", [])


## Adds a comment (no "id" yet) or replaces the one with the same id. Returns the stored comment.
func save_comment(id: String, c: Dictionary) -> Dictionary:
	var p := paper(id)
	if p.is_empty():
		return {}
	if not p.has("comments"):
		p["comments"] = []
	var now := int(Time.get_unix_time_from_system())
	var stored := c.duplicate(true)
	stored["updated"] = now
	if not stored.has("id") or String(stored["id"]).is_empty():
		stored["id"] = _new_id("n")
		stored["created"] = now
		p["comments"].append(stored)
	else:
		var list: Array = p["comments"]
		var at := -1
		for i in list.size():
			if list[i]["id"] == stored["id"]:
				at = i
		if at >= 0:
			list[at] = stored
		else:
			list.append(stored)
	_commit()
	return stored


## Updates fields the reader works out itself ("where", a cleaned "quote") without touching
## "updated" or notifying the library screen. Returns true if anything changed.
func set_comment_quiet(id: String, comment_id: String, fields: Dictionary) -> bool:
	for c in paper(id).get("comments", []):
		if c["id"] != comment_id:
			continue
		var changed_any := false
		for k in fields:
			if c.get(k) != fields[k]:
				c[k] = fields[k]
				changed_any = true
		if changed_any:
			save()
		return changed_any
	return false


# ------------------------------------------------------------------ reviews
#
# A review: {"merit", "sections": {key: text}, "included": [comment ids already collected],
#   "quotes": bool (items quote the commented text and its location), "updated"}
# Section keys and how comments fill them: review_builder.gd.

func review(id: String) -> Dictionary:
	return paper(id).get("review", {})


func save_review(id: String, r: Dictionary) -> void:
	var p := paper(id)
	if p.is_empty():
		return
	var stored := r.duplicate(true)
	stored["updated"] = int(Time.get_unix_time_from_system())
	p["review"] = stored
	_commit()


func delete_comment(id: String, comment_id: String) -> void:
	var p := paper(id)
	if p.is_empty():
		return
	p["comments"] = p.get("comments", []).filter(func(c): return c["id"] != comment_id)
	_commit()


static func _comment_text(p: Dictionary) -> String:
	var parts: Array[String] = []
	for c in p.get("comments", []):
		parts.append(String(c.get("text", "")))
		parts.append(String(c.get("category", "")))
		for s in c.get("subs", []):
			parts.append(String(s))
	return " ".join(parts)


func mark_read(id: String) -> void:
	var p := paper(id)
	if not p.is_empty():
		p["last_read"] = int(Time.get_unix_time_from_system())
		_commit()


func trash(ids: Array) -> void:
	for id in ids:
		var p := paper(id)
		if not p.is_empty():
			p["trashed"] = true
	_commit()


func restore(ids: Array) -> void:
	for id in ids:
		var p := paper(id)
		if not p.is_empty():
			p["trashed"] = false
	_commit()


## Deletes papers, their PDF copies and cached analysis. Cannot be undone.
func delete_permanently(ids: Array) -> void:
	var cache := _root.path_join("cache")
	var cache_files := DirAccess.get_files_at(cache) if DirAccess.dir_exists_absolute(cache) else PackedStringArray()
	var progress := ConfigFile.new()
	var progress_path := _root.path_join("progress.cfg")
	progress.load(progress_path)
	for id in ids:
		var p := paper(id)
		if p.is_empty():
			continue
		for section in ["progress", "totals"]:
			if progress.has_section_key(section, id):
				progress.erase_section_key(section, id)
		var file_name := String(p["file"]).get_file()
		DirAccess.remove_absolute(paper_path(p))
		for f in cache_files:
			if f.begins_with(file_name + "_"):
				DirAccess.remove_absolute(cache.path_join(f))
		papers.erase(p)
	if FileAccess.file_exists(progress_path):
		progress.save(progress_path)
	_commit()


func empty_trash() -> void:
	delete_permanently(papers.filter(func(p): return p["trashed"]).map(func(p): return p["id"]))


# ------------------------------------------------------------------ tags

static func clean_tag(tag: String) -> String:
	return tag.strip_edges().replace(",", " ").strip_edges()


func add_tags(ids: Array, tags: Array) -> void:
	for id in ids:
		var p := paper(id)
		if p.is_empty():
			continue
		for t in tags:
			var tag := clean_tag(String(t))
			if not tag.is_empty() and not tag in p["tags"]:
				p["tags"].append(tag)
		p["tags"].sort_custom(func(a, b): return String(a).naturalnocasecmp_to(b) < 0)
	_commit()


func remove_tag(ids: Array, tag: String) -> void:
	for id in ids:
		var p := paper(id)
		if not p.is_empty():
			p["tags"].erase(tag)
	_commit()


## Renames a tag everywhere (merging into an existing tag of the new name).
func rename_tag(old: String, new_name: String) -> void:
	var tag := clean_tag(new_name)
	if tag.is_empty() or tag == old:
		return
	for p in papers:
		if old in p["tags"]:
			p["tags"].erase(old)
			if not tag in p["tags"]:
				p["tags"].append(tag)
				p["tags"].sort_custom(func(a, b): return String(a).naturalnocasecmp_to(b) < 0)
	_commit()


func delete_tag(tag: String) -> void:
	for p in papers:
		p["tags"].erase(tag)
	_commit()


## Tag -> number of papers, for papers in `subset` (default: all papers not in the trash).
func tag_counts(subset = null) -> Dictionary:
	var list: Array = subset if subset is Array else papers.filter(func(p): return not p["trashed"])
	var counts := {}
	for p in list:
		for t in p["tags"]:
			counts[t] = int(counts.get(t, 0)) + 1
	return counts


# ------------------------------------------------------------------ collections

## How deep collections can nest below a top-level collection:
## Thesis (top) > Related work (1) > LLM repair (2), and no deeper.
const MAX_NESTING := 2


## 0 for a top-level collection, 1 for its subcollections, and so on.
func depth(id: String) -> int:
	var d := 0
	var c := collection(collection(id).get("parent", ""))
	while not c.is_empty() and d < 64:
		d += 1
		c = collection(String(c["parent"]))
	return d


## Levels of subcollections below a collection (0 if it has none).
func subtree_height(id: String) -> int:
	var h := 0
	for c in children(id):
		h = maxi(h, 1 + subtree_height(c["id"]))
	return h


## Whether a new subcollection can be made in `parent` ("" = top level is always fine).
func can_add_subcollection(parent: String) -> bool:
	return parent.is_empty() or depth(parent) < MAX_NESTING


## Whether `id` (with its subcollections) can be moved under `new_parent` ("" = top level).
func can_move_collection(id: String, new_parent: String) -> bool:
	if collection(id).is_empty() or id == new_parent or new_parent in descendants(id):
		return false
	var new_depth := 0 if new_parent.is_empty() else depth(new_parent) + 1
	return new_depth + subtree_height(id) <= MAX_NESTING


## Creates a collection; returns "" if `parent` is already as deep as collections may nest.
func add_collection(name: String, parent := "") -> String:
	if not can_add_subcollection(parent):
		return ""
	var id := _new_id("c")
	collections.append({"id": id, "name": name.strip_edges(), "parent": parent})
	_commit()
	return id


func rename_collection(id: String, name: String) -> void:
	var c := collection(id)
	if c.is_empty() or name.strip_edges().is_empty():
		return
	c["name"] = name.strip_edges()
	_commit()


## Moves a collection under another one ("" = top level). Refuses cycles and nesting
## deeper than MAX_NESTING.
func move_collection(id: String, new_parent: String) -> bool:
	var c := collection(id)
	if not can_move_collection(id, new_parent):
		return false
	c["parent"] = new_parent
	_commit()
	return true


## Deletes a collection and its subcollections. Papers stay in the library.
func delete_collection(id: String) -> void:
	var gone := descendants(id)
	gone.append(id)
	collections = collections.filter(func(c): return not c["id"] in gone)
	for p in papers:
		p["collections"] = p["collections"].filter(func(cid): return not cid in gone)
	_commit()


func children(parent: String) -> Array:
	var out := collections.filter(func(c): return c["parent"] == parent)
	out.sort_custom(func(a, b): return String(a["name"]).naturalnocasecmp_to(b["name"]) < 0)
	return out


func descendants(id: String) -> Array:
	var out := []
	for c in children(id):
		out.append(c["id"])
		out.append_array(descendants(c["id"]))
	return out


## Collection path for display, e.g. "Thesis / Related work".
func collection_path(id: String) -> String:
	var parts: Array[String] = []
	var c := collection(id)
	var guard := 0
	while not c.is_empty() and guard < 64:
		parts.push_front(String(c["name"]))
		c = collection(String(c["parent"]))
		guard += 1
	return " / ".join(parts)


func add_to_collection(ids: Array, cid: String) -> void:
	if collection(cid).is_empty():
		return
	for id in ids:
		var p := paper(id)
		if not p.is_empty() and not cid in p["collections"]:
			p["collections"].append(cid)
	_commit()


func remove_from_collection(ids: Array, cid: String) -> void:
	for id in ids:
		var p := paper(id)
		if not p.is_empty():
			p["collections"].erase(cid)
	_commit()


# ------------------------------------------------------------------ queries

## Papers in a view, having all `tags`, matching `search` (title, tags, file name).
func query(view: String, tags: Array = [], search := "") -> Array:
	var words := search.to_lower().split(" ", false)
	var out := []
	for p in papers:
		match view:
			"trash":
				if not p["trashed"]:
					continue
			"unfiled":
				if p["trashed"] or not p["collections"].is_empty():
					continue
			"all":
				if p["trashed"]:
					continue
			_:
				if p["trashed"] or not view.substr(2) in p["collections"]:
					continue
		var ok := true
		for t in tags:
			if not t in p["tags"]:
				ok = false
				break
		if ok and not words.is_empty():
			var hay := (display_title(p) + " " + " ".join(p["tags"]) + " " + String(p["orig_name"]) + " " + _comment_text(p)).to_lower()
			for w in words:
				if not hay.contains(w):
					ok = false
					break
		if ok:
			out.append(p)
	return out


func count(view: String) -> int:
	return query(view).size()

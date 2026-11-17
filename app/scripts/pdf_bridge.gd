extends Node
## Autoload "Pdf": talks to the Java PDF helper (helper/paperhelper.jar).
##
## The helper runs as a child process for the whole session. Requests and replies are
## one JSON object per line over its stdin/stdout (see pdf_helper/.../Main.kt).
## open/render/close wait for their reply; analysis runs in the background and is polled,
## like HighReader's Android plugin, so reader code can use the same calls.

const JAR_NAME := "paperhelper.jar"
const CALL_TIMEOUT_MS := 30000
const START_TIMEOUT_MS := 20000

var _pid: int = -1
var _stdio: FileAccess = null
var _stderr: FileAccess = null
var _reader: Thread = null
var _err_reader: Thread = null
var _mutex := Mutex.new()
var _responses: Dictionary = {}   # id -> reply Dictionary (from the reader thread)
var _next_id: int = 1
var _available: bool = false
var _last_error: String = ""
var _helper_version: int = -1

var _current_path: String = ""
var _render_count: int = 0
var _render_out: Dictionary = {}   # request id -> temp file (request_render)

# Analysis state, written by the reader thread under _mutex.
var _analysis_id: int = -1
var _analysis_state: String = "idle"   # "idle", "running", "done", "error"
var _analysis_progress: float = 0.0
var _analysis_result_path: String = ""


func _ready() -> void:
	_start_helper()


func _exit_tree() -> void:
	_stop_helper()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_stop_helper()


# ------------------------------------------------------------------ process

## Java to run: a bundled runtime next to the app, then JAVA_HOME, then Java on PATH.
## On Windows javaw.exe is used: same as java.exe but it never opens a console window.
func _find_java() -> String:
	var exe := "javaw.exe" if OS.get_name() == "Windows" else "java"
	var app_dir := OS.get_executable_path().get_base_dir()
	var candidates: Array[String] = [app_dir.path_join("runtime/bin").path_join(exe)]
	var java_home := OS.get_environment("JAVA_HOME")
	if not java_home.is_empty():
		candidates.append(java_home.path_join("bin").path_join(exe))
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	return "javaw" if OS.get_name() == "Windows" else "java"


## The jar sits next to an exported app (helper/), or in the project folder when run from the editor.
func _find_jar() -> String:
	var app_dir := OS.get_executable_path().get_base_dir()
	var candidates: Array[String] = [app_dir.path_join("helper").path_join(JAR_NAME)]
	if OS.has_feature("editor"):
		candidates.append(ProjectSettings.globalize_path("res://helper").path_join(JAR_NAME))
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	return ""


func _start_helper() -> void:
	# Leftover render files from an earlier session.
	var tmp_dir := storage_dir().path_join("tmp")
	if DirAccess.dir_exists_absolute(tmp_dir):
		for f in DirAccess.get_files_at(tmp_dir):
			if f.ends_with(".rgba"):
				DirAccess.remove_absolute(tmp_dir.path_join(f))
	var jar := _find_jar()
	if jar.is_empty():
		_last_error = "PDF helper not found (%s). Build it with: pdf_helper/gradlew copyJarToGodot" % JAR_NAME
		push_error(_last_error)
		return
	var java := _find_java()
	var info: Dictionary = OS.execute_with_pipe(java, PackedStringArray(["-Xss4m", "-jar", jar]))
	if info.is_empty():
		_last_error = "Could not start Java (%s). Install Java 17 or newer." % java
		push_error(_last_error)
		return
	_pid = info["pid"]
	_stdio = info["stdio"]
	_stderr = info["stderr"]
	_reader = Thread.new()
	_reader.start(_read_loop)
	_err_reader = Thread.new()
	_err_reader.start(_stderr_loop)
	var r := _call({"cmd": "ping"}, START_TIMEOUT_MS)
	if r.get("ok", false):
		_available = true
		_helper_version = int(r.get("version", -1))
		print_verbose("PDF helper ready: analyzer v%d, java=%s, jar=%s" % [_helper_version, java, jar])
	else:
		push_error("PDF helper did not answer: " + _last_error)


func _stop_helper() -> void:
	if _pid < 0:
		return
	_available = false
	if OS.is_process_running(_pid):
		_send({"id": 0, "cmd": "quit"})
		var t0 := Time.get_ticks_msec()
		while OS.is_process_running(_pid) and Time.get_ticks_msec() - t0 < 1500:
			OS.delay_msec(10)
		if OS.is_process_running(_pid):
			OS.kill(_pid)
	if _reader and _reader.is_started():
		_reader.wait_to_finish()
	if _err_reader and _err_reader.is_started():
		_err_reader.wait_to_finish()
	_stdio = null
	_stderr = null
	_pid = -1


func _read_loop() -> void:
	while true:
		var line := _stdio.get_line()
		if line.is_empty():
			if _stdio.get_error() != OK or not OS.is_process_running(_pid):
				break
			continue
		var msg = JSON.parse_string(line)
		if not (msg is Dictionary):
			continue
		var id := int(msg.get("id", -1))
		_mutex.lock()
		if msg.has("event"):
			if msg["event"] == "progress" and id == _analysis_id:
				_analysis_progress = float(msg.get("value", 0.0))
		elif id == _analysis_id and id > 0:
			if msg.get("ok", false):
				_analysis_result_path = str(msg.get("result", ""))
				_analysis_progress = 1.0
				_analysis_state = "done"
			else:
				_last_error = str(msg.get("error", "analysis failed"))
				_analysis_state = "error"
		elif id > 0:
			_responses[id] = msg
		_mutex.unlock()


func _stderr_loop() -> void:
	while true:
		var line := _stderr.get_line()
		if line.is_empty():
			if _stderr.get_error() != OK or not OS.is_process_running(_pid):
				break
			continue
		print_verbose("[pdf helper] ", line)


func _send(req: Dictionary) -> void:
	if _stdio:
		_stdio.store_line(JSON.stringify(req))
		_stdio.flush()


## Sends a request and waits for its reply. Returns {} on failure (see last_error()).
func _call(req: Dictionary, timeout_ms: int = CALL_TIMEOUT_MS) -> Dictionary:
	if _pid < 0:
		return {}
	var id := _next_id
	_next_id += 1
	req["id"] = id
	_send(req)
	var t0 := Time.get_ticks_msec()
	while true:
		_mutex.lock()
		var r = _responses.get(id)
		if r != null:
			_responses.erase(id)
		_mutex.unlock()
		if r != null:
			if not r.get("ok", false):
				_last_error = str(r.get("error", "unknown error"))
				return {}
			return r
		if not OS.is_process_running(_pid):
			_last_error = "PDF helper stopped"
			_available = false
			return {}
		if Time.get_ticks_msec() - t0 > timeout_ms:
			_last_error = "PDF helper timed out on " + str(req.get("cmd"))
			return {}
		OS.delay_usec(500)
	return {}


# ---------------------------------------------------------------- public API

func is_available() -> bool:
	return _available


func helper_version() -> int:
	return _helper_version


## Returns {"name":..., "pages":[[w,h],...]} (points, rotation applied) or {} on failure.
func open_pdf(path: String) -> Dictionary:
	var r := _call({"cmd": "open", "path": ProjectSettings.globalize_path(path)})
	if r.is_empty():
		_current_path = ""
		return {}
	_current_path = ProjectSettings.globalize_path(path)
	return {"name": r.get("name", ""), "pages": r.get("pages", [])}


## Page count and title guess for a PDF (does not change the open document).
## Returns {"pages": int, "title": String} or {} on failure.
func pdf_info(path: String) -> Dictionary:
	var r := _call({"cmd": "info", "path": ProjectSettings.globalize_path(path)})
	if r.is_empty():
		return {}
	return {"pages": int(r.get("pages", 0)), "title": String(r.get("title", ""))}


## Renders one page `width` pixels wide. Returns null on failure.
func render_page(index: int, width: int) -> Texture2D:
	var img := render_page_image(index, width)
	return ImageTexture.create_from_image(img) if img else null


## Same as render_page, but returns the Image (usable from a background thread later).
func render_page_image(index: int, width: int) -> Image:
	var tmp_dir := storage_dir().path_join("tmp")
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	_render_count += 1
	var out := tmp_dir.path_join("render_%d.rgba" % _render_count)
	var r := _call({"cmd": "render", "page": index, "width": width, "out": out})
	if r.is_empty():
		return null
	var bytes := FileAccess.get_file_as_bytes(out)
	DirAccess.remove_absolute(out)
	var w := int(r["width"])
	var h := int(r["height"])
	if bytes.size() != w * h * 4:
		_last_error = "render returned %d bytes, expected %d" % [bytes.size(), w * h * 4]
		return null
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)


## Starts rendering a page without waiting. Returns a request id for take_render(), or -1.
func request_render(index: int, width: int) -> int:
	if _pid < 0:
		return -1
	var tmp_dir := storage_dir().path_join("tmp")
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	_render_count += 1
	var id := _next_id
	_next_id += 1
	var out := tmp_dir.path_join("render_%d.rgba" % _render_count)
	_render_out[id] = out
	_send({"id": id, "cmd": "render", "page": index, "width": width, "out": out})
	return id


## For a request_render() id: {} while still rendering, else {"image": Image or null}.
func take_render(id: int) -> Dictionary:
	_mutex.lock()
	var r = _responses.get(id)
	if r != null:
		_responses.erase(id)
	_mutex.unlock()
	if r == null:
		if not OS.is_process_running(_pid):
			_render_out.erase(id)
			return {"image": null}
		return {}
	var out: String = _render_out.get(id, "")
	_render_out.erase(id)
	if not r.get("ok", false):
		_last_error = str(r.get("error", "render failed"))
		return {"image": null}
	var bytes := FileAccess.get_file_as_bytes(out)
	DirAccess.remove_absolute(out)
	var w := int(r["width"])
	var h := int(r["height"])
	if bytes.size() != w * h * 4:
		return {"image": null}
	return {"image": Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)}


func close_pdf() -> void:
	_call({"cmd": "close"})
	_current_path = ""
	_mutex.lock()
	_analysis_id = -1
	_analysis_state = "idle"
	_analysis_result_path = ""
	_mutex.unlock()


## Starts analysis of the open PDF (or `path`) in the background. Results are cached
## in `cache` (default: cache_dir()).
func start_analysis(path: String = "", cache: String = "") -> bool:
	var file := ProjectSettings.globalize_path(path) if not path.is_empty() else _current_path
	if file.is_empty() or _pid < 0:
		return false
	var id := _next_id
	_next_id += 1
	_mutex.lock()
	_analysis_id = id
	_analysis_state = "running"
	_analysis_progress = 0.0
	_analysis_result_path = ""
	_mutex.unlock()
	_send({"id": id, "cmd": "analyze", "path": file, "cache_dir": cache if not cache.is_empty() else cache_dir()})
	return true


## "idle", "running", "done" or "error".
func analysis_state() -> String:
	_mutex.lock()
	var s := _analysis_state
	_mutex.unlock()
	if s == "running" and not OS.is_process_running(_pid):
		return "error"
	return s


func analysis_progress() -> float:
	_mutex.lock()
	var p := _analysis_progress
	_mutex.unlock()
	return p


## The analysis JSON (see HighReader's CLAUDE.md for the format), or {} if not done.
func analysis_result() -> Dictionary:
	_mutex.lock()
	var path := _analysis_result_path
	_mutex.unlock()
	if path.is_empty():
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else {}


## Folder for the library, cache and settings (user:// as an absolute path).
func storage_dir() -> String:
	return ProjectSettings.globalize_path("user://")


func cache_dir() -> String:
	return storage_dir().path_join("cache")


## Path for a small data file in the storage folder.
func data_path(file_name: String) -> String:
	return storage_dir().path_join(file_name)


func last_error() -> String:
	return _last_error

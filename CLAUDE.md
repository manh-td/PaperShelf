# PaperShelf

Desktop app (Godot 4.7 + a Java helper process) for reading papers one sentence or line at a
time, like HighReader, with a small Zotero-style library (collections, tags). Mainly used
on Linux; developed on Windows.

## Layout

```
app/                         Godot project (GL Compatibility renderer, user dir "PaperShelf")
  scripts/pdf_bridge.gd      Autoload "Pdf": starts the helper and talks to it over a pipe
  scripts/library.gd         Autoload "Library": papers, collections, tags in library.json
  scripts/library_view.gd    Library screen: collections + tags | paper list | details
  scripts/main.gd            Shell: library <-> reader, opening (analysis) and theme
  scripts/reader_view.gd     Reader: modes, framing/zoom, async page textures, keyboard and mouse
  scripts/steps_builder.gd   Copied unchanged from HighReader: lines -> sentence/line/float steps
  scripts/settings_panel.gd  Settings overlay (fit, scrolling, colors, style, dim, skip side columns)
  scripts/contents_panel.gd  Contents drawer (left, keyboard-driven ItemList)
  helper/paperhelper.jar     Built helper (copied by Gradle; .gdignore keeps Godot out)
  tests/bridge_test.gd       Headless end-to-end check of the bridge and helper
  tests/reader_shots.gd      Windowed run: opens a PDF, presses reader keys, saves screenshots
  tests/library_test.gd      Headless library model checks (scratch folder)
  tests/library_shots.gd     Windowed library run: import, collections, tags, open, trash (scratch folder)
  tests/sentences_sample.gd, mode_switch_drift.gd   From HighReader; run on a cache JSON
pdf_helper/                  Kotlin/JVM Gradle project for the helper
  src/main/kotlin/com/papershelf/helper/
    Main.kt                  JSON-lines protocol on stdin/stdout: ping, open, render, close, info, analyze, quit
    TitleGuesser.kt          Title for new papers: PDF Title field if it looks real, else largest text on page 1
    PaperAnalyzer.kt         Copy of HighReader's analyzer (only PdfBox imports changed)
tools/make_test_pdf.ps1      Generates a synthetic two-column test paper
```

## Build and test (this machine)

Godot: `D:\Godot\Godot_v4.7.2-stable_win64_console.exe`. JDK 17: `C:\Program Files\Eclipse Adoptium\jdk-17.0.21.9-hotspot`.

1. Build the helper (JAVA_HOME = JDK 17): `pdf_helper\gradlew.bat -p pdf_helper copyJarToGodot`
2. Test: `Godot --headless --path app --script res://tests/bridge_test.gd -- <file.pdf> [--fresh]`
   (`--fresh` drops the cached analysis first).
3. Check scripts compile: `Godot --headless --path app --quit-after 30`.

## Linux package

`powershell -ExecutionPolicy Bypass -File tools\build_linux.ps1` builds
`build/PaperShelf-linux-x86_64.tar.gz` (~78 MB): helper jar, Godot export (preset "Linux",
pck embedded), and the Adoptium JRE 17 from `build/downloads/` as `PaperShelf/runtime/`.
- Needs Godot 4.7.2 export templates in `%APPDATA%\Godot\export_templates\4.7.2.stable`.
- Packing is the Gradle `packageLinux` task: it sets Unix modes (0755 for the app and the
  script, JRE modes kept from its tarball) and LF line endings, so it works from Windows.
- `tools/linux/`: README.txt and install-desktop-entry.sh (adds a menu entry) go into the package.
- Windows: `tools\build_windows.ps1` builds `build/PaperShelf-windows-x86_64.zip` (~84 MB) the same
  way (Gradle `packageWindows`, JRE zip from `build/downloads/`, README from `tools/windows/`).
  On Windows the bridge runs `javaw.exe` so no console window opens.
- `--verbose` prints "PDF helper ready: ... java=..., jar=..." to check which runtime was used.

## CI: building the packages on GitHub

`.github/workflows/build.yml` (manual trigger: Actions > "Build packages" > Run workflow).
On ubuntu-latest: JDK 17, Godot 4.7.2 editor + export templates (SHA-512 checked, cached),
Adoptium JRE 17 for Linux and Windows (SHA-256 checked), builds the helper jar, exports
both presets, runs `packageLinux packageWindows`, checks permissions and the bundled
runtime, then smoke-tests the Linux package (helper ping with the bundled Java, and the app
started headless must log "PDF helper ready"). Uploads both packages as artifacts and,
optionally, publishes a Release tagged `v<version>`.
- Inputs: `version_name` (file names; empty = `0.0-build<run number>`), `publish_release`.
- No secrets needed. Android is not built: PaperShelf has no Android backend yet.

## How the helper works

- `pdf_bridge.gd` runs `java -jar helper/paperhelper.jar` once. Java is looked up as
  `<app dir>/runtime/bin/java` (bundled runtime, for the Linux export), then `$JAVA_HOME/bin/java`, then `java` on PATH.
  The jar is looked up in `<app dir>/helper/`, then (editor only) `res://helper/`.
- open/render/close wait for their reply. Analysis runs on a helper thread and is polled
  (`analysis_state()`, `analysis_progress()`, `analysis_result()`), same API as HighReader's plugin.
- Rendering writes raw RGBA8 to `user://tmp/` and the bridge loads it into an Image.
- Analysis is cached in `user://cache/<file>_<size>_v<VERSION>.json` (same format as HighReader).
- The helper exits when its stdin closes, so it never outlives the app.
- **Keep `PaperAnalyzer.kt` in sync with HighReader** and bump `VERSION` when output changes.

## Reader (reader_view.gd)

- Same modes and steps as HighReader. Zoom is `view_scale` (px per page width); fits:
  `column` (default: the column fills READ_WIDTH * zoom), `text` (the highlight does), `width`, `page`.
  Figures always fit their region. `follow`: `center` keeps the highlight at 40% height, `minimal` scrolls only near the edges.
- Keys: →/↓/Space/J/Enter next, ←/↑/Shift+Space/K back, PgDn/PgUp page, Home/End, 1-4 mode,
  +/−/0 zoom, C/Tab contents, S settings, Esc back. Wheel steps (scrolls in Free), Ctrl+wheel zooms,
  click a word to jump, drag (or middle-drag) to look around. F11 fullscreen (main.gd).
- Bar buttons use FOCUS_NONE so arrow keys never move GUI focus; keys are read in `_unhandled_key_input`.
- Pages render asynchronously (`Pdf.request_render` / `take_render`), at most 2 at a time.
- Reading positions live in `<library root>/progress.cfg`, keyed by paper id.

## Library (library.gd, library_view.gd)

- Storage (`user://`, i.e. `~/.local/share/PaperShelf` on Linux, `%APPDATA%\PaperShelf` on Windows):
  `library.json`, `papers/<id>.pdf` (copies), `cache/` (analysis), `progress.cfg`, `settings.cfg`.
- Zotero-like: a paper can be in several collections; collections nest; deleting a collection
  keeps its papers; Trash, then Delete permanently (removes the copy, cache and progress).
- Import copies the file, skips duplicates by MD5, and asks the helper (`info`) for a title.
- Views: "all", "unfiled", "trash", "c:<id>"; tag filter is AND; search matches title, tags, file name.
- Keys: Enter open, Delete trash, F2 rename, Ctrl+O / Ctrl+Shift+O import, Ctrl+F search, Ctrl+N new collection.
- Tests use `Library.load_from(<scratch dir>)` so the real library is never touched.

## Conventions

- GDScript: explicit types where inference fails. UI is built in code.

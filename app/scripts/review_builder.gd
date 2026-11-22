extends RefCounted
## Turns a paper's comments into review sections, and a review into Markdown.
##
## The layout follows a typical conference review: Overall merit, Paper summary, Strengths,
## Weaknesses, Detailed comments for authors (an intro, then one part per aspect),
## Questions for authors' response, References.

## [key, title, kind]: "list" = bullet items, "detail" = a part of the detailed comments,
## "prose" = paragraphs. "intro" and "references" are written by hand.
const SECTIONS := [
	["summary", "Paper summary", "prose"],
	["strengths", "Strengths", "list"],
	["weaknesses", "Weaknesses", "list"],
	["intro", "Detailed comments for authors", "prose"],
	["novelty", "Originality/Novelty", "detail"],
	["significance", "Significance", "detail"],
	["soundness", "Soundness", "detail"],
	["verifiability", "Verifiability", "detail"],
	["presentation", "Presentation", "detail"],
	["other", "Other comments", "detail"],
	["questions", "Questions for authors’ response", "list"],
	["references", "References", "prose"],
]

## Comment category -> section. Comments without a category go to "other".
const CATEGORY_SECTION := {
	"Paper summary": "summary",
	"Strength": "strengths",
	"Weakness": "weaknesses",
	"Question": "questions",
	"Novelty": "novelty",
	"Significance": "significance",
	"Rigor/Soundness": "soundness",
	"Verifiability": "verifiability",
	"Presentation": "presentation",
	"Others": "other",
}

const MERITS := ["", "Strong reject", "Reject", "Weak reject", "Borderline", "Weak accept", "Accept", "Strong accept"]
const MAX_QUOTE := 220


static func section_for(category: String) -> String:
	return CATEGORY_SECTION.get(category, "other")


static func section_kind(key: String) -> String:
	for s in SECTIONS:
		if s[0] == key:
			return s[2]
	return "prose"


static var _line_break_hyphen := RegEx.create_from_string("(\\p{L})- (\\p{L})")


## A quote for reading: words split at a line end ("compre- hension") joined again (the
## hyphen is kept, since a line break cannot tell "problem-solving" from "compre-hension"),
## and long quotes cut at a word boundary.
static func pretty_quote(text: String, max_len := MAX_QUOTE) -> String:
	var q := _line_break_hyphen.sub(text.strip_edges(), "$1-$2", true)
	if q.length() > max_len:
		var cut := q.left(max_len)
		var at := cut.rfind(" ")
		q = (cut.left(at) if at > max_len / 2 else cut).strip_edges() + " …"
	return q


static func _quote(c: Dictionary) -> String:
	return pretty_quote(String(c.get("quote", "")))


## "Section 2 (Methodology), Subsection 2.1 (Study Setup), sentence 2, p. 4: “…”"
static func citation(c: Dictionary) -> String:
	var where := String(c.get("where", "")).strip_edges()
	var q := _quote(c)
	if q.is_empty():
		return where
	return ("%s: “%s”" % [where, q]) if not where.is_empty() else "“%s”" % q


static func _sentence(t: String) -> String:
	t = t.strip_edges()
	if t.is_empty() or t[t.length() - 1] in [".", "?", "!", ":", ";"]:
		return t
	return t + "."


## One comment as text for its section.
static func item_text(c: Dictionary, kind: String, quotes: bool) -> String:
	var text := String(c.get("text", "")).strip_edges()
	var subs: Array = c.get("subs", [])
	match kind:
		"list":
			var out := "- " + text
			if quotes:
				var cite := citation(c)
				if not cite.is_empty():
					out += " (" + cite + ")"
			for s in subs:
				out += "\n  - " + String(s).strip_edges()
			return out
		"detail":
			var out := ""
			if quotes:
				var cite := citation(c)
				if not cite.is_empty():
					out = "> " + cite + "\n\n"
			out += text
			if not subs.is_empty():
				out += "\n"
				for s in subs:
					out += "\n- " + String(s).strip_edges()
			return out
		_:
			# Prose (the summary): the comment and its points as sentences.
			var parts: Array[String] = [_sentence(text)]
			for s in subs:
				parts.append(_sentence(String(s)))
			return " ".join(parts)


## Sections that comments fill (everything but the hand-written intro and references).
static func comment_sections() -> Array:
	return SECTIONS.map(func(s): return s[0]).filter(func(k): return not k in ["intro", "references"])


## The comment sections as they would be generated from `comments` now (reading order).
static func generate(comments: Array, quotes: bool) -> Dictionary:
	var out := {}
	for key in comment_sections():
		out[key] = ""
	var sorted := comments.duplicate()
	sorted.sort_custom(func(a, b): return int(a["s"]) < int(b["s"]))
	for c in sorted:
		var key := section_for(String(c.get("category", "")))
		var kind := section_kind(key)
		var item := item_text(c, kind, quotes)
		var sep := "\n" if kind == "list" else "\n\n"
		out[key] = item if String(out[key]).is_empty() else String(out[key]) + sep + item
	return out


## Brings the review up to date with the comments. A section the user has not edited (its
## text is still what was last generated, or it is empty) is regenerated, so re-categorized,
## edited, moved and new comments show up. Edited sections are kept as they are; see
## stale_sections(). With `force`, every comment section is regenerated (Rebuild).
## Reviews made before this ("generated" missing) count their non-empty sections as edited.
static func sync(review: Dictionary, comments: Array, force := false) -> Dictionary:
	var r := review.duplicate(true)
	if not r.has("sections"):
		r["sections"] = {}
	if not r.has("quotes"):
		r["quotes"] = true
	var generated: Dictionary = r.get("generated", {})
	var fresh := generate(comments, bool(r["quotes"]))
	for key in comment_sections():
		var cur := String(r["sections"].get(key, ""))
		var untouched := cur.strip_edges().is_empty() or (generated.has(key) and cur == String(generated[key]))
		if force or untouched:
			r["sections"][key] = fresh[key]
			generated[key] = fresh[key]
	r["generated"] = generated
	r["included"] = comments.map(func(c): return c["id"])
	return r


## Sections the user edited whose comments have changed since (they are not updated
## automatically; the review screen offers "Update from comments" for each).
static func stale_sections(review: Dictionary, comments: Array) -> Array:
	var generated: Dictionary = review.get("generated", {})
	var fresh := generate(comments, bool(review.get("quotes", true)))
	var out := []
	for key in comment_sections():
		var cur := String(review.get("sections", {}).get(key, ""))
		var edited := not cur.strip_edges().is_empty() and (not generated.has(key) or cur != String(generated[key]))
		if edited and fresh[key] != String(generated.get(key, "")):
			out.append(key)
	return out


## Replaces one section with what the comments give now (after the user confirms).
static func update_section(review: Dictionary, comments: Array, key: String) -> Dictionary:
	var r := review.duplicate(true)
	var fresh := generate(comments, bool(r.get("quotes", true)))
	r["sections"][key] = fresh[key]
	if not r.has("generated"):
		r["generated"] = {}
	r["generated"][key] = fresh[key]
	return r


## The review as Markdown, laid out like a conference review form.
static func to_markdown(review: Dictionary, title: String) -> String:
	var sec: Dictionary = review.get("sections", {})
	var text := func(key: String) -> String: return String(sec.get(key, "")).strip_edges()
	var out := "# %s\n\n" % title
	var merit := String(review.get("merit", ""))
	if not merit.is_empty():
		out += "## Overall merit: %s\n\n" % merit
	for key in ["summary", "strengths", "weaknesses"]:
		if not text.call(key).is_empty():
			out += "## %s\n\n%s\n\n" % [_title(key), text.call(key)]
	var details := ""
	for key in ["novelty", "significance", "soundness", "verifiability", "presentation", "other"]:
		if not text.call(key).is_empty():
			details += "**%s**\n\n%s\n\n" % [_title(key), text.call(key)]
	if not text.call("intro").is_empty() or not details.is_empty():
		out += "## Detailed comments for authors\n\n"
		if not text.call("intro").is_empty():
			out += text.call("intro") + "\n\n"
		out += details
	if not text.call("questions").is_empty():
		out += "## %s\n\n%s\n\n" % [_title("questions"), text.call("questions")]
	if not text.call("references").is_empty():
		out += "## References\n\n%s\n" % text.call("references")
	return out.strip_edges() + "\n"


static func _title(key: String) -> String:
	for s in SECTIONS:
		if s[0] == key:
			return s[1]
	return key

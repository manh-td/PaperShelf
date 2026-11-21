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


## Adds the comments not in the review yet (all of them with `rebuild`, which first clears
## the sections that comments fill). Hand-written parts (merit, intro, references) stay.
static func collect(review: Dictionary, comments: Array, rebuild: bool) -> Dictionary:
	var r := review.duplicate(true)
	if not r.has("sections"):
		r["sections"] = {}
	if not r.has("quotes"):
		r["quotes"] = true
	var included: Array = [] if rebuild else r.get("included", []).duplicate()
	if rebuild:
		for s in SECTIONS:
			if not s[0] in ["intro", "references"]:
				r["sections"][s[0]] = ""
	var fresh := comments.filter(func(c): return not c["id"] in included)
	fresh.sort_custom(func(a, b): return int(a["s"]) < int(b["s"]))
	for c in fresh:
		var key := section_for(String(c.get("category", "")))
		var kind := section_kind(key)
		var item := item_text(c, kind, bool(r["quotes"]))
		var cur := String(r["sections"].get(key, "")).strip_edges()
		var sep := "\n" if kind == "list" else "\n\n"
		r["sections"][key] = item if cur.is_empty() else cur + sep + item
		included.append(c["id"])
	r["included"] = included
	return r


static func new_count(review: Dictionary, comments: Array) -> int:
	var included: Array = review.get("included", [])
	return comments.filter(func(c): return not c["id"] in included).size()


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

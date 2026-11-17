package com.papershelf.helper

import org.apache.pdfbox.pdmodel.PDDocument
import org.apache.pdfbox.text.PDFTextStripper
import org.apache.pdfbox.text.TextPosition
import kotlin.math.abs
import kotlin.math.max

/**
 * Guesses a paper's title when it is added to the library: the PDF's own Title field
 * if it looks real, otherwise the largest text in the upper part of page 1.
 */
object TitleGuesser {
    private val junkMeta = Regex(
        "^(untitled|title|paper|document|slide|manuscript|microsoft word|doi:|arxiv:|\\d+$)|\\.(dvi|docx?|tex|pdf|ps|indd|qxd)$",
        RegexOption.IGNORE_CASE,
    )

    private val afterTitle = Regex(
        "^(author\\(?s?\\)?:|authors?\\b|by\\s|source:|published|stable url|abstract\\b|doi\\b|https?://)",
        RegexOption.IGNORE_CASE,
    )

    private class Run(val text: String, val size: Float, val y: Float, val x: Float)

    private class RunStripper : PDFTextStripper() {
        val runs = ArrayList<Run>()

        override fun writeString(text: String, textPositions: MutableList<TextPosition>) {
            if (textPositions.isEmpty() || textPositions[0].dir != 0f) return
            var size = 0f
            for (tp in textPositions) {
                val y = abs(tp.yScale)
                val s = if (y in 2f..200f) y else tp.fontSizeInPt
                size = max(size, s)
            }
            runs.add(Run(text, size, textPositions[0].yDirAdj, textPositions[0].xDirAdj))
        }
    }

    fun metaTitle(doc: PDDocument): String {
        val t = (doc.documentInformation?.title ?: "").replace(Regex("\\s+"), " ").trim()
        if (t.length < 4 || t.length > 300 || !t.contains(' ') || junkMeta.containsMatchIn(t)) return ""
        return t
    }

    fun firstPageTitle(doc: PDDocument): String {
        if (doc.numberOfPages == 0) return ""
        val stripper = RunStripper().apply {
            sortByPosition = true
            startPage = 1
            endPage = 1
        }
        stripper.getText(doc)
        val pageH = doc.getPage(0).cropBox.height
        val runs = stripper.runs.filter { it.text.count { c -> c.isLetter() } >= 2 }
        if (runs.isEmpty()) return ""
        // Body size: the size carrying the most characters.
        val hist = HashMap<Int, Int>()
        for (r in runs) hist[(r.size * 2).toInt()] = (hist[(r.size * 2).toInt()] ?: 0) + r.text.length
        val body = (hist.maxByOrNull { it.value }?.key ?: 20) / 2f
        val upper = runs.filter { it.y < pageH * 0.6f }
        if (upper.isEmpty()) return ""
        val top = upper.maxOf { it.size }
        if (top < body * 1.15f) return ""
        val big = upper.filter { it.size >= top - 0.6f }.sortedWith(compareBy({ it.y }, { it.x }))
        // The first block of big lines (a title may wrap onto 2-3 lines).
        val lines = ArrayList<String>()
        var lastY = Float.NaN
        for (r in big) {
            if (!lastY.isNaN() && abs(r.y - lastY) < top * 0.3f) {
                lines[lines.size - 1] = lines.last() + " " + r.text
                continue
            }
            if (!lastY.isNaN() && r.y - lastY > top * 2.2f) break
            // Cover pages (e.g. JSTOR) continue with citation details in the same size.
            if (lines.isNotEmpty() && afterTitle.containsMatchIn(r.text.trim())) break
            if (lines.size == 4) break
            lines.add(r.text)
            lastY = r.y
        }
        var title = lines.joinToString(" ").replace(Regex("\\s+"), " ").trim()
        // Words split by a line-end hyphen: "Lat- tices" -> "Lattices".
        title = title.replace(Regex("(\\p{L})- (\\p{Ll})"), "$1$2")
        return if (title.length > 300) title.take(297) + "..." else title
    }
}

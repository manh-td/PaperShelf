package com.papershelf.helper

import org.apache.pdfbox.pdmodel.PDDocument
import org.apache.pdfbox.rendering.ImageType
import org.apache.pdfbox.rendering.PDFRenderer
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.BufferedReader
import java.io.File
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.io.PrintStream
import java.util.concurrent.Executors
import java.util.logging.Level
import java.util.logging.Logger
import kotlin.math.roundToInt
import kotlin.system.exitProcess

/**
 * PDF helper process for PaperShelf.
 *
 * The Godot app starts this once and talks to it with one JSON object per line:
 * requests on stdin, responses and events on stdout (UTF-8). Every request has an
 * integer "id"; its response carries the same id plus "ok" (and "error" when false).
 *
 *   {"id":1,"cmd":"ping"}                                   -> {"id":1,"ok":true,"version":17}
 *   {"id":2,"cmd":"open","path":"/x.pdf"}                   -> {"id":2,"ok":true,"name":"x.pdf","pages":[[w,h],...]}
 *   {"id":3,"cmd":"render","page":0,"width":1600,"out":"/tmp/p.rgba"}
 *                                                           -> {"id":3,"ok":true,"width":1600,"height":2071}
 *      Writes raw RGBA8 pixels (width*height*4 bytes) to "out".
 *   {"id":4,"cmd":"close"}                                  -> {"id":4,"ok":true}
 *   {"id":7,"cmd":"info","path":"/x.pdf"}                   -> {"id":7,"ok":true,"pages":7,"title":"...",
 *                                                               "meta_title":"...","page_title":"..."}
 *   {"id":5,"cmd":"analyze","path":"/x.pdf","cache_dir":"/c"}
 *      Runs in the background. Sends {"event":"progress","id":5,"value":0.4} while running, then
 *      {"id":5,"ok":true,"result":"/c/x.pdf_1234_v17.json","cached":false}. A new "analyze"
 *      cancels the previous one (its response is then {"id":..,"ok":false,"error":"cancelled"}).
 *   {"id":6,"cmd":"quit"}
 *
 * The process exits when stdin closes, so it never outlives the app.
 */

private val out = PrintStream(FileOutputStream(FileDescriptor.out), true, "UTF-8")
private val outLock = Any()

// Kept in a field so the logger configuration is not garbage-collected.
private val pdfboxLogger: Logger = Logger.getLogger("org.apache")

private var doc: PDDocument? = null
private var renderer: PDFRenderer? = null

private val analysisExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "analysis").apply { isDaemon = true } }
@Volatile private var analysisGeneration = 0

private fun send(obj: JSONObject) {
    synchronized(outLock) {
        out.print(obj.toString())
        out.print('\n')
        out.flush()
    }
}

private fun reply(id: Int, ok: Boolean = true) = JSONObject().put("id", id).put("ok", ok)

fun main() {
    System.setProperty("java.awt.headless", "true")
    // PDFBox logs a warning for every odd font; keep stderr quiet.
    pdfboxLogger.level = Level.SEVERE
    // Nothing else may write to stdout: it carries the protocol.
    System.setOut(System.err)

    val input = BufferedReader(InputStreamReader(System.`in`, Charsets.UTF_8))
    while (true) {
        // Some shells prepend a byte-order mark to piped input.
        val line = (input.readLine() ?: break).removePrefix("﻿")
        if (line.isBlank()) continue
        var id = -1
        try {
            val req = JSONObject(line)
            id = req.optInt("id", -1)
            when (val cmd = req.optString("cmd")) {
                "ping" -> send(reply(id).put("version", PaperAnalyzer.VERSION))
                "open" -> send(open(id, req.getString("path")))
                "render" -> send(render(id, req.getInt("page"), req.getInt("width"), req.getString("out")))
                "close" -> { closeDoc(); send(reply(id)) }
                "info" -> send(info(id, req.getString("path")))
                "analyze" -> startAnalysis(id, File(req.getString("path")), File(req.getString("cache_dir")))
                "quit" -> { send(reply(id)); break }
                else -> send(reply(id, false).put("error", "unknown command: $cmd"))
            }
        } catch (t: Throwable) {
            send(reply(id, false).put("error", t.message ?: t.toString()))
        }
    }
    closeDoc()
    exitProcess(0)
}

// ------------------------------------------------------------------ rendering

private fun closeDoc() {
    try { doc?.close() } catch (_: Exception) {}
    doc = null
    renderer = null
}

/** Page size in points as displayed, i.e. with the page rotation applied. */
private fun displaySize(d: PDDocument, index: Int): Pair<Float, Float> {
    val page = d.getPage(index)
    val box = page.cropBox
    val rotated = (page.rotation % 180 + 180) % 180 == 90
    return if (rotated) box.height to box.width else box.width to box.height
}

private fun open(id: Int, path: String): JSONObject {
    closeDoc()
    val file = File(path)
    val d = PDDocument.load(file)
    doc = d
    renderer = PDFRenderer(d)
    val pages = JSONArray()
    for (i in 0 until d.numberOfPages) {
        val (w, h) = displaySize(d, i)
        pages.put(JSONArray().put(w.roundToInt()).put(h.roundToInt()))
    }
    return reply(id).put("name", file.name).put("pages", pages)
}

private fun render(id: Int, index: Int, width: Int, outPath: String): JSONObject {
    val d = doc ?: return reply(id, false).put("error", "no document open")
    val r = renderer!!
    if (index < 0 || index >= d.numberOfPages || width <= 0) {
        return reply(id, false).put("error", "bad page or width")
    }
    val (pw, _) = displaySize(d, index)
    val img = r.renderImage(index, width / pw, ImageType.RGB)
    val w = img.width
    val h = img.height
    val argb = img.getRGB(0, 0, w, h, null, 0, w)
    val bytes = ByteArray(w * h * 4)
    var j = 0
    for (px in argb) {
        bytes[j] = (px shr 16).toByte()
        bytes[j + 1] = (px shr 8).toByte()
        bytes[j + 2] = px.toByte()
        bytes[j + 3] = 0xFF.toByte()
        j += 4
    }
    BufferedOutputStream(FileOutputStream(outPath), 1 shl 20).use { it.write(bytes) }
    return reply(id).put("width", w).put("height", h)
}

/** Page count and a title guess, without touching the open document. */
private fun info(id: Int, path: String): JSONObject {
    PDDocument.load(File(path)).use { d ->
        val meta = TitleGuesser.metaTitle(d)
        val guessed = try { TitleGuesser.firstPageTitle(d) } catch (_: Exception) { "" }
        val title = meta.ifEmpty { guessed }
        return reply(id).put("pages", d.numberOfPages).put("title", title)
            .put("meta_title", meta).put("page_title", guessed)
    }
}

// ------------------------------------------------------------------- analysis

private fun startAnalysis(id: Int, file: File, cacheDir: File) {
    val gen = ++analysisGeneration
    analysisExecutor.execute {
        if (gen != analysisGeneration) {
            send(reply(id, false).put("error", "cancelled"))
            return@execute
        }
        try {
            cacheDir.mkdirs()
            val prefix = file.name + "_"
            val cache = File(cacheDir, "${file.name}_${file.length()}_v${PaperAnalyzer.VERSION}.json")
            if (cache.isFile) {
                send(reply(id).put("result", cache.absolutePath).put("cached", true))
                return@execute
            }
            var lastSent = -1f
            val json = PaperAnalyzer.analyze(file) { p ->
                if (gen == analysisGeneration && p - lastSent >= 0.02f) {
                    lastSent = p
                    send(JSONObject().put("event", "progress").put("id", id).put("value", (p * 1000).roundToInt() / 1000.0))
                }
            }
            if (gen != analysisGeneration) {
                send(reply(id, false).put("error", "cancelled"))
                return@execute
            }
            // Drop caches from older analyzer versions of this file.
            cacheDir.listFiles { f -> f.name.startsWith(prefix) && f.name != cache.name }?.forEach { it.delete() }
            val tmp = File(cacheDir, cache.name + ".tmp")
            tmp.writeText(json, Charsets.UTF_8)
            if (!tmp.renameTo(cache)) {
                cache.delete()
                tmp.renameTo(cache)
            }
            send(reply(id).put("result", cache.absolutePath).put("cached", false))
        } catch (t: Throwable) {
            send(reply(id, false).put("error", t.message ?: t.toString()))
        }
    }
}

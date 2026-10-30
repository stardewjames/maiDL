package app.maidl.core

import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.URL
import java.util.concurrent.CancellationException
import java.util.concurrent.TimeUnit

class HttpStatusException(val code: Int) : IOException("Server returned HTTP $code")

data class ContentRange(val start: Long, val end: Long, val total: Long?)

fun parseContentRange(header: String?): ContentRange? {
    if (header == null) return null
    val match = Regex("""bytes\s+(\d+)-(\d+)/(\d+|\*)""", RegexOption.IGNORE_CASE)
        .matchEntire(header.trim()) ?: return null
    val start = match.groupValues[1].toLongOrNull() ?: return null
    val end = match.groupValues[2].toLongOrNull() ?: return null
    val total = if (match.groupValues[3] == "*") null else {
        match.groupValues[3].toLongOrNull() ?: return null
    }
    if (end < start || (total != null && end >= total)) return null
    return ContentRange(start, end, total)
}

/** A partial file can only be appended when the server honours the range. */
fun shouldRestart(requestedFrom: Long, responseCode: Int, range: ContentRange?): Boolean {
    if (responseCode != 206) return requestedFrom > 0
    return range == null || range.start != requestedFrom
}

data class MediaInfo(
    val sourceUrl: String,
    val finalUrl: String,
    val mimeType: String,
    val kind: MediaKind,
    val fileName: String,
    val totalBytes: Long,
)

data class FetchResult(val info: MediaInfo, val bytesWritten: Long)

/**
 * Resolves page metadata without applying media byte ranges to HTML. Partial
 * bytes are reused only for the same resolved resource and a strong ETag.
 */
class DownloadEngine(private val client: OkHttpClient = defaultClient()) {
    private data class ResumeState(
        val sourceUrl: String,
        val targetUrl: String,
        val finalUrl: String,
        val etag: String,
        val totalBytes: Long,
    ) {
        fun write(file: File) {
            val json = JSONObject().apply {
                put("sourceUrl", sourceUrl)
                put("targetUrl", targetUrl)
                put("finalUrl", finalUrl)
                put("etag", etag)
                put("totalBytes", totalBytes)
            }
            FileOutputStream(file).use { output ->
                output.write(json.toString().toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
        }
    }

    @Volatile
    private var activeCall: Call? = null

    @Volatile
    private var canceled = false

    fun cancel() {
        canceled = true
        activeCall?.cancel()
    }

    private fun ensureActive(isCanceled: () -> Boolean) {
        if (canceled || isCanceled()) throw CancellationException()
    }

    private fun readResume(sourceUrl: String, partFile: File, from: Long): ResumeState? {
        if (from <= 0 || partFile.length() != from) return null
        return runCatching {
            val json = JSONObject(resumeFile(partFile).readText())
            ResumeState(
                sourceUrl = json.getString("sourceUrl"),
                targetUrl = json.getString("targetUrl"),
                finalUrl = json.getString("finalUrl"),
                etag = json.getString("etag"),
                totalBytes = json.getLong("totalBytes"),
            ).takeIf {
                it.sourceUrl == sourceUrl && isStrongEtag(it.etag) &&
                    (it.totalBytes < 0 || from <= it.totalBytes)
            }
        }.getOrNull()
    }

    private sealed interface Attempt {
        data class Restart(val target: String, val resetFile: Boolean) : Attempt
        data class Done(val result: FetchResult) : Attempt
    }

    fun fetch(
        sourceUrl: String,
        partFile: File,
        resumeFrom: Long,
        onMetadata: (MediaInfo) -> Unit,
        onProgress: (received: Long, total: Long) -> Unit,
        isCanceled: () -> Boolean,
        referer: String? = null,
        cookie: String? = null,
    ): FetchResult {
        var target = sourceUrl
        var resume = readResume(sourceUrl, partFile, resumeFrom)
        var redirectsFromHtml = 0

        while (true) {
            ensureActive(isCanceled)
            val from = if (resume?.targetUrl == target) resumeFrom else 0L
            when (
                val attempt = attempt(
                    sourceUrl, target, from, resume, partFile,
                    referer, cookie, onMetadata, onProgress, isCanceled,
                )
            ) {
                is Attempt.Done -> return attempt.result
                is Attempt.Restart -> {
                    if (attempt.target == target && from == 0L) {
                        throw LinkText.LinkException(
                            "unsupported_link",
                            "That page doesn't expose a direct video or image.",
                        )
                    }
                    if (attempt.target != target) {
                        redirectsFromHtml++
                        if (redirectsFromHtml > 1) {
                            throw LinkText.LinkException(
                                "unsupported_link",
                                "That page doesn't expose a direct video or image.",
                            )
                        }
                    }
                    target = attempt.target
                    if (attempt.resetFile) {
                        resume = null
                        discardPartial(partFile)
                    }
                }
            }
        }
    }

    private fun attempt(
        sourceUrl: String,
        target: String,
        from: Long,
        resume: ResumeState?,
        partFile: File,
        referer: String?,
        cookie: String?,
        onMetadata: (MediaInfo) -> Unit,
        onProgress: (Long, Long) -> Unit,
        isCanceled: () -> Boolean,
    ): Attempt {
        val request = Request.Builder()
            .url(target)
            .header("User-Agent", USER_AGENT)
            .header("Accept", "*/*")
            .header("Accept-Encoding", "identity")
            .apply {
                if (referer != null) header("Referer", referer)
                if (cookie != null) header("Cookie", cookie)
            }
            .apply {
                if (from > 0 && resume != null) {
                    header("Range", "bytes=$from-")
                    header("If-Range", resume.etag)
                }
            }
            .build()

        val call = client.newCall(request)
        activeCall = call
        if (canceled || isCanceled()) call.cancel()
        try {
            call.execute().use { response ->
            ensureActive(isCanceled)
            if (response.code == 416 && from > 0) {
                return Attempt.Restart(target, resetFile = true)
            }
            if (!response.isSuccessful) throw HttpStatusException(response.code)

            val contentType = response.header("Content-Type")
            val mime = contentType?.substringBefore(';')?.trim()?.lowercase()
            val finalUrl = response.request.url.toString()

            if (isHtml(mime)) {
                if (from > 0) return Attempt.Restart(target, resetFile = true)
                val html = readText(response, MAX_HTML_BYTES, isCanceled)
                val next = OgParser.findMediaUrl(html, finalUrl)
                    ?: throw LinkText.LinkException(
                        "unsupported_link",
                        "That page doesn't expose a direct video or image.",
                    )
                return Attempt.Restart(next, resetFile = false)
            }

            if (isStreamingPlaylist(mime, finalUrl)) {
                throw LinkText.LinkException(
                    "unsupported_link",
                    "Streaming playlists (HLS/DASH) aren't supported. Share a direct video link.",
                )
            }

            val rangeHeader = response.header("Content-Range")
            val range = parseContentRange(rangeHeader)
            if (shouldRestart(from, response.code, range)) {
                return Attempt.Restart(target, resetFile = true)
            }
            if (response.code == 206 && range?.total == null) {
                throw IOException("The server sent a partial response without its full size.")
            }
            val responseLength = response.body?.contentLength() ?: -1
            if (response.code == 206 && responseLength >= 0 &&
                responseLength != range!!.end - range.start + 1
            ) {
                throw IOException("The server sent inconsistent range lengths.")
            }
            val etag = response.header("ETag")?.takeIf(::isStrongEtag)
            if (from > 0 && (
                    resume == null || finalUrl != resume.finalUrl || etag != resume.etag ||
                        (resume.totalBytes >= 0 && range?.total != resume.totalBytes)
                    )
            ) {
                return Attempt.Restart(target, resetFile = true)
            }
            val encoding = response.header("Content-Encoding")
            if (!encoding.isNullOrBlank() && !encoding.equals("identity", ignoreCase = true)) {
                throw IOException("The server sent an unsupported content encoding.")
            }

            val totalBytes = when (response.code) {
                206 -> range?.total ?: -1
                else -> response.body?.contentLength()?.takeIf { it >= 0 } ?: -1
            }

            val disposition = response.header("Content-Disposition")
            val mimeKind = MediaKind.fromContentType(mime)
            val urlKind = MediaTypes.kindFromUrl(finalUrl)
            val kind = if (mimeKind.isMedia) mimeKind else urlKind
            if (!kind.isMedia) {
                throw LinkText.LinkException(
                    "unsupported_link",
                    "This link doesn't point to a video or image.",
                )
            }
            val resolvedMime = if (mimeKind.isMedia && mime != null) {
                mime
            } else {
                val guess = MediaTypes.fileNameFor(
                    finalUrl,
                    null,
                    disposition,
                    System.currentTimeMillis(),
                )
                MediaTypes.contentTypeFor(guess)
            }
            val fileName = MediaTypes.fileNameFor(
                finalUrl,
                resolvedMime,
                disposition,
                System.currentTimeMillis(),
            )
            val info = MediaInfo(
                sourceUrl = sourceUrl,
                finalUrl = finalUrl,
                mimeType = resolvedMime,
                kind = kind,
                fileName = fileName,
                totalBytes = totalBytes,
            )
            ensureActive(isCanceled)
            onMetadata(info)

            val body = response.body ?: throw IOException("The server sent an empty response.")
            partFile.parentFile?.mkdirs()
            val expectedStart = if (from > 0 && response.code == 206) from else 0L
            var received = expectedStart
            FileOutputStream(partFile, expectedStart > 0).use { output ->
                if (output.channel.size() != expectedStart) {
                    throw IOException("The partial download changed before it could resume.")
                }
                // Truncate first: a crash while writing metadata must never label
                // bytes from an older representation with the new validator.
                if (expectedStart == 0L) output.fd.sync()
                if (etag != null) {
                    ResumeState(sourceUrl, target, finalUrl, etag, totalBytes)
                        .write(resumeFile(partFile))
                } else {
                    resumeFile(partFile).delete()
                }
                body.byteStream().use { input ->
                    val buffer = ByteArray(COPY_BUFFER)
                    while (true) {
                        ensureActive(isCanceled)
                        val read = input.read(buffer)
                        ensureActive(isCanceled)
                        if (read == -1) break
                        output.write(buffer, 0, read)
                        received += read
                        onProgress(received, totalBytes)
                    }
                }
                output.fd.sync()
            }
            ensureActive(isCanceled)
            val responseBytes = received - expectedStart
            if (received == 0L || (totalBytes >= 0 && received != totalBytes) ||
                (body.contentLength() >= 0 && responseBytes != body.contentLength()) ||
                (response.code == 206 && responseBytes != range!!.end - range.start + 1)
            ) {
                throw IOException("Download incomplete ($received of $totalBytes bytes).")
            }
            return Attempt.Done(FetchResult(info, received))
            }
        } catch (error: IOException) {
            ensureActive(isCanceled)
            throw error
        } finally {
            activeCall = null
        }
    }

    private fun readText(
        response: okhttp3.Response,
        maxBytes: Long,
        isCanceled: () -> Boolean,
    ): String {
        val body = response.body ?: return ""
        val out = ByteArrayOutputStream()
        body.byteStream().use { input ->
            val buffer = ByteArray(16 * 1024)
            var remaining = maxBytes
            while (remaining > 0) {
                ensureActive(isCanceled)
                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (read == -1) break
                out.write(buffer, 0, read)
                remaining -= read
            }
        }
        return out.toString("UTF-8")
    }

    companion object {
        private const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/124.0 Mobile Safari/537.36 maiDL/1.0"
        private const val MAX_HTML_BYTES = 768L * 1024L
        private const val COPY_BUFFER = 64 * 1024

        private fun isStrongEtag(value: String): Boolean =
            value.length >= 2 && value.startsWith('"') && value.endsWith('"')

        fun resumeFile(partFile: File): File = File(partFile.path + ".resume")

        fun discardPartial(partFile: File) {
            partFile.delete()
            resumeFile(partFile).delete()
        }

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.MILLISECONDS)
            .retryOnConnectionFailure(true)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()

        fun isHtml(mime: String?): Boolean =
            mime == "text/html" || mime == "application/xhtml+xml"

        fun isStreamingPlaylist(mime: String?, url: String): Boolean {
            if (mime != null && (
                    mime.contains("mpegurl") ||
                        mime == "application/vnd.apple.mpegurl" ||
                        mime == "application/dash+xml"
                    )
            ) {
                return true
            }
            val extension = MediaTypes.extensionOf(url) ?: return false
            return extension == "m3u8" || extension == "mpd"
        }

        fun hostOf(url: String): String =
            runCatching { URL(url).host }.getOrNull() ?: url
    }
}

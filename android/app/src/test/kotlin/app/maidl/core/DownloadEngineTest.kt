package app.maidl.core

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.util.concurrent.CancellationException
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Exercises the real transfer pipeline against a local HTTP server: no Android
 * runtime required, which is the closest we can get to a device run here.
 */
class DownloadEngineTest {
    private lateinit var server: TestServer
    private lateinit var tempDir: File
    private val engine = DownloadEngine()

    @Before
    fun setUp() {
        server = TestServer()
        tempDir = Files.createTempDirectory("maidl-download").toFile()
    }

    @After
    fun tearDown() {
        server.close()
        tempDir.deleteRecursively()
    }

    private fun url(path: String): String = "http://127.0.0.1:${server.port}$path"

    private fun serve(
        path: String,
        mime: String,
        body: ByteArray,
        headers: Map<String, String> = emptyMap(),
        status: Int = 200,
    ) {
        server.route(path, TestResponse(status, mime, body, headers))
    }

    private fun payload(size: Int): ByteArray = ByteArray(size) { (it % 251).toByte() }

    private fun recordResume(
        part: File,
        source: String,
        totalBytes: Int,
        target: String = source,
        etag: String = "\"version-1\"",
    ) {
        DownloadEngine.resumeFile(part).writeText(
            JSONObject().apply {
                put("sourceUrl", source)
                put("targetUrl", target)
                put("finalUrl", target)
                put("etag", etag)
                put("totalBytes", totalBytes)
            }.toString(),
        )
    }

    @Test
    fun downloadsDirectVideoAndResolvesNameFromHeaders() {
        val body = payload(150_000)
        serve(
            "/clip.mp4",
            "video/mp4",
            body,
            headers = mapOf("Content-Disposition" to "attachment; filename=\"holiday.mp4\""),
        )
        server.start()

        val part = File(tempDir, "clip.part")
        var seen: MediaInfo? = null
        var progress = 0L
        val result = engine.fetch(
            sourceUrl = url("/clip.mp4?token=1"),
            partFile = part,
            resumeFrom = 0,
            onMetadata = { seen = it },
            onProgress = { received, _ -> progress = received },
            isCanceled = { false },
        )

        assertEquals("holiday.mp4", result.info.fileName)
        assertEquals(MediaKind.VIDEO, result.info.kind)
        assertEquals("video/mp4", result.info.mimeType)
        assertEquals(body.size.toLong(), result.info.totalBytes)
        assertEquals(body.size.toLong(), result.bytesWritten)
        assertEquals(body.size.toLong(), progress)
        assertArrayEquals(body, part.readBytes())
        assertEquals("holiday.mp4", seen?.fileName)
    }

    @Test
    fun followsPageMetadataToTheMediaFile() {
        val body = payload(64_000)
        val page = """
            <html><head>
              <meta property="og:image" content="/thumb.jpg">
              <meta property="og:video" content="/media/clip.mp4">
            </head></html>
        """.trimIndent().toByteArray()
        serve("/page", "text/html; charset=utf-8", page)
        serve("/media/clip.mp4", "video/mp4", body)
        server.start()

        val result = engine.fetch(
            sourceUrl = url("/page"),
            partFile = File(tempDir, "page.part"),
            resumeFrom = 0,
            onMetadata = {},
            onProgress = { _, _ -> },
            isCanceled = { false },
        )

        assertEquals(url("/media/clip.mp4"), result.info.finalUrl)
        assertEquals("clip.mp4", result.info.fileName)
        assertEquals(MediaKind.VIDEO, result.info.kind)
        assertEquals(2, server.requests.size)
        assertArrayEquals(body, File(tempDir, "page.part").readBytes())
    }

    @Test
    fun resumesFromAPartialFileWhenTheServerHonoursTheRange() {
        val body = payload(200_000)
        val resumeAt = 120_000
        val part = File(tempDir, "resume.part")
        part.writeBytes(body.copyOfRange(0, resumeAt))
        recordResume(part, url("/resume.mp4"), body.size)

        serve(
            "/resume.mp4",
            "video/mp4",
            body.copyOfRange(resumeAt, body.size),
            headers = mapOf(
                "Content-Range" to "bytes $resumeAt-${body.size - 1}/${body.size}",
                "ETag" to "\"version-1\"",
            ),
            status = 206,
        )
        server.start()

        val result = engine.fetch(
            sourceUrl = url("/resume.mp4"),
            partFile = part,
            resumeFrom = part.length(),
            onMetadata = {},
            onProgress = { _, _ -> },
            isCanceled = { false },
        )

        assertEquals("bytes=$resumeAt-", server.requests.single().headers["range"])
        assertEquals("\"version-1\"", server.requests.single().headers["if-range"])
        assertEquals("identity", server.requests.single().headers["accept-encoding"])
        assertEquals(body.size.toLong(), result.bytesWritten)
        assertEquals(body.size.toLong(), result.info.totalBytes)
        assertEquals(body.size.toLong(), part.length())
        assertArrayEquals(body, part.readBytes())
    }

    @Test
    fun restartsCleanlyWhenTheServerIgnoresTheRange() {
        val body = payload(90_000)
        val part = File(tempDir, "restart.part")
        part.writeBytes(body.copyOfRange(0, 40_000))
        recordResume(part, url("/ignored.mp4"), body.size)
        serve("/ignored.mp4", "video/mp4", body)
        server.start()

        val result = engine.fetch(
            sourceUrl = url("/ignored.mp4"),
            partFile = part,
            resumeFrom = part.length(),
            onMetadata = {},
            onProgress = { _, _ -> },
            isCanceled = { false },
        )

        assertEquals(body.size.toLong(), result.bytesWritten)
        assertEquals(body.size.toLong(), part.length())
        assertArrayEquals(body, part.readBytes())
    }

    @Test
    fun resumesPageMediaWithoutSendingItsRangeToTheHtmlPage() {
        val body = payload(160_000)
        val resumeAt = 80_000
        val part = File(tempDir, "page-resume.part")
        part.writeBytes(body.copyOfRange(0, resumeAt))
        recordResume(part, url("/page"), body.size, target = url("/media.mp4"))
        serve(
            "/page", "text/html",
            """<meta property="og:video" content="/media.mp4">""".toByteArray(),
        )
        serve(
            "/media.mp4", "video/mp4", body.copyOfRange(resumeAt, body.size),
            headers = mapOf(
                "Content-Range" to "bytes $resumeAt-${body.size - 1}/${body.size}",
                "ETag" to "\"version-1\"",
            ),
            status = 206,
        )
        server.start()

        val result = engine.fetch(
            url("/page"), part, part.length(), {}, { _, _ -> }, { false },
        )

        assertEquals(null, server.requests[0].headers["range"])
        assertEquals("bytes=$resumeAt-", server.requests[1].headers["range"])
        assertEquals(body.size.toLong(), result.bytesWritten)
        assertArrayEquals(body, part.readBytes())
    }

    @Test
    fun replacesPartialBytesWhenPageMetadataSelectsDifferentMedia() {
        val body = payload(90_000)
        val part = File(tempDir, "changed-page.part")
        part.writeBytes(ByteArray(40_000) { 7 })
        recordResume(part, url("/page"), body.size, target = url("/old.mp4"))
        serve(
            "/page", "text/html",
            """<meta property="og:video" content="/new.mp4">""".toByteArray(),
        )
        serve("/new.mp4", "video/mp4", body, headers = mapOf("ETag" to "\"version-1\""))
        server.start()

        engine.fetch(url("/page"), part, part.length(), {}, { _, _ -> }, { false })

        assertTrue(server.requests.none { it.headers.containsKey("range") })
        assertArrayEquals(body, part.readBytes())
    }

    @Test
    fun rejectsChangedResourceEvenWhenTheServerIncorrectlyHonoursTheRange() {
        val body = payload(140_000)
        val resumeAt = 60_000
        val part = File(tempDir, "changed-resource.part")
        part.writeBytes(ByteArray(resumeAt) { 7 })
        recordResume(part, url("/changed.mp4"), body.size)
        server.route("/changed.mp4") { request ->
            if (request.headers.containsKey("range")) {
                TestResponse(
                    206, "video/mp4", body.copyOfRange(resumeAt, body.size),
                    mapOf(
                        "Content-Range" to "bytes $resumeAt-${body.size - 1}/${body.size}",
                        "ETag" to "\"version-2\"",
                    ),
                )
            } else {
                TestResponse(200, "video/mp4", body, mapOf("ETag" to "\"version-2\""))
            }
        }
        server.start()

        engine.fetch(url("/changed.mp4"), part, part.length(), {}, { _, _ -> }, { false })

        assertEquals(2, server.requests.size)
        assertEquals("\"version-1\"", server.requests[0].headers["if-range"])
        assertEquals(null, server.requests[1].headers["range"])
        assertArrayEquals(body, part.readBytes())
    }

    @Test
    fun startsOverWhenAPartialFileHasNoStrongValidator() {
        val body = payload(90_000)
        val part = File(tempDir, "unverified.part")
        part.writeBytes(ByteArray(40_000) { 7 })
        recordResume(part, url("/unverified.mp4"), body.size, etag = "W/\"weak\"")
        serve("/unverified.mp4", "video/mp4", body)
        server.start()

        engine.fetch(url("/unverified.mp4"), part, part.length(), {}, { _, _ -> }, { false })

        assertEquals(null, server.requests.single().headers["range"])
        assertArrayEquals(body, part.readBytes())
    }

    @Test
    fun cancellationCannotReturnACompletedTransfer() {
        val body = payload(200_000)
        val part = File(tempDir, "canceled.part")
        serve("/cancel.mp4", "video/mp4", body)
        server.start()

        assertThrows(CancellationException::class.java) {
            engine.fetch(
                url("/cancel.mp4"), part, 0, {},
                { _, _ -> engine.cancel() },
                { false },
            )
        }
        assertTrue(part.length() in 1 until body.size.toLong())
    }

    @Test
    fun infersTheTypeFromTheUrlWhenTheServerSaysOctetStream() {
        val body = payload(32_000)
        serve("/plain.mp4", "application/octet-stream", body)
        server.start()

        val result = engine.fetch(
            sourceUrl = url("/plain.mp4"),
            partFile = File(tempDir, "plain.part"),
            resumeFrom = 0,
            onMetadata = {},
            onProgress = { _, _ -> },
            isCanceled = { false },
        )

        assertEquals(MediaKind.VIDEO, result.info.kind)
        assertEquals("video/mp4", result.info.mimeType)
        assertEquals("plain.mp4", result.info.fileName)
    }

    @Test
    fun surfacesHttpFailuresWithTheirStatusCode() {
        serve("/missing.mp4", "text/plain", "gone".toByteArray(), status = 404)
        server.start()

        val error = assertThrows(HttpStatusException::class.java) {
            engine.fetch(
                sourceUrl = url("/missing.mp4"),
                partFile = File(tempDir, "missing.part"),
                resumeFrom = 0,
                onMetadata = {},
                onProgress = { _, _ -> },
                isCanceled = { false },
            )
        }
        assertEquals(404, error.code)
    }

    @Test
    fun rejectsStreamingPlaylistsAndUnknownFiles() {
        serve("/live.m3u8", "application/vnd.apple.mpegurl", "#EXTM3U".toByteArray())
        serve("/document.pdf", "application/pdf", payload(128))
        server.start()

        val playlist = assertThrows(LinkText.LinkException::class.java) {
            engine.fetch(
                sourceUrl = url("/live.m3u8"),
                partFile = File(tempDir, "playlist.part"),
                resumeFrom = 0,
                onMetadata = {},
                onProgress = { _, _ -> },
                isCanceled = { false },
            )
        }
        assertEquals("unsupported_link", playlist.code)

        val document = assertThrows(LinkText.LinkException::class.java) {
            engine.fetch(
                sourceUrl = url("/document.pdf"),
                partFile = File(tempDir, "document.part"),
                resumeFrom = 0,
                onMetadata = {},
                onProgress = { _, _ -> },
                isCanceled = { false },
            )
        }
        assertEquals("unsupported_link", document.code)
    }

    @Test
    fun rejectsPagesWithoutUsableMetadataAndSelfReferentialMetadata() {
        serve("/empty", "text/html", "<html><body>nothing</body></html>".toByteArray())
        serve(
            "/loop",
            "text/html",
            """<meta property="og:video" content="/loop">""".toByteArray(),
        )
        server.start()

        val empty = assertThrows(LinkText.LinkException::class.java) {
            engine.fetch(
                sourceUrl = url("/empty"),
                partFile = File(tempDir, "empty.part"),
                resumeFrom = 0,
                onMetadata = {},
                onProgress = { _, _ -> },
                isCanceled = { false },
            )
        }
        assertTrue(empty.message!!.contains("doesn't expose"))

        val loop = assertThrows(LinkText.LinkException::class.java) {
            engine.fetch(
                sourceUrl = url("/loop"),
                partFile = File(tempDir, "loop.part"),
                resumeFrom = 0,
                onMetadata = {},
                onProgress = { _, _ -> },
                isCanceled = { false },
            )
        }
        assertTrue(loop.message!!.contains("doesn't expose"))
    }
}

private data class TestRequest(
    val path: String,
    val headers: Map<String, String>,
)

private data class TestResponse(
    val status: Int,
    val mime: String?,
    val body: ByteArray,
    val extraHeaders: Map<String, String> = emptyMap(),
)

/**
 * Minimal HTTP/1.1 server: one connection at a time, always closes, which is
 * enough for sequential download requests.
 */
private class TestServer : Closeable {
    private val socket = ServerSocket(
        0,
        50,
        InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)),
    )
    private val routes = HashMap<String, (TestRequest) -> TestResponse>()
    private val thread = Thread({ acceptLoop() }, "maidl-test-http").apply {
        isDaemon = true
    }

    @Volatile
    private var running = true

    val requests = CopyOnWriteArrayList<TestRequest>()

    val port: Int get() = socket.localPort

    fun route(path: String, response: TestResponse) {
        routes[path] = { response }
    }

    fun route(path: String, response: (TestRequest) -> TestResponse) {
        routes[path] = response
    }

    fun start() {
        thread.start()
    }

    override fun close() {
        running = false
        runCatching { socket.close() }
    }

    private fun acceptLoop() {
        while (running) {
            val client = try {
                socket.accept()
            } catch (_: IOException) {
                break
            }
            try {
                client.use { connection ->
                    connection.soTimeout = 5_000
                    val input = BufferedInputStream(connection.getInputStream())
                    val requestLine = readLine(input) ?: return@use
                    val parts = requestLine.split(' ')
                    val path = parts.getOrNull(1)?.substringBefore('?') ?: "/"
                    val headers = mutableMapOf<String, String>()
                    while (true) {
                        val line = readLine(input) ?: break
                        if (line.isEmpty()) break
                        val separator = line.indexOf(':')
                        if (separator > 0) {
                            headers[line.substring(0, separator).trim().lowercase()] =
                                line.substring(separator + 1).trim()
                        }
                    }
                    val request = TestRequest(path, headers)
                    requests.add(request)

                    val response = routes[path]?.invoke(request)
                        ?: TestResponse(404, "text/plain", "not found".toByteArray())
                    writeResponse(BufferedOutputStream(connection.getOutputStream()), response)
                }
            } catch (_: IOException) {
                // Client went away; keep serving.
            }
        }
    }

    private fun writeResponse(output: BufferedOutputStream, response: TestResponse) {
        val head = buildString {
            append("HTTP/1.1 ${response.status} ")
            append(if (response.status in 200..299) "OK" else "Error")
            append("\r\n")
            if (response.mime != null) append("Content-Type: ${response.mime}\r\n")
            response.extraHeaders.forEach { (name, value) ->
                append("$name: $value\r\n")
            }
            append("Content-Length: ${response.body.size}\r\n")
            append("Connection: close\r\n\r\n")
        }
        output.write(head.toByteArray(Charsets.ISO_8859_1))
        output.write(response.body)
        output.flush()
    }

    private fun readLine(input: InputStream): String? {
        val buffer = ByteArrayOutputStream()
        while (true) {
            val byte = input.read()
            if (byte == -1) {
                return if (buffer.size() == 0) {
                    null
                } else {
                    String(buffer.toByteArray(), Charsets.ISO_8859_1)
                }
            }
            if (byte == '\n'.code) break
            if (byte != '\r'.code) buffer.write(byte)
        }
        return String(buffer.toByteArray(), Charsets.ISO_8859_1)
    }
}

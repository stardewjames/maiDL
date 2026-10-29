package app.maidl.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadEngineLogicTest {

    @Test
    fun parsesContentRange() {
        val range = parseContentRange("bytes 100-499/500")
        assertEquals(100L, range?.start)
        assertEquals(499L, range?.end)
        assertEquals(500L, range?.total)

        val unknownTotal = parseContentRange("bytes 0-0/*")
        assertNull(unknownTotal?.total)

        assertNull(parseContentRange(null))
        assertNull(parseContentRange("garbage"))
        assertNull(parseContentRange("bytes 5-4/10"))
        assertNull(parseContentRange("bytes 0-10/10"))
        assertNull(parseContentRange("prefix bytes 0-1/2 suffix"))
        assertNull(parseContentRange("bytes 0-1/999999999999999999999999"))
    }

    @Test
    fun restartsUnlessTheServerHonoursTheExactRange() {
        assertFalse(shouldRestart(0, 200, null))
        assertFalse(shouldRestart(0, 206, ContentRange(0, 99, 1000)))
        assertFalse(shouldRestart(100, 206, ContentRange(100, 999, 1000)))
        assertTrue(shouldRestart(100, 200, null))
        assertTrue(shouldRestart(100, 206, ContentRange(0, 999, 1000)))
        assertTrue(shouldRestart(100, 206, null))
        assertTrue(shouldRestart(0, 206, ContentRange(10, 99, 100)))
        assertTrue(shouldRestart(0, 206, null))
    }

    @Test
    fun classifiesHtmlResponses() {
        assertTrue(DownloadEngine.isHtml("text/html"))
        assertTrue(DownloadEngine.isHtml("application/xhtml+xml"))
        assertFalse(DownloadEngine.isHtml("video/mp4"))
        assertFalse(DownloadEngine.isHtml(null))
    }

    @Test
    fun rejectsStreamingPlaylists() {
        assertTrue(DownloadEngine.isStreamingPlaylist("application/vnd.apple.mpegurl", "x"))
        assertTrue(DownloadEngine.isStreamingPlaylist(null, "https://x.dev/live/index.m3u8"))
        assertTrue(DownloadEngine.isStreamingPlaylist("application/dash+xml", "x"))
        assertFalse(DownloadEngine.isStreamingPlaylist("video/mp4", "https://x.dev/a.mp4"))
    }

    @Test
    fun formatsByteCounts() {
        assertEquals("Unknown size", formatBytes(-1))
        assertEquals("1023 B", formatBytes(1023))
        assertEquals("1.0 KB", formatBytes(1024))
        assertEquals("1.5 GB", formatBytes((1024L * 1024 * 1024 * 3) / 2))
    }
}

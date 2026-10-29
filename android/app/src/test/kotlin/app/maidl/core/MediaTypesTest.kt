package app.maidl.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaTypesTest {

    @Test
    fun derivesFileNameFromTheUrl() {
        assertEquals(
            "clip.mp4",
            MediaTypes.fileNameFor("https://x.dev/v/clip.mp4?token=1", "video/mp4", null, 1L),
        )
    }

    @Test
    fun prefersContentDispositionNames() {
        assertEquals(
            "My Video.mov",
            MediaTypes.fileNameFor(
                "https://x.dev/download",
                "video/quicktime",
                "attachment; filename=\"My Video.MOV\"",
                1L,
            ),
        )
    }

    @Test
    fun decodesRfc5987FileNames() {
        val name = MediaTypes.fileNameFor(
            "https://x.dev/download",
            "video/mp4",
            "attachment; filename*=UTF-8''caf%C3%A9%20clip.mp4",
            1L,
        )
        assertTrue(name.startsWith("caf"))
        assertTrue(name.endsWith(".mp4"))
        assertFalse(name.contains("/"))
    }

    @Test
    fun extensionFollowsTheResponseTypeNotTheUrl() {
        assertEquals(
            "frame.png",
            MediaTypes.fileNameFor("https://x.dev/frame.jpg", "image/png", null, 1L),
        )
    }

    @Test
    fun sanitizesHostileFileNames() {
        val name = MediaTypes.fileNameFor(
            "https://x.dev/download",
            "image/png",
            "attachment; filename=\"../../evil:name.png\"",
            1L,
        )
        assertFalse(name.contains("/"))
        assertFalse(name.contains(":"))
        assertTrue(name.endsWith(".png"))
    }

    @Test
    fun fallsBackToATimestampedName() {
        val name = MediaTypes.fileNameFor("https://x.dev/", null, null, 1234L)
        assertEquals("maiDL_1234", name)
    }

    @Test
    fun mapsExtensionsAndMimeTypes() {
        assertEquals(MediaKind.VIDEO, MediaTypes.kindFromUrl("https://x.dev/a.MP4?x=1"))
        assertEquals(MediaKind.IMAGE, MediaTypes.kindFromUrl("https://x.dev/a.jpeg"))
        assertEquals(MediaKind.UNKNOWN, MediaTypes.kindFromUrl("https://x.dev/a."))
        assertEquals("jpg", MediaTypes.extensionForMime("image/jpeg; charset=binary"))
        assertEquals("video/mp4", MediaTypes.contentTypeFor("clip.mp4"))
        assertEquals("application/octet-stream", MediaTypes.contentTypeFor("clip.weird"))
        assertTrue(MediaTypes.isMediaFileName("x.heic"))
        assertFalse(MediaTypes.isMediaFileName("x.html"))
    }
}

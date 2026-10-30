package app.maidl.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class LinkResolverTest {
    @Test
    fun supportedHostsCoverSocialDomainsButNotLookalikes() {
        assertTrue(LinkResolver.isSupported("https://www.tiktok.com/@a/video/1"))
        assertTrue(LinkResolver.isSupported("https://vm.tiktok.com/ZM123/"))
        assertTrue(LinkResolver.isSupported("https://www.instagram.com/reel/abc/"))
        assertTrue(LinkResolver.isSupported("https://youtu.be/abc"))
        assertTrue(LinkResolver.isSupported("https://m.youtube.com/shorts/abc"))
        assertTrue(LinkResolver.isSupported("https://x.com/user/status/1"))
        assertTrue(LinkResolver.isSupported("https://twitter.com/user/status/1"))
        assertFalse(LinkResolver.isSupported("https://notyoutube.com/watch"))
        assertFalse(LinkResolver.isSupported("https://example.com/video.mp4"))
        assertFalse(LinkResolver.isSupported("not a link"))
    }

    @Test
    fun ytdlpResponseReturnsMediaUrlAndFilename() {
        val result = LinkResolver.parse(
            JSONObject(
                """{"url":"http://192.168.1.20:8080/media/abc","fileName":"clip.mp4"}""",
            ),
        )
        assertEquals("http://192.168.1.20:8080/media/abc", result.mediaUrl)
        assertEquals("clip.mp4", result.fileName)
    }

    @Test
    fun ytdlpResponseRejectsNonHttpMedia() {
        try {
            LinkResolver.parse(JSONObject("""{"url":"file:///etc/passwd"}"""))
            fail("expected a resolver error")
        } catch (_: LinkResolver.ResolverException) {
            // expected
        }
    }

    @Test
    fun missingMediaUrlFails() {
        try {
            LinkResolver.parse(JSONObject("{}"))
            fail("expected a resolver error")
        } catch (error: LinkResolver.ResolverException) {
            assertTrue(error.message.orEmpty().isNotBlank())
        }
    }

    @Test
    fun settingsRejectInvalidEndpoints() {
        assertNull(ResolverSettings().endpoint)
        assertNull(
            ResolverSettings(mode = ResolverMode.YTDLP, ytdlpUrl = "not-a-url").endpoint,
        )
        assertFalse(
            ResolverSettings(mode = ResolverMode.YTDLP, ytdlpUrl = "").isEnabled,
        )
        assertTrue(
            ResolverSettings(
                mode = ResolverMode.YTDLP,
                ytdlpUrl = "http://192.168.1.20:8080",
            ).isEnabled,
        )
    }
}

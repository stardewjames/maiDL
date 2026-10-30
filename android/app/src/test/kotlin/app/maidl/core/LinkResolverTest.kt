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
    fun cobaltTunnelReturnsMediaUrlAndFilename() {
        val result = LinkResolver.parse(
            JSONObject(
                """{"status":"tunnel","url":"https://cdn.example/v.mp4","filename":"clip.mp4"}""",
            ),
            ResolverMode.COBALT,
        )
        assertEquals("https://cdn.example/v.mp4", result.mediaUrl)
        assertEquals("clip.mp4", result.fileName)
    }

    @Test
    fun cobaltPickerPrefersVideoItems() {
        val result = LinkResolver.parse(
            JSONObject(
                """{"status":"picker","picker":[
                    {"type":"photo","url":"https://cdn.example/a.jpg"},
                    {"type":"video","url":"https://cdn.example/b.mp4"}
                ]}""",
            ),
            ResolverMode.COBALT,
        )
        assertEquals("https://cdn.example/b.mp4", result.mediaUrl)
        assertNull(result.fileName)
    }

    @Test
    fun cobaltErrorSurfacesCode() {
        try {
            LinkResolver.parse(
                JSONObject(
                    """{"status":"error","error":{"code":"error.link.unsupported"}}""",
                ),
                ResolverMode.COBALT,
            )
            fail("expected a resolver error")
        } catch (error: LinkResolver.ResolverException) {
            assertTrue(error.message.orEmpty().contains("error.link.unsupported"))
        }
    }

    @Test
    fun ytdlpResponseRequiresHttpMedia() {
        val result = LinkResolver.parse(
            JSONObject(
                """{"url":"http://192.168.1.20:8080/media/abc","fileName":"clip.mp4"}""",
            ),
            ResolverMode.YTDLP,
        )
        assertEquals("http://192.168.1.20:8080/media/abc", result.mediaUrl)
        assertEquals("clip.mp4", result.fileName)

        try {
            LinkResolver.parse(
                JSONObject("""{"url":"file:///etc/passwd"}"""),
                ResolverMode.YTDLP,
            )
            fail("expected a resolver error")
        } catch (_: LinkResolver.ResolverException) {
            // expected
        }
    }

    @Test
    fun settingsRejectInvalidEndpoints() {
        assertNull(ResolverSettings().endpoint)
        assertNull(
            ResolverSettings(mode = ResolverMode.YTDLP, ytdlpUrl = "not-a-url").endpoint,
        )
        assertFalse(
            ResolverSettings(mode = ResolverMode.COBALT, cobaltUrl = "").isEnabled,
        )
        assertTrue(
            ResolverSettings(
                mode = ResolverMode.COBALT,
                cobaltUrl = "https://api.cobalt.tools",
            ).isEnabled,
        )
    }
}

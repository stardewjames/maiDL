package app.maidl.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SocialExtractorTest {
    @Test
    fun supportedHostsCoverSocialDomainsButNotLookalikes() {
        assertTrue(SocialExtractor.isSupported("https://www.tiktok.com/@a/video/1"))
        assertTrue(SocialExtractor.isSupported("https://vm.tiktok.com/ZM123/"))
        assertTrue(SocialExtractor.isSupported("https://www.instagram.com/reel/abc/"))
        assertTrue(SocialExtractor.isSupported("https://x.com/user/status/1"))
        assertTrue(SocialExtractor.isSupported("https://twitter.com/user/status/1"))
        assertFalse(SocialExtractor.isSupported("https://notyoutube.com/watch"))
        assertFalse(SocialExtractor.isSupported("https://example.com/video.mp4"))
        assertFalse(SocialExtractor.isSupported("not a link"))
    }

    @Test
    fun youtubeIsDetected() {
        assertTrue(SocialExtractor.isYouTube("https://youtu.be/abc"))
        assertTrue(SocialExtractor.isYouTube("https://www.youtube.com/watch?v=1"))
        assertFalse(SocialExtractor.isYouTube("https://www.tiktok.com/@a/video/1"))
    }

    @Test
    fun tiktokHydrationJsonYieldsDownloadAddress() {
        val html = """
            <html><body>
            <script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">
            {"__DEFAULT_SCOPE__":{"webapp.video-detail":{"itemInfo":{"itemStruct":
            {"video":{"playAddr":"https://cdn.example/play.mp4",
            "downloadAddr":"https://cdn.example/download.mp4"}}}}}}
            </script></body></html>
        """.trimIndent()
        val media = SocialExtractor.parseHtml(
            html,
            SocialPlatform.TIKTOK,
            "https://www.tiktok.com/@a/video/1",
        )
        assertEquals("https://cdn.example/download.mp4", media)
    }

    @Test
    fun instagramEscapedVideoUrlIsUnescaped() {
        val html = """<html>"video_url":"https:\/\/cdn.example\/video.mp4?a=1\u0026b=2"</html>"""
        val media = SocialExtractor.parseHtml(
            html,
            SocialPlatform.INSTAGRAM,
            "https://www.instagram.com/reel/abc/",
        )
        assertEquals("https://cdn.example/video.mp4?a=1&b=2", media)
    }

    @Test
    fun xVariantsYieldTwimgMp4() {
        val html = """
            <html><script>{"variants":[
            {"url":"https:\/\/video.twimg.com\/ext_tw_video\/1.mp4?tag=1"}
            ]}</script></html>
        """.trimIndent()
        val media = SocialExtractor.parseHtml(
            html,
            SocialPlatform.X,
            "https://x.com/user/status/1",
        )
        assertEquals("https://video.twimg.com/ext_tw_video/1.mp4?tag=1", media)
    }

    @Test
    fun missingMediaFails() {
        try {
            SocialExtractor.parseHtml(
                "<html><body>login required</body></html>",
                SocialPlatform.INSTAGRAM,
                "https://www.instagram.com/reel/abc/",
            )
            fail("expected a social extraction error")
        } catch (error: SocialExtractorException) {
            assertNotNull(error.message)
        }
    }

    @Test
    fun photoPostFallsBackToImage() {
        val html = """<html><meta property="og:image" content="https://cdn.example/a.jpg"></html>"""
        val media = SocialExtractor.parseHtml(
            html,
            SocialPlatform.X,
            "https://x.com/user/status/2",
        )
        assertEquals("https://cdn.example/a.jpg", media)
        assertNull(SocialExtractor.platformFor("https://example.com/a"))
    }
}

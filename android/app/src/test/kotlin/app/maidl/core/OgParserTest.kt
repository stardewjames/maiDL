package app.maidl.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OgParserTest {

    private val base = "https://site.example/watch/1"

    @Test
    fun prefersVideoOverImage() {
        val html = """
            <html><head>
              <meta property="og:image" content="https://cdn.example/thumb.jpg">
              <meta property="og:video:secure_url" content="https://cdn.example/movie.mp4">
            </head></html>
        """.trimIndent()
        assertEquals("https://cdn.example/movie.mp4", OgParser.findMediaUrl(html, base))
    }

    @Test
    fun handlesAttributeOrderSingleQuotesAndEntities() {
        val html = """
            <meta content='https://cdn.example/a.mp4?x=1&amp;y=2' name='og:video'>
        """.trimIndent()
        assertEquals(
            "https://cdn.example/a.mp4?x=1&y=2",
            OgParser.findMediaUrl(html, base),
        )
    }

    @Test
    fun resolvesRelativeAndProtocolRelativeUrls() {
        val relative = """<meta property="og:video" content="/media/clip.mp4">"""
        assertEquals(
            "https://site.example/media/clip.mp4",
            OgParser.findMediaUrl(relative, base),
        )

        val protocolRelative = """<meta property="og:image" content="//cdn.example/i.png">"""
        assertEquals(
            "https://cdn.example/i.png",
            OgParser.findMediaUrl(protocolRelative, base),
        )
    }

    @Test
    fun fallsBackToVideoTags() {
        val html = """<video controls src="https://cdn.example/b.webm"></video>"""
        assertEquals("https://cdn.example/b.webm", OgParser.findMediaUrl(html, base))
    }

    @Test
    fun ignoresPagesWithoutMediaMetadata() {
        assertNull(OgParser.findMediaUrl("<html><body>nothing</body></html>", base))
        assertNull(OgParser.findMediaUrl("", base))
        assertNull(
            OgParser.findMediaUrl(
                """<meta property="og:title" content="no media">""",
                base,
            ),
        )
    }

    @Test
    fun decodesNumericEntities() {
        assertEquals("a/b?c=1&d=2", OgParser.decodeEntities("a&#x2F;b?c=1&amp;d=2"))
    }
}

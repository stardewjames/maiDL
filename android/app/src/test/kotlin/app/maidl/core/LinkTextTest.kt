package app.maidl.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkTextTest {

    @Test
    fun extractsTheLinkFromShareChatter() {
        assertEquals(
            "https://cdn.example.com/a/b.mp4",
            LinkText.parse("Look at this https://cdn.example.com/a/b.mp4 wow"),
        )
    }

    @Test
    fun trimsTrailingPunctuationAndPoisonedParens() {
        assertEquals(
            "https://example.com/pic.png",
            LinkText.parse("see (https://example.com/pic.png)."),
        )
        assertEquals(
            "https://example.com/pic.jpg",
            LinkText.parse("\"https://example.com/pic.jpg\""),
        )
    }

    @Test
    fun keepsBalancedParenthesesInThePath() {
        assertEquals(
            "https://example.com/wiki/Foo_(bar).jpg",
            LinkText.parse("https://example.com/wiki/Foo_(bar).jpg"),
        )
        assertEquals(
            "https://example.com/media(1)",
            LinkText.parse("(https://example.com/media(1))."),
        )
        assertEquals(
            "https://example.com/media(1)",
            LinkText.parse("https://example.com/media(1)"),
        )
    }

    @Test
    fun acceptsBareHostsButNotSentences() {
        assertEquals(
            "https://cdn.example.com/clip.mp4",
            LinkText.parse("cdn.example.com/clip.mp4"),
        )
        val error = assertThrows(LinkText.LinkException::class.java) {
            LinkText.parse("example.com is nice")
        }
        assertEquals("invalid_link", error.code)
    }

    @Test
    fun rejectsEmptyAndNonHttpInput() {
        assertThrows(LinkText.LinkException::class.java) { LinkText.parse("   ") }
        assertThrows(LinkText.LinkException::class.java) {
            LinkText.parse("ftp://example.com/a.mp4")
        }
    }

    @Test
    fun stripsTheFragmentSoTheSameLinkDeduplicates() {
        assertEquals(
            "https://example.com/v.mp4",
            LinkText.normalize("https://example.com/v.mp4#t=30"),
        )
    }

    @Test
    fun kindHintUsesTheUrlExtension() {
        assertEquals(MediaKind.VIDEO, LinkText.kindHint("https://x.dev/a.MP4?token=1"))
        assertEquals(MediaKind.IMAGE, LinkText.kindHint("https://x.dev/a.heic"))
        assertEquals(MediaKind.UNKNOWN, LinkText.kindHint("https://x.dev/watch"))
        assertTrue(LinkText.normalize(" https://x.dev/a.png ").startsWith("https://"))
    }
}

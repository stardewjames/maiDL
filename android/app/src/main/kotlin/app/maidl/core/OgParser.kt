package app.maidl.core

import java.net.URI

/**
 * Extracts a playable video or full-size image URL from page metadata so that
 * sharing a page link (not just a direct file link) still works.
 */
object OgParser {
    private val metaTag = Regex("""<meta\b[^>]*>""", RegexOption.IGNORE_CASE)
    private val mediaTag = Regex("""<(?:video|source)\b[^>]*>""", RegexOption.IGNORE_CASE)
    private val attribute = Regex(
        """([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))""",
    )

    private val priority = listOf(
        "og:video:secure_url",
        "og:video:url",
        "og:video",
        "twitter:player:stream",
        "og:image:secure_url",
        "og:image:url",
        "og:image",
        "twitter:image",
    )

    fun findMediaUrl(html: String, baseUrl: String): String? {
        val found = LinkedHashMap<String, String>()
        for (tag in metaTag.findAll(html)) {
            val attrs = attributes(tag.value)
            val key = (attrs["property"] ?: attrs["name"])?.trim()?.lowercase() ?: continue
            val content = attrs["content"]?.trim() ?: continue
            if (key in priority && content.isNotEmpty() && !found.containsKey(key)) {
                found[key] = content
            }
        }
        for (key in priority) {
            found[key]?.let { absolutize(it, baseUrl) }?.let { return it }
        }

        for (tag in mediaTag.findAll(html)) {
            val attrs = attributes(tag.value)
            val src = attrs["src"]?.trim()
            if (!src.isNullOrEmpty()) {
                absolutize(src, baseUrl)?.let { return it }
            }
        }
        return null
    }

    fun absolutize(value: String, baseUrl: String): String? {
        val decoded = decodeEntities(value.trim())
        if (decoded.isEmpty()) return null
        val resolved = when {
            decoded.startsWith("https://", true) || decoded.startsWith("http://", true) ->
                decoded
            decoded.startsWith("//") -> {
                val scheme = runCatching { URI(baseUrl).scheme }.getOrNull() ?: "https"
                "$scheme:$decoded"
            }
            decoded.startsWith("/") -> {
                val base = runCatching { URI(baseUrl) }.getOrNull() ?: return null
                val port = if (base.port > 0) ":${base.port}" else ""
                "${base.scheme}://${base.host}$port$decoded"
            }
            else -> runCatching { URI(baseUrl).resolve(decoded).toString() }.getOrNull()
        }
        if (resolved == null) return null
        return if (resolved.startsWith("http://", true) ||
            resolved.startsWith("https://", true)
        ) {
            resolved
        } else {
            null
        }
    }

    fun decodeEntities(value: String): String {
        if (!value.contains('&')) return value
        return value
            .replace("&amp;", "&")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&apos;", "'")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace(Regex("""&#x([0-9a-fA-F]+);""")) {
                it.groupValues[1].toIntOrNull(16)?.toChar()?.toString() ?: it.value
            }
            .replace(Regex("""&#(\d+);""")) {
                it.groupValues[1].toIntOrNull()?.toChar()?.toString() ?: it.value
            }
    }

    private fun attributes(tag: String): Map<String, String> {
        val result = HashMap<String, String>()
        for (match in attribute.findAll(tag)) {
            val value = match.groupValues[2]
                .ifEmpty { match.groupValues[3] }
                .ifEmpty { match.groupValues[4] }
            result.putIfAbsent(match.groupValues[1].lowercase(), value)
        }
        return result
    }
}

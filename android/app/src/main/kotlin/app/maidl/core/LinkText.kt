package app.maidl.core

/**
 * Link extraction shared by the share relay and the method channel.
 * Mirrors lib/src/core/link_input.dart so both sides reject the same input.
 */
object LinkText {
    class LinkException(val code: String, message: String) : Exception(message)

    private val httpUrl = Regex("""https?://[^\s<>"]+""", RegexOption.IGNORE_CASE)
    private val bareHost = Regex(
        """^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?(?:[/?#].*)?$""",
        RegexOption.IGNORE_CASE,
    )
    private const val trailingJunk = ".,;:!?]}>'\""

    fun parse(input: String): String {
        val text = input.trim()
        if (text.isEmpty()) {
            throw LinkException("invalid_link", "Paste a video or image link first.")
        }
        httpUrl.findAll(text).forEach { match ->
            val candidate = trimUrl(match.value)
            if (candidate != null) return normalize(candidate)
        }
        if (!text.any { it.isWhitespace() } && bareHost.matches(text)) {
            return normalize("https://$text")
        }
        throw LinkException("invalid_link", "That doesn't look like an http or https link.")
    }

    fun normalize(url: String): String = url.trim().substringBefore('#')

    /** Best-effort kind from the URL, confirmed later with the response type. */
    fun kindHint(url: String): MediaKind = MediaTypes.kindFromUrl(url)

    private fun trimUrl(value: String): String? {
        var candidate = value
        while (candidate.isNotEmpty()) {
            val last = candidate.last()
            if (trailingJunk.indexOf(last) >= 0) {
                candidate = candidate.dropLast(1)
                continue
            }
            if (last == ')' && candidate.count { it == '(' } < candidate.count { it == ')' }) {
                candidate = candidate.dropLast(1)
                continue
            }
            break
        }
        if (candidate.length <= "https://".length) return null
        if (candidate.endsWith("://")) return null
        return candidate
    }
}

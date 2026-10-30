package app.maidl.core

import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.concurrent.TimeUnit

data class SocialMedia(
    val mediaUrl: String,
    val fileName: String,
    val referer: String,
    val cookie: String?,
)

enum class SocialPlatform(val referer: String) {
    TIKTOK("https://www.tiktok.com/"),
    INSTAGRAM("https://www.instagram.com/"),
    X("https://x.com/"),
}

class SocialExtractorException(message: String) : Exception(message)

/**
 * Extracts a media URL from a public TikTok, Instagram or X page without a
 * server. Page cookies are kept and returned so the download request can use
 * the same session that produced the media URL.
 */
object SocialExtractor {
    private const val USER_AGENT =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 " +
            "Mobile/15E148 Safari/604.1 maiDL/1.0"

    private val cookieJar = MemoryCookieJar()

    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .cookieJar(cookieJar)
        .build()

    fun platformFor(link: String): SocialPlatform? {
        val host = runCatching { URI(link).host?.lowercase() }.getOrNull() ?: return null
        return when {
            host == "tiktok.com" || host.endsWith(".tiktok.com") ->
                SocialPlatform.TIKTOK
            host == "instagram.com" || host.endsWith(".instagram.com") ->
                SocialPlatform.INSTAGRAM
            host == "x.com" || host.endsWith(".x.com") ||
                host == "twitter.com" || host.endsWith(".twitter.com") ||
                host == "t.co" -> SocialPlatform.X
            else -> null
        }
    }

    fun isSupported(link: String): Boolean = platformFor(link) != null

    fun isYouTube(link: String): Boolean {
        val host = runCatching { URI(link).host?.lowercase() }.getOrNull() ?: return false
        return host == "youtube.com" || host.endsWith(".youtube.com") ||
            host == "youtu.be"
    }

    fun extract(link: String): SocialMedia {
        val platform = platformFor(link)
            ?: throw SocialExtractorException("That link isn't supported by the built-in extractor.")
        val request = Request.Builder()
            .url(link)
            .header("User-Agent", USER_AGENT)
            .header("Accept-Language", "en-US,en;q=0.9")
            .build()

        val (html, baseUrl) = try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    throw SocialExtractorException(
                        "That page blocked the request. Try the direct video link.",
                    )
                }
                (response.body?.string().orEmpty()) to response.request.url.toString()
            }
        } catch (error: SocialExtractorException) {
            throw error
        } catch (_: Exception) {
            throw SocialExtractorException(
                "That page could not be loaded. Check your connection.",
            )
        }

        val media = parseHtml(html, platform, baseUrl)
        val cookie = cookieJar.loadForRequest(media.toHttpUrlOrNull() ?: run {
            throw SocialExtractorException("The extractor returned an invalid media URL.")
        }).joinToString("; ") { "${it.name}=${it.value}" }.ifBlank { null }
        return SocialMedia(
            mediaUrl = media,
            fileName = MediaTypes.fileNameFor(
                media,
                null,
                null,
                System.currentTimeMillis(),
            ),
            referer = platform.referer,
            cookie = cookie,
        )
    }

    internal fun parseHtml(
        html: String,
        platform: SocialPlatform,
        baseUrl: String,
    ): String = when (platform) {
        SocialPlatform.TIKTOK -> parseTikTok(html, baseUrl)
        SocialPlatform.INSTAGRAM -> parseInstagram(html, baseUrl)
        SocialPlatform.X -> parseX(html, baseUrl)
    }

    private fun parseTikTok(html: String, baseUrl: String): String {
        for (identifier in listOf(
            "__UNIVERSAL_DATA_FOR_REHYDRATION__",
            "SIGI_STATE",
        )) {
            val json = scriptJson(html, identifier) ?: continue
            val video = findVideo(json)
            if (video != null) {
                val raw = video.optString("downloadAddr").ifBlank {
                    video.optString("playAddr")
                }
                httpUrl(raw)?.let { return it }
            }
            findImagePost(json)?.let { raw -> httpUrl(raw)?.let { return it } }
        }
        OgParser.findMediaUrl(html, baseUrl)
            ?.takeIf(::isVideoUrl)
            ?.let { return it }
        throw SocialExtractorException(
            "No downloadable video was found. The post may require login.",
        )
    }

    private fun parseInstagram(html: String, baseUrl: String): String {
        val candidates = listOf(
            regexFirst(""""video_url"\s*:\s*"([^"]+)"""", html),
            regexFirst(""""contentUrl"\s*:\s*"([^"]+)"""", html),
            regexFirst(
                """"video_versions"\s*:\s*\[\s*\{[^}]*"url"\s*:\s*"([^"]+)"""",
                html,
            ),
        )
        for (raw in candidates) {
            if (raw != null) httpUrl(raw)?.let { return it }
        }
        val og = OgParser.findMediaUrl(html, baseUrl)
        if (og != null) {
            val reel = baseUrl.contains("/reel/") || baseUrl.contains("/tv/")
            if (!reel || isVideoUrl(og)) return og
        }
        throw SocialExtractorException(
            "No downloadable video was found. The post may require login.",
        )
    }

    private fun parseX(html: String, baseUrl: String): String {
        val og = OgParser.findMediaUrl(html, baseUrl)
        if (og != null && isVideoUrl(og)) return og

        val matches = allMatches(
            """video\.twimg\.com[^"'\s]+?\.mp4(?:\?[^"'\s]*)? """.trim(),
            html,
        )
        for (candidate in matches.asReversed()) {
            httpUrl("https://$candidate")?.let { return it }
        }
        if (og != null) return og
        throw SocialExtractorException("No downloadable video was found on that post.")
    }

    private fun scriptJson(html: String, id: String): Any? {
        val body = regexFirst(
            """<script[^>]+id="${Regex.escape(id)}"[^>]*>(.*?)</script>""",
            html,
        ) ?: return null
        return runCatching { JSONObject(body) }.getOrNull()
    }

    private fun findImagePost(value: Any?): String? {
        when (value) {
            is JSONObject -> {
                val images = value.optJSONObject("imagePost")?.optJSONArray("images")
                if (images != null) {
                    for (index in 0 until images.length()) {
                        val image = images.optJSONObject(index) ?: continue
                        val imageUrl = image.optJSONObject("imageURL")
                        val list = imageUrl?.optJSONArray("urlList")
                        if (list != null) {
                            for (urlIndex in 0 until list.length()) {
                                val raw = list.optString(urlIndex)
                                if (raw.isNotBlank()) return raw
                            }
                        }
                        val raw = imageUrl?.optString("url").orEmpty()
                        if (raw.isNotBlank()) return raw
                    }
                }
                for (key in value.keys()) {
                    findImagePost(value.opt(key))?.let { return it }
                }
            }
            is JSONArray -> {
                for (index in 0 until value.length()) {
                    findImagePost(value.opt(index))?.let { return it }
                }
            }
        }
        return null
    }

    private fun findVideo(value: Any?): JSONObject? {
        when (value) {
            is JSONObject -> {
                if (value.has("playAddr") || value.has("downloadAddr")) return value
                for (key in value.keys()) {
                    findVideo(value.opt(key))?.let { return it }
                }
            }
            is JSONArray -> {
                for (index in 0 until value.length()) {
                    findVideo(value.opt(index))?.let { return it }
                }
            }
        }
        return null
    }

    private fun regexFirst(pattern: String, text: String): String? {
        return runCatching {
            Regex(
                pattern,
                setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
            ).find(text)?.groupValues?.getOrNull(1)
        }.getOrNull()
    }

    private fun allMatches(pattern: String, text: String): List<String> {
        return runCatching {
            Regex(pattern, RegexOption.IGNORE_CASE).findAll(text)
                .map { it.value }
                .toList()
        }.getOrDefault(emptyList())
    }

    private fun httpUrl(raw: String): String? {
        if (raw.isBlank()) return null
        return unescape(raw).toHttpUrlOrNull()?.toString()
    }

    private fun unescape(value: String): String = value
        .replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("\\u003d", "=")
        .replace("\\u0025", "%")
        .replace("&amp;", "&")
        .replace("\\\"", "\"")

    private fun isVideoUrl(value: String): Boolean {
        val url = value.toHttpUrlOrNull() ?: return false
        if (url.pathSegments.lastOrNull()?.substringAfterLast('.', "")
                ?.lowercase() in setOf("mp4", "mov", "m4v", "webm")
        ) {
            return true
        }
        val text = value.lowercase()
        return text.contains("video") || text.contains("mime_type=video")
    }

    private class MemoryCookieJar : CookieJar {
        private val cookies = mutableListOf<Cookie>()

        @Synchronized
        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            for (cookie in cookies) {
                this.cookies.removeAll {
                    it.name == cookie.name &&
                        it.domain == cookie.domain &&
                        it.path == cookie.path
                }
                this.cookies.add(cookie)
            }
        }

        @Synchronized
        override fun loadForRequest(url: HttpUrl): List<Cookie> =
            cookies.filter { it.matches(url) }
    }
}

package app.maidl.core

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.net.URI
import java.util.concurrent.TimeUnit

/**
 * Resolves social links through a user-configured yt-dlp service. The service
 * returns a direct URL the normal download engine can fetch.
 */
object LinkResolver {
    data class Resolved(val mediaUrl: String, val fileName: String?)

    class ResolverException(message: String) : Exception(message)

    private const val YTDLP_SUFFIX = "/resolve"

    private val supportedSuffixes = listOf(
        "tiktok.com",
        "instagram.com",
        "youtube.com",
        "youtu.be",
        "twitter.com",
        "x.com",
        "t.co",
    )

    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .build()

    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    fun isSupported(link: String): Boolean {
        val host = runCatching { URI(link).host?.lowercase() }.getOrNull() ?: return false
        return supportedSuffixes.any { suffix ->
            host == suffix || host.endsWith(".$suffix")
        }
    }

    fun resolve(link: String, settings: ResolverSettings): Resolved {
        val base = settings.endpoint
            ?: throw ResolverException("Add a resolver URL in Settings → Social links.")
        if (settings.mode != ResolverMode.YTDLP) {
            throw ResolverException("Turn on the yt-dlp resolver in Settings → Social links.")
        }
        val endpoint = base.trimEnd('/') + YTDLP_SUFFIX
        val body = JSONObject().put("url", link).toString().toRequestBody(jsonMediaType)
        val request = try {
            Request.Builder()
                .url(endpoint)
                .header("Accept", "application/json")
                .post(body)
                .build()
        } catch (_: IllegalArgumentException) {
            throw ResolverException("The resolver URL is not valid.")
        }

        try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    throw ResolverException("The resolver returned HTTP ${response.code}.")
                }
                val text = response.body?.string().orEmpty()
                val json = runCatching { JSONObject(text) }.getOrNull()
                    ?: throw ResolverException("The resolver returned unreadable data.")
                return parse(json)
            }
        } catch (error: ResolverException) {
            throw error
        } catch (_: IOException) {
            throw ResolverException(
                "The resolver could not be reached. Check its URL and connection.",
            )
        }
    }

    internal fun parse(json: JSONObject): Resolved {
        val media = mediaUrl(json.optString("url"))
            ?: throw ResolverException("The yt-dlp service did not return a media URL.")
        return Resolved(
            mediaUrl = media,
            fileName = json.optString("fileName").takeIf { it.isNotBlank() }
                ?: json.optString("filename").takeIf { it.isNotBlank() },
        )
    }

    private fun mediaUrl(raw: String): String? {
        if (raw.isBlank()) return null
        val uri = runCatching { URI(raw) }.getOrNull() ?: return null
        if (uri.scheme?.lowercase() !in setOf("http", "https")) return null
        if (uri.host.isNullOrBlank()) return null
        return raw
    }
}

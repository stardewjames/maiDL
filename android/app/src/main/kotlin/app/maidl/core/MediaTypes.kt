package app.maidl.core

import java.net.URI
import java.net.URLDecoder

enum class MediaKind(val wire: String) {
    VIDEO("video"),
    IMAGE("image"),
    UNKNOWN("unknown");

    val isMedia: Boolean get() = this != UNKNOWN

    companion object {
        fun fromWire(value: String?): MediaKind =
            entries.firstOrNull { it.wire == value } ?: UNKNOWN

        fun fromContentType(contentType: String?): MediaKind {
            val type = contentType?.trim()?.lowercase()?.substringBefore(';') ?: return UNKNOWN
            return when {
                type.startsWith("video/") -> VIDEO
                type.startsWith("image/") -> IMAGE
                else -> UNKNOWN
            }
        }
    }
}

object MediaTypes {
    private val extensionToKind: Map<String, MediaKind> = mapOf(
        "mp4" to MediaKind.VIDEO,
        "m4v" to MediaKind.VIDEO,
        "mov" to MediaKind.VIDEO,
        "webm" to MediaKind.VIDEO,
        "mkv" to MediaKind.VIDEO,
        "avi" to MediaKind.VIDEO,
        "3gp" to MediaKind.VIDEO,
        "mpg" to MediaKind.VIDEO,
        "mpeg" to MediaKind.VIDEO,
        "jpg" to MediaKind.IMAGE,
        "jpeg" to MediaKind.IMAGE,
        "png" to MediaKind.IMAGE,
        "gif" to MediaKind.IMAGE,
        "webp" to MediaKind.IMAGE,
        "heic" to MediaKind.IMAGE,
        "heif" to MediaKind.IMAGE,
        "bmp" to MediaKind.IMAGE,
        "tif" to MediaKind.IMAGE,
        "tiff" to MediaKind.IMAGE,
    )

    private val mimeToExtension: Map<String, String> = mapOf(
        "video/mp4" to "mp4",
        "video/quicktime" to "mov",
        "video/webm" to "webm",
        "video/x-matroska" to "mkv",
        "video/3gpp" to "3gp",
        "video/mpeg" to "mpg",
        "image/jpeg" to "jpg",
        "image/png" to "png",
        "image/gif" to "gif",
        "image/webp" to "webp",
        "image/heic" to "heic",
        "image/heif" to "heif",
        "image/bmp" to "bmp",
        "image/tiff" to "tiff",
    )

    private val videoExtensions = setOf(
        "mp4", "m4v", "mov", "webm", "mkv", "avi", "3gp", "mpg", "mpeg",
    )
    private val imageExtensions = setOf(
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
    )

    private val contentTypeByExtension: Map<String, String> = mapOf(
        "mp4" to "video/mp4",
        "m4v" to "video/mp4",
        "mov" to "video/quicktime",
        "webm" to "video/webm",
        "mkv" to "video/x-matroska",
        "3gp" to "video/3gpp",
        "jpg" to "image/jpeg",
        "jpeg" to "image/jpeg",
        "png" to "image/png",
        "gif" to "image/gif",
        "webp" to "image/webp",
        "heic" to "image/heic",
        "heif" to "image/heif",
        "bmp" to "image/bmp",
        "tiff" to "image/tiff",
    )

    private val unsafeChars = Regex("""[^A-Za-z0-9._ ()-]""")
    private val maxNameLength = 120

    fun kindFromUrl(url: String): MediaKind {
        val extension = extensionOf(url) ?: return MediaKind.UNKNOWN
        return extensionToKind[extension] ?: MediaKind.UNKNOWN
    }

    fun extensionOf(url: String): String? {
        val path = url.substringBefore('#').substringBefore('?')
        val name = path.trimEnd('/').substringAfterLast('/', missingDelimiterValue = "")
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return null
        return name.substring(dot + 1).lowercase()
    }

    fun extensionForMime(contentType: String?): String? {
        val type = contentType?.trim()?.lowercase()?.substringBefore(';')?.trim() ?: return null
        return mimeToExtension[type]
    }

    fun contentTypeFor(fileName: String): String {
        val extension = fileName.substringAfterLast('.', "").lowercase()
        return contentTypeByExtension[extension] ?: "application/octet-stream"
    }

    /** True when [name] carries a recognisable media extension. */
    fun isMediaFileName(name: String): Boolean {
        val extension = name.substringAfterLast('.', "").lowercase()
        return extension in videoExtensions || extension in imageExtensions
    }

    /**
     * Builds a display name that the gallery indexing pipeline understands:
     * a safe base name plus an extension consistent with the response.
     */
    fun fileNameFor(
        url: String,
        contentType: String?,
        contentDisposition: String?,
        fallbackMillis: Long,
    ): String {
        val fromHeader = parseContentDispositionName(contentDisposition)
        val fromUrl = urlName(url)
        var candidate = fromHeader ?: fromUrl ?: "maiDL_$fallbackMillis"

        val mimeExtension = extensionForMime(contentType)
        val candidateExtension = candidate.substringAfterLast('.', "").lowercase()
        val extension = when {
            mimeExtension != null -> mimeExtension
            candidateExtension.isNotEmpty() -> candidateExtension
            else -> null
        }

        var base = candidate
        if (candidateExtension in extensionToKind && candidate.contains('.')) {
            base = candidate.substringBeforeLast('.')
        }
        base = base.replace(unsafeChars, "_").trim().trim('.', ' ').take(maxNameLength)
        if (base.isEmpty()) base = "maiDL_$fallbackMillis"

        return if (extension == null) base else "$base.$extension"
    }

    fun parseContentDispositionName(header: String?): String? {
        if (header.isNullOrBlank()) return null
        // RFC 5987 variant: filename*=UTF-8''my%20video.mp4
        val encoded = Regex(
            """filename\*\s*=\s*(?:[A-Za-z0-9-]+)?'[^']*'([^;]+)""",
            RegexOption.IGNORE_CASE,
        ).find(header)?.groupValues?.get(1)?.trim()?.trim('"')
        if (!encoded.isNullOrBlank()) {
            val decoded = runCatching { URLDecoder.decode(encoded, "UTF-8") }.getOrNull()
            if (!decoded.isNullOrBlank()) return decoded
        }
        return Regex("""filename\s*=\s*"([^"]+)"""", RegexOption.IGNORE_CASE)
            .find(header)?.groupValues?.get(1)?.trim()
            ?: Regex("""filename\s*=\s*([^;]+)""", RegexOption.IGNORE_CASE)
                .find(header)?.groupValues?.get(1)?.trim()?.trim('"')
    }

    private fun urlName(url: String): String? {
        val path = runCatching { URI(url).rawPath }.getOrNull()
            ?: url.substringBefore('#').substringBefore('?')
        val trimmed = path.trimEnd('/')
        if (trimmed.isEmpty()) return null
        val raw = trimmed.substringAfterLast('/', missingDelimiterValue = "")
        if (raw.isBlank()) return null
        val decoded = runCatching { URLDecoder.decode(raw, "UTF-8") }.getOrNull() ?: raw
        return decoded.takeIf { it.isNotBlank() }
    }
}

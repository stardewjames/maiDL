package app.maidl.core

import org.json.JSONArray
import org.json.JSONObject

enum class JobStatus(val wire: String) {
    RESOLVING("resolving"),
    QUEUED("queued"),
    DOWNLOADING("downloading"),
    SAVING("saving"),
    COMPLETED("completed"),
    FAILED("failed"),
    CANCELED("canceled");

    val isActive: Boolean
        get() = this == RESOLVING || this == QUEUED || this == DOWNLOADING ||
            this == SAVING

    val isTerminal: Boolean
        get() = !isActive

    companion object {
        fun fromWire(value: String?): JobStatus =
            entries.firstOrNull { it.wire == value } ?: QUEUED
    }
}

enum class JobOrigin(val wire: String) {
    SHARE("share"),
    MANUAL("manual");

    companion object {
        fun fromWire(value: String?): JobOrigin =
            entries.firstOrNull { it.wire == value } ?: MANUAL
    }
}

data class Job(
    val id: String,
    val url: String,
    val kind: MediaKind,
    val fileName: String,
    val status: JobStatus,
    val origin: JobOrigin,
    val createdAt: Long,
    val updatedAt: Long,
    val bytesReceived: Long = 0,
    val totalBytes: Long = -1,
    val error: String? = null,
    val remoteId: String? = null,
    val mimeType: String? = null,
    // Direct media URL when a social link was resolved.
    val mediaUrl: String? = null,
    val referer: String? = null,
    val cookie: String? = null,
    // Internal execution generation; deliberately not part of the channel payload.
    val generation: Long = 0,
) {
    val isActive: Boolean get() = status.isActive

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("url", url)
        put("kind", kind.wire)
        put("fileName", fileName)
        put("status", status.wire)
        put("origin", origin.wire)
        put("createdAt", createdAt)
        put("updatedAt", updatedAt)
        put("bytesReceived", bytesReceived)
        put("totalBytes", totalBytes)
        put("error", error ?: JSONObject.NULL)
        put("remoteId", remoteId ?: JSONObject.NULL)
        put("mimeType", mimeType ?: JSONObject.NULL)
        put("mediaUrl", mediaUrl ?: JSONObject.NULL)
        put("referer", referer ?: JSONObject.NULL)
        put("cookie", cookie ?: JSONObject.NULL)
        put("generation", generation)
    }

    companion object {
        fun listToJson(jobs: List<Job>): JSONArray =
            JSONArray().apply { jobs.forEach { put(it.toJson()) } }

        fun fromJson(json: JSONObject): Job? {
            val id = json.optString("id").takeIf { it.isNotBlank() } ?: return null
            val url = json.optString("url").takeIf { it.isNotBlank() } ?: return null
            val kind = MediaKind.fromWire(json.optString("kind"))
            val fileName = json.optString("fileName").takeIf { it.isNotBlank() } ?: "media"
            return Job(
                id = id,
                url = url,
                kind = kind,
                fileName = fileName,
                status = JobStatus.fromWire(json.optString("status")),
                origin = JobOrigin.fromWire(json.optString("origin")),
                createdAt = json.optLong("createdAt", 0L),
                updatedAt = json.optLong("updatedAt", 0L),
                bytesReceived = json.optLong("bytesReceived", 0L).coerceAtLeast(0L),
                totalBytes = json.optLong("totalBytes", -1L),
                error = json.optString("error").takeIf { it.isNotBlank() },
                remoteId = json.optString("remoteId").takeIf { it.isNotBlank() },
                mimeType = json.optString("mimeType").takeIf { it.isNotBlank() },
                mediaUrl = json.optString("mediaUrl").takeIf { it.isNotBlank() },
                referer = json.optString("referer").takeIf { it.isNotBlank() },
                cookie = json.optString("cookie").takeIf { it.isNotBlank() },
                generation = json.optLong("generation", 0L),
            )
        }
    }
}

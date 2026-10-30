package app.maidl.core

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import java.net.URI

enum class ResolverMode(val wire: String) {
    OFF("off"),
    YTDLP("ytdlp"),
    COBALT("cobalt");

    companion object {
        fun fromWire(value: String?): ResolverMode =
            entries.firstOrNull { it.wire == value } ?: OFF
    }
}

data class ResolverSettings(
    val mode: ResolverMode = ResolverMode.OFF,
    val ytdlpUrl: String = "",
    val cobaltUrl: String = "",
) {
    val endpoint: String?
        get() {
            val raw = when (mode) {
                ResolverMode.OFF -> return null
                ResolverMode.YTDLP -> ytdlpUrl
                ResolverMode.COBALT -> cobaltUrl
            }.trim()
            if (raw.isEmpty()) return null
            val uri = runCatching { URI(raw) }.getOrNull() ?: return null
            if (uri.scheme?.lowercase() !in setOf("http", "https")) return null
            if (uri.host.isNullOrBlank()) return null
            return raw
        }

    val isEnabled: Boolean get() = mode != ResolverMode.OFF && endpoint != null

    fun toPayload(): Map<String, Any?> = mapOf(
        "mode" to mode.wire,
        "ytdlpUrl" to ytdlpUrl,
        "cobaltUrl" to cobaltUrl,
    )

    fun toJson(): JSONObject = JSONObject().apply {
        put("mode", mode.wire)
        put("ytdlpUrl", ytdlpUrl)
        put("cobaltUrl", cobaltUrl)
    }

    companion object {
        fun fromJson(json: JSONObject): ResolverSettings = ResolverSettings(
            mode = ResolverMode.fromWire(json.optString("mode")),
            ytdlpUrl = json.optString("ytdlpUrl").trim(),
            cobaltUrl = json.optString("cobaltUrl").trim(),
        )

        fun fromPayload(arguments: Map<*, *>?): ResolverSettings = ResolverSettings(
            mode = ResolverMode.fromWire(arguments?.get("mode") as? String),
            ytdlpUrl = (arguments?.get("ytdlpUrl") as? String).orEmpty().trim(),
            cobaltUrl = (arguments?.get("cobaltUrl") as? String).orEmpty().trim(),
        )
    }
}

class ResolverSettingsStore private constructor(
    private val prefs: SharedPreferences,
) {
    fun load(): ResolverSettings {
        val raw = prefs.getString(KEY, null) ?: return ResolverSettings()
        return runCatching { ResolverSettings.fromJson(JSONObject(raw)) }
            .getOrDefault(ResolverSettings())
    }

    fun save(settings: ResolverSettings) {
        prefs.edit().putString(KEY, settings.toJson().toString()).apply()
    }

    companion object {
        private const val PREFS = "maidl_settings"
        private const val KEY = "resolver"

        fun get(context: Context): ResolverSettingsStore =
            ResolverSettingsStore(
                context.applicationContext.getSharedPreferences(
                    PREFS,
                    Context.MODE_PRIVATE,
                ),
            )
    }
}

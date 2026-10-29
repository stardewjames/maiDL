package app.maidl

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import app.maidl.core.Job
import app.maidl.core.JobOrigin
import app.maidl.core.LinkText
import app.maidl.core.MediaTypes
import app.maidl.core.Notifications
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter bridge. Mirrors the contract documented in lib/src/core/downloads_api.dart.
 */
class MaidlBridge(
    private val activity: Activity,
    private val repository: DownloadRepository,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val lastSent = HashMap<String, String>()
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingNotificationResult: MethodChannel.Result? = null

    private val storeListener: () -> Unit = { mainHandler.post { emitChanges() } }

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
        repository.addListener(storeListener)
        repository.reconcile()
    }

    fun detach() {
        repository.removeListener(storeListener)
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
        pendingNotificationResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                Notifications.ensureChannels(activity)
                repository.reconcile()
                result.success(
                    mapOf(
                        "jobs" to repository.jobs().map { it.payload() },
                        "platform" to "android",
                        "photos" to "unsupported",
                        "notifications" to notificationState(),
                        "canOpenSaved" to true,
                    ),
                )
            }

            "history" -> {
                repository.reconcile()
                result.success(repository.jobs().map { it.payload() })
            }

            "enqueue" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("invalid_link", "No link was provided.", null)
                    return
                }
                val origin = JobOrigin.fromWire(call.argument<String>("origin"))
                try {
                    result.success(repository.enqueueUrl(url, origin).payload())
                } catch (error: LinkText.LinkException) {
                    result.error(error.code, error.message, null)
                }
            }

            "retry" -> withJobId(call, result) { id ->
                try {
                    result.success(repository.retry(id).payload())
                } catch (error: LinkText.LinkException) {
                    result.error(error.code, error.message, null)
                }
            }

            "cancel" -> withJobId(call, result) { id ->
                repository.cancel(id)
                result.success(null)
            }

            "remove" -> withJobId(call, result) { id ->
                repository.remove(id)
                result.success(null)
            }

            "clearHistory" -> {
                repository.clearHistory()
                result.success(null)
            }

            "openSaved" -> withJobId(call, result) { id ->
                result.success(openSaved(id))
            }

            "requestPhotoAccess" -> result.success("unsupported")

            "requestNotifications" -> requestNotifications(result)

            else -> result.notImplemented()
        }
    }

    fun onPermissionResult(requestCode: Int, granted: Boolean) {
        if (requestCode != REQUEST_NOTIFICATIONS) return
        pendingNotificationResult?.success(granted)
        pendingNotificationResult = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        lastSent.clear()
        repository.jobs().forEach { job ->
            lastSent[job.id] = job.toJson().toString()
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emitChanges() {
        val sink = eventSink ?: return
        val current = repository.jobs()
        for (job in current) {
            val serialized = job.toJson().toString()
            if (lastSent[job.id] != serialized) {
                lastSent[job.id] = serialized
                runCatching { sink.success(job.payload()) }
            }
        }
        lastSent.keys.retainAll(current.map { it.id }.toSet())
    }

    private fun withJobId(
        call: MethodCall,
        result: MethodChannel.Result,
        action: (String) -> Unit,
    ) {
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error("not_found", "No download was specified.", null)
            return
        }
        action(id)
    }

    private fun openSaved(id: String): Boolean {
        val job = repository.job(id) ?: return false
        val uri = job.remoteId?.let(Uri::parse) ?: return false
        val mime = job.mimeType ?: MediaTypes.contentTypeFor(job.fileName)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(Notifications.canPost(activity))
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        if (pendingNotificationResult != null) {
            result.success(false)
            return
        }
        pendingNotificationResult = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATIONS,
        )
    }

    private fun notificationState(): String = when {
        Notifications.canPost(activity) -> "granted"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED -> "granted"
        else -> "denied"
    }

    private fun Job.payload(): Map<String, Any?> = mapOf(
        "id" to id,
        "url" to url,
        "kind" to kind.wire,
        "fileName" to fileName,
        "status" to status.wire,
        "origin" to origin.wire,
        "createdAt" to createdAt,
        "updatedAt" to updatedAt,
        "bytesReceived" to bytesReceived,
        "totalBytes" to totalBytes,
        "error" to error,
        "remoteId" to remoteId,
    )

    companion object {
        const val METHOD_CHANNEL = "app.maidl/downloads"
        const val EVENT_CHANNEL = "app.maidl/download_events"
        private const val REQUEST_NOTIFICATIONS = 4711
    }
}

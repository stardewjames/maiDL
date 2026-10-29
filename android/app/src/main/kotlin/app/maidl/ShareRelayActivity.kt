package app.maidl

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import app.maidl.core.JobOrigin
import app.maidl.core.LinkText
import app.maidl.core.Notifications
import java.util.concurrent.Executors

/**
 * Invisible share target.
 *
 * The share sheet launches this activity, a job is queued (or a failure is
 * reported), and it finishes immediately. No Flutter engine is started, so
 * sharing costs a few hundred milliseconds and no visible app switch.
 */
class ShareRelayActivity : Activity() {

    private val worker = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            handle(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        val text = intent?.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
            ?: intent?.getStringExtra(Intent.EXTRA_SUBJECT)?.takeIf { it.isNotBlank() }
        if (text == null) {
            finish()
            return
        }

        worker.execute {
            try {
                // Blocks until WorkManager has persisted the request so the
                // job cannot be lost when this activity finishes.
                val job = DownloadRepository.get(applicationContext)
                    .enqueueAwaitingPersist(text, JobOrigin.SHARE)
                if (!Notifications.canPost(applicationContext)) {
                    runOnUiThread {
                        Toast.makeText(
                            applicationContext,
                            "Saving ${job.fileName}…",
                            Toast.LENGTH_SHORT,
                        ).show()
                    }
                }
            } catch (error: LinkText.LinkException) {
                report(error.message ?: "That link could not be saved.")
            } catch (_: Throwable) {
                report("The link could not be saved.")
            }
            runOnUiThread {
                if (!isFinishing) finish()
            }
        }
    }

    private fun report(message: String) {
        Notifications.linkFailed(applicationContext, message)
        if (!Notifications.canPost(applicationContext)) {
            runOnUiThread {
                Toast.makeText(applicationContext, message, Toast.LENGTH_LONG).show()
            }
        }
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }
}

package app.maidl.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import app.maidl.CancelDownloadReceiver
import app.maidl.MainActivity
import app.maidl.R

object Notifications {
    const val CHANNEL_PROGRESS = "downloads_progress"
    const val CHANNEL_RESULT = "downloads_result"
    private const val LINK_FAILURE_ID = 424242

    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_PROGRESS,
                "Download progress",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Silent progress while a link downloads in the background"
                setShowBadge(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_RESULT,
                "Saved downloads",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Tells you when a download has been added to your library"
                setShowBadge(false)
            },
        )
    }

    fun canPost(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled()

    fun progressId(jobId: String): Int = jobId.hashCode() and 0x7fffffff

    private fun resultId(jobId: String): Int = (progressId(jobId) + 1) and 0x7fffffff

    fun progress(
        context: Context,
        job: Job,
        received: Long,
        total: Long,
        saving: Boolean = false,
    ): Notification {
        ensureChannels(context)
        val percent = if (total > 0) {
            ((received.coerceAtMost(total) * 100) / total).toInt()
        } else {
            -1
        }
        val text = when {
            job.status == JobStatus.RESOLVING -> "Resolving link…"
            saving -> "Adding to your library…"
            total > 0 -> "$percent% · ${formatBytes(received)} of ${formatBytes(total)}"
            else -> "${formatBytes(received)} downloaded"
        }
        val builder = NotificationCompat.Builder(context, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle(job.fileName)
            .setContentText(text)
            .setProgress(100, if (percent >= 0) percent else 0, percent < 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openApp(context))

        if (!saving) {
            val cancel = PendingIntent.getBroadcast(
                context,
                progressId(job.id),
                Intent(context, CancelDownloadReceiver::class.java)
                    .putExtra(CancelDownloadReceiver.EXTRA_JOB_ID, job.id),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(
                R.drawable.ic_stat_download,
                "Cancel",
                cancel,
            )
        }
        return builder.build()
    }

    fun updateProgress(
        context: Context,
        job: Job,
        received: Long,
        total: Long,
        saving: Boolean = false,
    ) {
        if (!canPost(context)) return
        runCatching {
            NotificationManagerCompat.from(context).notify(
                progressId(job.id),
                progress(context, job, received, total, saving),
            )
        }
    }

    fun result(context: Context, job: Job, success: Boolean) {
        ensureChannels(context)
        if (!canPost(context)) return
        val title = if (success) "Saved to your library" else "Couldn't save your download"
        val text = if (success) {
            job.fileName
        } else {
            job.error ?: "The link could not be downloaded."
        }
        val builder = NotificationCompat.Builder(context, CHANNEL_RESULT)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(openApp(context))
        runCatching {
            NotificationManagerCompat.from(context)
                .notify(resultId(job.id), builder.build())
        }
    }

    fun linkFailed(context: Context, message: String) {
        ensureChannels(context)
        if (!canPost(context)) return
        val builder = NotificationCompat.Builder(context, CHANNEL_RESULT)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle("Couldn't save that link")
            .setContentText(message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(message))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_ERROR)
            .setContentIntent(openApp(context))
        runCatching {
            NotificationManagerCompat.from(context).notify(LINK_FAILURE_ID, builder.build())
        }
    }

    fun cancel(context: Context, jobId: String) {
        NotificationManagerCompat.from(context).cancel(progressId(jobId))
    }

    private fun openApp(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

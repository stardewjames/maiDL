package app.maidl

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.Operation
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import app.maidl.core.DownloadWorker
import app.maidl.core.Job
import app.maidl.core.JobOrigin
import app.maidl.core.JobStatus
import app.maidl.core.JobStore
import app.maidl.core.LinkText
import app.maidl.core.MediaTypes
import app.maidl.core.Notifications
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Owns the queue: turns links into persisted jobs, schedules WorkManager, and
 * keeps the persisted state honest when work has silently died.
 */
class DownloadRepository private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val store = JobStore.get(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        Notifications.ensureChannels(appContext)
    }

    fun jobs(): List<Job> = store.list()

    fun job(id: String): Job? = store.get(id)

    fun addListener(listener: () -> Unit) = store.addListener(listener)

    fun removeListener(listener: () -> Unit) = store.removeListener(listener)

    fun enqueue(input: String, origin: JobOrigin): Job =
        enqueueUrl(LinkText.parse(input), origin)

    @Synchronized
    fun enqueueUrl(url: String, origin: JobOrigin): Job {
        val job = createJob(url, origin)
        schedule(job)
        return job
    }

    /**
     * Waits for WorkManager to persist the request. Used by the share relay,
     * which finishes immediately: without this the job could be lost if the
     * process dies before WorkManager's database write lands.
     */
    @Synchronized
    fun enqueueAwaitingPersist(input: String, origin: JobOrigin): Job {
        val job = createJob(LinkText.parse(input), origin)
        schedule(job).result.get()
        return job
    }

    private fun createJob(url: String, origin: JobOrigin): Job {
        val normalized = LinkText.normalize(url)
        store.activeDuplicate(normalized)?.let { return it }

        val now = System.currentTimeMillis()
        val job = Job(
            id = UUID.randomUUID().toString(),
            url = normalized,
            kind = LinkText.kindHint(normalized),
            fileName = MediaTypes.fileNameFor(normalized, null, null, now),
            status = JobStatus.QUEUED,
            origin = origin,
            createdAt = now,
            updatedAt = now,
        )
        store.put(job)
        return job
    }

    @Synchronized
    fun retry(id: String): Job {
        val existing = store.get(id) ?: throw LinkText.LinkException(
            "not_found",
            "That download is no longer in the list.",
        )
        if (existing.isActive) return existing
        val job = existing.copy(
            status = JobStatus.QUEUED,
            error = null,
            bytesReceived = 0,
            totalBytes = -1,
            remoteId = null,
            mediaUrl = null,
            referer = null,
            cookie = null,
            mimeType = null,
            updatedAt = System.currentTimeMillis(),
            generation = existing.generation + 1,
        )
        store.put(job)
        schedule(job, replace = true)
        return job
    }

    @Synchronized
    fun cancel(id: String) {
        val canceled = store.update(id) { job ->
            if (!job.isActive) return@update null
            job.copy(
                status = JobStatus.CANCELED,
                updatedAt = System.currentTimeMillis(),
            )
        } ?: return
        WorkManager.getInstance(appContext).cancelUniqueWork(workName(canceled.id))
        Notifications.cancel(appContext, id)
    }

    @Synchronized
    fun remove(id: String) {
        if (store.get(id)?.isActive == true) cancel(id)
        store.remove(id)
        File(appContext.cacheDir, "downloads/$id").deleteRecursively()
        File(appContext.cacheDir, "downloads/$id.part").delete()
        File(appContext.cacheDir, "downloads/$id.part.resume").delete()
    }

    fun clearHistory() {
        store.clearFinished()
    }

    /**
     * WorkManager drops work when the user force-stops the app. Active jobs
     * with no live work would otherwise spin forever in the UI.
     */
    fun reconcile() {
        scope.launch {
            val active = store.list().filter { it.isActive }
            if (active.isEmpty()) return@launch
            val workManager = WorkManager.getInstance(appContext)
            for (job in active) {
                val infos = runCatching {
                    workManager.getWorkInfosForUniqueWork(workName(job.id))
                        .get(5, TimeUnit.SECONDS)
                }.getOrNull() ?: continue
                val alive = infos.any {
                    it.state == WorkInfo.State.ENQUEUED ||
                        it.state == WorkInfo.State.RUNNING ||
                        it.state == WorkInfo.State.BLOCKED
                }
                if (alive) continue
                store.update(job.id) { latest ->
                    if (!latest.isActive || latest.generation != job.generation) {
                        return@update null
                    }
                    latest.copy(
                        status = JobStatus.FAILED,
                        error = "The download was interrupted. Tap Try again.",
                        updatedAt = System.currentTimeMillis(),
                    )
                }
            }
        }
    }

    private fun schedule(job: Job, replace: Boolean = false): Operation {
        val request = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setInputData(
                workDataOf(
                    DownloadWorker.KEY_JOB_ID to job.id,
                    DownloadWorker.KEY_GENERATION to job.generation,
                ),
            )
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .setBackoffCriteria(
                BackoffPolicy.EXPONENTIAL,
                DownloadWorker.BACKOFF_DELAY_SECONDS,
                TimeUnit.SECONDS,
            )
            .addTag(TAG)
            .build()
        return WorkManager.getInstance(appContext).enqueueUniqueWork(
            workName(job.id),
            if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP,
            request,
        )
    }

    private fun workName(id: String): String = "maidl-download-$id"

    companion object {
        private const val TAG = "maidl-download"

        @Volatile
        private var instance: DownloadRepository? = null

        fun get(context: Context): DownloadRepository =
            instance ?: synchronized(this) {
                instance ?: DownloadRepository(context).also { instance = it }
            }
    }
}

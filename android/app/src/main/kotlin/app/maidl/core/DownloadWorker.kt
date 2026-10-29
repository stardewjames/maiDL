package app.maidl.core

import android.content.Context
import android.content.pm.ServiceInfo
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.IOException
import java.util.concurrent.CancellationException
import java.util.concurrent.TimeUnit

/**
 * One job per unique work name. Survives app death, resumes partial files, and
 * publishes into MediaStore only after the bytes are fully on disk.
 */
class DownloadWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val jobId = inputData.getString(KEY_JOB_ID) ?: return@withContext Result.failure()
        withExecutionLock(jobId) { performWork() }
    }

    private suspend fun performWork(): Result {
        val jobId = inputData.getString(KEY_JOB_ID) ?: return Result.failure()
        val generation = inputData.getLong(KEY_GENERATION, 0)
        val store = JobStore.get(applicationContext)
        val initial = store.get(jobId) ?: return Result.failure()
        if (initial.generation != generation) return Result.failure()
        if (initial.status == JobStatus.COMPLETED) return Result.success()
        if (!initial.isActive) return Result.failure()

        val workerContext = currentCoroutineContext()
        val partFile = File(applicationContext.cacheDir, "downloads/$jobId/$generation.part")
        val engine = DownloadEngine()
        var job = initial
        var lastUpdate = 0L
        var lastPercent = Int.MIN_VALUE

        fun ensureRunning() {
            workerContext.ensureActive()
            val latest = store.get(jobId)
            if (isStopped || latest == null || !latest.isActive ||
                latest.generation != generation
            ) {
                throw CancellationException()
            }
        }

        try {
            ensureRunning()
            Notifications.ensureChannels(applicationContext)
            job = updateActive(store, jobId, generation) {
                it.copy(
                    status = JobStatus.DOWNLOADING,
                    error = null,
                    updatedAt = System.currentTimeMillis(),
                )
            }
            trySetForeground(job, 0, -1)

            val result = coroutineScope {
                val transfer = async {
                    engine.fetch(
                        sourceUrl = job.url,
                        partFile = partFile,
                        resumeFrom = partFile.length(),
                        onMetadata = { info ->
                            ensureRunning()
                            job = updateActive(store, jobId, generation) {
                                it.copy(
                                    kind = info.kind,
                                    fileName = info.fileName,
                                    mimeType = info.mimeType,
                                    totalBytes = info.totalBytes,
                                    updatedAt = System.currentTimeMillis(),
                                )
                            }
                        },
                        onProgress = { received, total ->
                            val now = System.currentTimeMillis()
                            val percent = if (total > 0) {
                                ((received * 100) / total).toInt()
                            } else {
                                -1
                            }
                            if (now - lastUpdate >= PROGRESS_INTERVAL_MS || percent != lastPercent) {
                                ensureRunning()
                                lastUpdate = now
                                lastPercent = percent
                                job = updateActive(store, jobId, generation) {
                                    it.copy(
                                        bytesReceived = received,
                                        totalBytes = total,
                                        updatedAt = now,
                                    )
                                }
                                Notifications.updateProgress(
                                    applicationContext, job, received, total,
                                )
                            }
                        },
                        isCanceled = {
                            isStopped || !workerContext.isActive
                        },
                    )
                }
                try {
                    transfer.await()
                } finally {
                    // Await is cancellable even while execute()/read() blocks.
                    // Cancel the socket before the scope waits for its child.
                    engine.cancel()
                }
            }

            ensureRunning()
            val info = result.info
            job = updateActive(store, jobId, generation) {
                it.copy(
                    status = JobStatus.SAVING,
                    kind = info.kind,
                    fileName = info.fileName,
                    mimeType = info.mimeType,
                    bytesReceived = result.bytesWritten,
                    totalBytes = info.totalBytes,
                    updatedAt = System.currentTimeMillis(),
                )
            }
            trySetForeground(job, result.bytesWritten, info.totalBytes, saving = true)

            var lastSaveUpdate = 0L
            MediaStoreSaver.save(
                context = applicationContext,
                fileName = info.fileName,
                mimeType = info.mimeType,
                kind = info.kind,
                source = partFile,
                ensureActive = ::ensureRunning,
                onProgress = { copied, total ->
                    val now = System.currentTimeMillis()
                    if (now - lastSaveUpdate >= PROGRESS_INTERVAL_MS) {
                        lastSaveUpdate = now
                        Notifications.updateProgress(
                            applicationContext, job, copied, total, saving = true,
                        )
                    }
                },
                onPublish = { uri, publish ->
                    // Publication and completion share the store lock with
                    // cancel/remove: only one terminal outcome can win.
                    job = updateActive(store, jobId, generation) {
                        workerContext.ensureActive()
                        if (isStopped) throw CancellationException()
                        publish()
                        it.copy(
                            status = JobStatus.COMPLETED,
                            remoteId = uri.toString(),
                            bytesReceived = result.bytesWritten,
                            error = null,
                            updatedAt = System.currentTimeMillis(),
                        )
                    }
                },
            )

            Notifications.result(applicationContext, job, success = true)
            Notifications.cancel(applicationContext, jobId)
            return Result.success()
        } catch (error: Throwable) {
            val latest = store.get(jobId)
            if (error is CancellationException || isStopped || !workerContext.isActive ||
                latest == null || !latest.isActive || latest.generation != generation
            ) {
                // WorkManager also stops workers for lost constraints. Explicit
                // cancellation is already persisted by the repository; do not
                // turn a system pause into a user cancellation.
                requeue(store, jobId, generation, partFile)
                if (error is CancellationException) throw error
                throw CancellationException("Download stopped.").apply { initCause(error) }
            }
            val retryable = error is IOException &&
                (error !is HttpStatusException ||
                    error.code == 408 || error.code == 429 || error.code >= 500)
            if (retryable && runAttemptCount < MAX_ATTEMPTS) {
                requeue(store, jobId, generation, partFile)
                return Result.retry()
            }
            val message = when (error) {
                is LinkText.LinkException -> error.message ?: "That link could not be saved."
                is HttpStatusException -> if (retryable) {
                    "The server is not responding right now. Tap Try again."
                } else {
                    "The server refused the download (HTTP ${error.code})."
                }
                is IOException ->
                    "The download was interrupted. Check your connection and try again."
                else -> error.message ?: "The download failed."
            }
            markFailed(store, jobId, generation, message)
            return Result.failure()
        } finally {
            engine.cancel()
            val latest = store.get(jobId)
            if (latest == null || latest.generation != generation || !latest.isActive) {
                DownloadEngine.discardPartial(partFile)
                partFile.parentFile?.delete()
            }
        }
    }

    private fun updateActive(
        store: JobStore,
        jobId: String,
        generation: Long,
        transform: (Job) -> Job,
    ): Job = store.update(jobId) {
        if (!it.isActive || it.generation != generation) null else transform(it)
    } ?: throw CancellationException()

    private fun requeue(store: JobStore, jobId: String, generation: Long, partFile: File) {
        store.update(jobId) {
            if (!it.isActive || it.generation != generation) return@update null
            it.copy(
                status = JobStatus.QUEUED,
                bytesReceived = partFile.length(),
                error = null,
                updatedAt = System.currentTimeMillis(),
            )
        }
        if (store.get(jobId)?.generation == generation) {
            Notifications.cancel(applicationContext, jobId)
        }
    }

    private fun markFailed(store: JobStore, jobId: String, generation: Long, message: String) {
        val failed = store.update(jobId) {
            if (!it.isActive || it.generation != generation) return@update null
            it.copy(
                status = JobStatus.FAILED,
                error = message,
                updatedAt = System.currentTimeMillis(),
            )
        } ?: return
        Notifications.result(applicationContext, failed, success = false)
        Notifications.cancel(applicationContext, jobId)
    }

    private suspend fun trySetForeground(
        job: Job,
        received: Long,
        total: Long,
        saving: Boolean = false,
    ) {
        val notification = Notifications.progress(
            applicationContext,
            job,
            received,
            total,
            saving,
        )
        try {
            setForeground(
                ForegroundInfo(
                    Notifications.progressId(job.id),
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                ),
            )
        } catch (canceled: CancellationException) {
            throw canceled
        } catch (_: Exception) {
            // WorkManager can reject foreground promotion in restricted states.
        }
    }

    companion object {
        private class ExecutionLock {
            val mutex = Mutex()
            var users = 0
        }

        private val executionLocks = mutableMapOf<String, ExecutionLock>()

        private suspend fun <T> withExecutionLock(id: String, action: suspend () -> T): T {
            val execution = synchronized(executionLocks) {
                executionLocks.getOrPut(id) { ExecutionLock() }.also { it.users++ }
            }
            try {
                return execution.mutex.withLock { action() }
            } finally {
                synchronized(executionLocks) {
                    if (--execution.users == 0) executionLocks.remove(id)
                }
            }
        }

        const val KEY_JOB_ID = "job_id"
        const val KEY_GENERATION = "generation"
        private const val PROGRESS_INTERVAL_MS = 400L
        private const val MAX_ATTEMPTS = 3
        val BACKOFF_DELAY_SECONDS = TimeUnit.SECONDS.toSeconds(10)
    }
}

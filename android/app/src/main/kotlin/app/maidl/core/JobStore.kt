package app.maidl.core

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Durable queue/history. One JSON blob in SharedPreferences keeps the job list
 * small (downloads themselves live in MediaStore) and readable after process
 * death, which is what makes share-initiated downloads survive the app closing.
 */
class JobStore private constructor(private val prefs: SharedPreferences) {
    private val listeners = CopyOnWriteArrayList<() -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()

    fun list(): List<Job> = synchronized(lock) { read() }
        .sortedWith(compareByDescending<Job> { it.isActive }.thenByDescending { it.createdAt })

    fun get(id: String): Job? = synchronized(lock) { read().firstOrNull { it.id == id } }

    fun activeDuplicate(url: String): Job? =
        synchronized(lock) { read().firstOrNull { it.isActive && it.url == url } }

    fun put(job: Job) {
        synchronized(lock) {
            val jobs = read().filterNot { it.id == job.id }.toMutableList()
            jobs.add(job)
            write(jobs)
        }
        notifyChanged()
    }

    /** Atomically changes an existing record; null leaves it untouched. */
    fun update(id: String, transform: (Job) -> Job?): Job? {
        val updated = synchronized(lock) {
            val jobs = read()
            val index = jobs.indexOfFirst { it.id == id }
            if (index < 0) return@synchronized null
            val next = transform(jobs[index]) ?: return@synchronized null
            jobs[index] = next
            write(jobs)
            next
        }
        if (updated != null) notifyChanged()
        return updated
    }

    fun remove(id: String) {
        synchronized(lock) {
            val jobs = read().filterNot { it.id == id }.toMutableList()
            write(jobs)
        }
        notifyChanged()
    }

    fun clearFinished() {
        synchronized(lock) {
            val jobs = read().filter { it.isActive }.toMutableList()
            write(jobs)
        }
        notifyChanged()
    }

    fun addListener(listener: () -> Unit) {
        listeners.addIfAbsent(listener)
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    fun notifyChanged() {
        if (listeners.isEmpty()) return
        mainHandler.post {
            listeners.forEach { listener ->
                runCatching { listener() }
            }
        }
    }

    private fun read(): MutableList<Job> {
        val raw = prefs.getString(KEY, null) ?: return mutableListOf()
        return runCatching {
            val array = JSONArray(raw)
            val jobs = mutableListOf<Job>()
            for (index in 0 until array.length()) {
                array.optJSONObject(index)?.let { Job.fromJson(it)?.let(jobs::add) }
            }
            jobs
        }.getOrElse { mutableListOf() }
    }

    private fun write(jobs: List<Job>) {
        // commit() (not apply()) so a share that queues a job and immediately
        // finishes the relay activity cannot lose the record.
        prefs.edit().putString(KEY, Job.listToJson(jobs).toString()).commit()
    }

    companion object {
        private const val PREFS = "maidl_jobs_v1"
        private const val KEY = "jobs"

        @Volatile
        private var instance: JobStore? = null

        fun get(context: Context): JobStore =
            instance ?: synchronized(this) {
                instance ?: JobStore(
                    context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
                ).also { instance = it }
            }
    }
}

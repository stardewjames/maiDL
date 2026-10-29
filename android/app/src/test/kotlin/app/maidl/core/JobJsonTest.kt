package app.maidl.core

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JobJsonTest {

    private fun sample() = Job(
        id = "abc",
        url = "https://x.dev/a.mp4",
        kind = MediaKind.VIDEO,
        fileName = "a.mp4",
        status = JobStatus.DOWNLOADING,
        origin = JobOrigin.SHARE,
        createdAt = 1_700_000_000_000L,
        updatedAt = 1_700_000_005_000L,
        bytesReceived = 512,
        totalBytes = 1024,
        error = null,
        remoteId = null,
        mimeType = "video/mp4",
        generation = 4,
    )

    @Test
    fun roundTripsEveryField() {
        val restored = Job.fromJson(sample().toJson())
        assertEquals(sample(), restored)
    }

    @Test
    fun roundTripsTerminalStateWithRemoteId() {
        val completed = sample().copy(
            status = JobStatus.COMPLETED,
            remoteId = "content://media/external/video/media/42",
            error = null,
        )
        assertEquals(completed, Job.fromJson(completed.toJson()))
    }

    @Test
    fun keepsErrorTextForFailedJobs() {
        val failed = sample().copy(status = JobStatus.FAILED, error = "HTTP 404")
        val restored = Job.fromJson(failed.toJson())
        assertEquals("HTTP 404", restored?.error)
        assertEquals(JobStatus.FAILED, restored?.status)
    }

    @Test
    fun rejectsIncompleteJson() {
        assertNull(Job.fromJson(org.json.JSONObject("""{"url":"https://x.dev/a.mp4"}""")))
        assertNull(Job.fromJson(org.json.JSONObject("""{"id":"abc"}""")))
    }

    @Test
    fun defaultsUnknownEnumsToSafeValues() {
        val job = Job.fromJson(
            org.json.JSONObject(
                """{"id":"a","url":"https://x.dev/a.png","status":"bogus","kind":"bogus","origin":"bogus"}""",
            ),
        )
        assertEquals(JobStatus.QUEUED, job?.status)
        assertEquals(MediaKind.UNKNOWN, job?.kind)
        assertEquals(JobOrigin.MANUAL, job?.origin)
    }

    @Test
    fun restoresExistingJobsWithoutAnExecutionGeneration() {
        val json = sample().toJson()
        json.remove("generation")
        assertEquals(0L, Job.fromJson(json)?.generation)
    }

    @Test
    fun serialisesListsForTheStore() {
        val array: JSONArray = Job.listToJson(listOf(sample(), sample().copy(id = "def")))
        assertEquals(2, array.length())
        assertTrue(array.getJSONObject(0).has("mimeType"))
        assertFalse(array.getJSONObject(0).isNull("id"))
    }
}

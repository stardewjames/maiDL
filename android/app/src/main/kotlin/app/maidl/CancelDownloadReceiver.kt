package app.maidl

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class CancelDownloadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(EXTRA_JOB_ID) ?: return
        DownloadRepository.get(context).cancel(id)
    }

    companion object {
        const val EXTRA_JOB_ID = "job_id"
    }
}

package app.maidl.core

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.IOException

/**
 * Publishes a finished file into MediaStore so library-supported formats can
 * show up in the gallery and other MediaStore consumers.
 *
 * The row stays pending until the copy completes: a crash mid-write cannot
 * leave a half-video visible in the user's library.
 */
object MediaStoreSaver {

    fun save(
        context: Context,
        fileName: String,
        mimeType: String,
        kind: MediaKind,
        source: File,
        ensureActive: () -> Unit,
        onProgress: (copied: Long, total: Long) -> Unit,
        onPublish: (uri: Uri, publish: () -> Unit) -> Unit,
    ): Uri {
        ensureActive()
        val collection = when (kind) {
            MediaKind.VIDEO -> MediaStore.Video.Media.getContentUri(
                MediaStore.VOLUME_EXTERNAL_PRIMARY,
            )
            MediaKind.IMAGE -> MediaStore.Images.Media.getContentUri(
                MediaStore.VOLUME_EXTERNAL_PRIMARY,
            )
            MediaKind.UNKNOWN -> throw IllegalArgumentException("Unknown media kind")
        }
        val relativePath = when (kind) {
            MediaKind.VIDEO -> "${Environment.DIRECTORY_MOVIES}/maiDL"
            else -> "${Environment.DIRECTORY_PICTURES}/maiDL"
        }
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IOException("Could not create an entry in your library.")

        try {
            val total = source.length()
            ensureActive()
            var copied = 0L
            val output = resolver.openOutputStream(uri, "w")
                ?: throw IOException("Could not write to your library.")
            output.use { sink ->
                source.inputStream().use { input ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        ensureActive()
                        val read = input.read(buffer)
                        ensureActive()
                        if (read == -1) break
                        sink.write(buffer, 0, read)
                        copied += read
                        onProgress(copied, total)
                    }
                }
                sink.flush()
            }
            if (copied != total) {
                throw IOException("Incomplete copy into the library.")
            }
            ensureActive()
            onPublish(uri) {
                if (resolver.update(
                        uri,
                        ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                        null,
                        null,
                    ) != 1
                ) {
                    throw IOException("Could not publish the entry in your library.")
                }
            }
            return uri
        } catch (error: Throwable) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }
}

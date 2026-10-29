package pk.mpl.mpl

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Size
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Native media access for the Dart layer. Everything here is read-only with
 * respect to the user's audio: files are never moved, renamed, copied or
 * deleted. Heavy work runs on a background executor so playback and the UI
 * thread are never blocked.
 */
class MediaBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val io = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private var pendingPick: MethodChannel.Result? = null
    private var pendingTree: MethodChannel.Result? = null

    companion object {
        private const val REQ_PICK_DOCS = 7101
        private const val REQ_PICK_TREE = 7102
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "queryMediaStore" -> background(result) {
                queryMediaStore((call.argument<Number>("minDurationMs") ?: 0).toLong())
            }
            "pickAudioDocuments" -> pickDocuments(result)
            "pickFolder" -> pickFolder(result)
            "listTree" -> background(result) { listTree(Uri.parse(call.argument<String>("uri")!!)) }
            "describeDocuments" -> background(result) {
                call.argument<List<String>>("uris")!!.map { u ->
                    try { describeDocument(Uri.parse(u), null) } catch (_: Exception) { null }
                }
            }
            "releaseUri" -> background(result) { releaseUri(call.argument<String>("uri")!!); true }
            "checkAccessible" -> background(result) {
                call.argument<List<String>>("uris")!!.map { isAccessible(it) }
            }
            "readMetadata" -> background(result) {
                readMetadata(call.argument<String>("uri")!!, call.argument<String>("artworkPath"))
            }
            "decodePcm" -> background(result) {
                AudioDecoder(activity).decode(
                    call.argument<String>("uri")!!,
                    (call.argument<Number>("offsetMs") ?: 0).toLong(),
                    (call.argument<Number>("durationMs") ?: 0).toLong(),
                )
            }
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error(e.javaClass.simpleName, e.message ?: e.toString(), null) }
            }
        }
    }

    // ---------------------------------------------------------------- MediaStore

    private fun queryMediaStore(minDurationMs: Long): List<Map<String, Any?>> {
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }
        val cols = mutableListOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DATE_MODIFIED,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.MIME_TYPE,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) cols += MediaStore.Audio.Media.RELATIVE_PATH
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) cols += MediaStore.Audio.Media.GENRE
        // Exclude system sounds; keep music, podcasts and other recordings.
        val selection = "${MediaStore.Audio.Media.IS_RINGTONE} = 0 AND " +
            "${MediaStore.Audio.Media.IS_NOTIFICATION} = 0 AND " +
            "${MediaStore.Audio.Media.IS_ALARM} = 0 AND " +
            "${MediaStore.Audio.Media.DURATION} >= ?"
        val out = ArrayList<Map<String, Any?>>()
        activity.contentResolver.query(
            collection, cols.toTypedArray(), selection, arrayOf(minDurationMs.toString()), null,
        )?.use { c ->
            fun str(col: String) = c.getColumnIndex(col).let { if (it < 0 || c.isNull(it)) null else c.getString(it) }
            fun lng(col: String) = c.getColumnIndex(col).let { if (it < 0 || c.isNull(it)) null else c.getLong(it) }
            while (c.moveToNext()) {
                val id = lng(MediaStore.Audio.Media._ID) ?: continue
                val uri = ContentUris.withAppendedId(collection, id)
                out += mapOf(
                    "sourceId" to "ms:$id",
                    "uri" to uri.toString(),
                    "sourceType" to "mediastore",
                    "displayName" to str(MediaStore.Audio.Media.DISPLAY_NAME),
                    "title" to str(MediaStore.Audio.Media.TITLE),
                    "artist" to str(MediaStore.Audio.Media.ARTIST)?.takeIf { it != MediaStore.UNKNOWN_STRING },
                    "album" to str(MediaStore.Audio.Media.ALBUM),
                    "genre" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) str(MediaStore.Audio.Media.GENRE) else null,
                    "durationMs" to lng(MediaStore.Audio.Media.DURATION),
                    "size" to lng(MediaStore.Audio.Media.SIZE),
                    "dateModifiedMs" to (lng(MediaStore.Audio.Media.DATE_MODIFIED) ?: 0L) * 1000L,
                    "dateAddedMs" to (lng(MediaStore.Audio.Media.DATE_ADDED) ?: 0L) * 1000L,
                    "folder" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) str(MediaStore.Audio.Media.RELATIVE_PATH) else null,
                    "mimeType" to str(MediaStore.Audio.Media.MIME_TYPE),
                )
            }
        }
        return out
    }

    // ---------------------------------------------------------------- Storage Access Framework

    private fun pickDocuments(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A picker is already open", null); return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "audio/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        activity.startActivityForResult(intent, REQ_PICK_DOCS)
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingTree != null) {
            result.error("busy", "A picker is already open", null); return
        }
        pendingTree = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        activity.startActivityForResult(intent, REQ_PICK_TREE)
    }

    fun onActivityResult(requestCode: Int, ok: Boolean, data: Intent?) {
        when (requestCode) {
            REQ_PICK_DOCS -> {
                val result = pendingPick ?: return
                pendingPick = null
                if (!ok || data == null) { result.success(emptyList<Any>()); return }
                val uris = mutableListOf<Uri>()
                data.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris += clip.getItemAt(i).uri }
                data.data?.let { if (it !in uris) uris += it }
                background(result) {
                    uris.mapNotNull { uri ->
                        persist(uri)
                        describeDocument(uri, null)
                    }
                }
            }
            REQ_PICK_TREE -> {
                val result = pendingTree ?: return
                pendingTree = null
                val uri = data?.data
                if (!ok || uri == null) { result.success(null); return }
                persist(uri)
                result.success(uri.toString())
            }
        }
    }

    private fun persist(uri: Uri) {
        try {
            activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) {
            // Provider does not offer persistable grants; access lasts for this session only.
        }
    }

    private fun releaseUri(uri: String) {
        try {
            activity.contentResolver.releasePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) {
        }
    }

    private fun describeDocument(uri: Uri, folder: String?): Map<String, Any?>? {
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        activity.contentResolver.query(uri, cols, null, null, null)?.use { c ->
            if (!c.moveToFirst()) return null
            return mapOf(
                "sourceId" to "saf:$uri",
                "uri" to uri.toString(),
                "sourceType" to "saf",
                "displayName" to c.getString(0),
                "size" to if (c.isNull(1)) null else c.getLong(1),
                "dateModifiedMs" to if (c.isNull(2)) 0L else c.getLong(2),
                "mimeType" to c.getString(3),
                "folder" to folder,
            )
        }
        return null
    }

    private fun listTree(treeUri: Uri): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val stack = ArrayDeque<Pair<String, String>>()
        stack.add(rootId to "")
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        while (stack.isNotEmpty()) {
            val (docId, path) = stack.removeLast()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
            activity.contentResolver.query(children, cols, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    val name = c.getString(1) ?: ""
                    val mime = c.getString(2) ?: ""
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        stack.add(id to "$path$name/")
                    } else if (mime.startsWith("audio/")) {
                        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                        out += mapOf(
                            "sourceId" to "saf:$uri",
                            "uri" to uri.toString(),
                            "sourceType" to "saf",
                            "displayName" to name,
                            "size" to if (c.isNull(3)) null else c.getLong(3),
                            "dateModifiedMs" to if (c.isNull(4)) 0L else c.getLong(4),
                            "mimeType" to mime,
                            "folder" to path,
                        )
                    }
                }
            }
        }
        return out
    }

    private fun isAccessible(uri: String): Boolean {
        if (!uri.startsWith("content://")) return File(uri.removePrefix("file://")).canRead()
        return try {
            activity.contentResolver.openFileDescriptor(Uri.parse(uri), "r")?.use { true } ?: false
        } catch (_: Exception) {
            false
        }
    }

    // ---------------------------------------------------------------- Metadata

    private fun readMetadata(uri: String, artworkPath: String?): Map<String, Any?> {
        val r = MediaMetadataRetriever()
        try {
            if (uri.startsWith("content://")) r.setDataSource(activity, Uri.parse(uri))
            else r.setDataSource(uri.removePrefix("file://"))
            var artworkWritten = false
            if (artworkPath != null) {
                val bytes = r.embeddedPicture
                if (bytes != null && bytes.isNotEmpty()) {
                    FileOutputStream(File(artworkPath)).use { it.write(bytes) }
                    artworkWritten = true
                } else if (uri.startsWith("content://") && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    try {
                        val bmp = activity.contentResolver.loadThumbnail(Uri.parse(uri), Size(512, 512), null)
                        FileOutputStream(File(artworkPath)).use {
                            bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, it)
                        }
                        artworkWritten = true
                    } catch (_: Exception) {
                    }
                }
            }
            return mapOf(
                "title" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE),
                "artist" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST),
                "album" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM),
                "albumArtist" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST),
                "genre" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_GENRE),
                "durationMs" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull(),
                "artworkWritten" to artworkWritten,
            )
        } finally {
            r.release()
        }
    }
}

package com.igor.caldo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * The files and photos attached to tasks (`services/attachments.dart`).
 *
 * Whatever is picked is copied into [dir], and the task keeps the copy's
 * path there: a picked document's link lasts only as long as the grant that
 * came with it, and the original can be moved or deleted from under it.
 * Each copy is in a folder of its own under the name it came with, since
 * that name is what an app it is opened in shows, and what it shares it as;
 * the copy named by a UUID was opened as "0a89f043-be94-…". Photos
 * come from the system's photo picker, which needs no permission; files
 * from the document picker, which reaches Drive as readily as Downloads; a
 * photo taken there and then from the camera app, which is handed a file
 * of ours to write into. Caldo asks for no camera permission, and an app
 * that does not declare it may start the camera app without it.
 *
 * Opening one hands it to whatever app reads its type, through a
 * [FileProvider] that serves [dir] and nothing else.
 */
class Attachments(private val activity: Activity) {
    /** The pick waiting on a picker, and where the camera is writing. */
    private var answer: MethodChannel.Result? = null
    private var shot: File? = null

    val dir: File
        get() = File(activity.filesDir, DIR).apply { mkdirs() }

    fun call(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "dir" -> result.success(dir.absolutePath)
            "pick" -> pick(call.argument<String>("from")!!, result)
            "open" -> result.success(
                open(call.argument<String>("file")!!, call.argument<String>("mime")!!),
            )
            else -> result.notImplemented()
        }
    }

    private fun pick(from: String, result: MethodChannel.Result) {
        answer?.success(null)
        answer = result
        val intent = when (from) {
            "camera" -> {
                val file = place(photoName())
                shot = file
                Intent(MediaStore.ACTION_IMAGE_CAPTURE)
                    .putExtra(MediaStore.EXTRA_OUTPUT, uriOf(file))
                    .addFlags(
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
            }
            // The photo picker from Android 13; before it, the document
            // picker narrowed to images, which is what the photo picker
            // grew out of. Photos only: left to itself it offers videos as
            // well, which would come back as files under "Photo".
            "photos" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                Intent(MediaStore.ACTION_PICK_IMAGES)
                    .setType("image/*")
                    .putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, MediaStore.getPickImagesMaxLimit())
            } else {
                documents("image/*")
            }
            else -> documents("*/*")
        }
        val code = if (from == "camera") TAKE else PICK
        try {
            activity.startActivityForResult(intent, code)
        } catch (_: ActivityNotFoundException) {
            shot = null
            answer = null
            result.success(null)
        }
    }

    private fun documents(type: String) =
        Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(type)
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)

    /** Takes a picker's answer; false if the request was not one of ours. */
    fun answered(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK && requestCode != TAKE) return false
        val result = answer ?: return true
        val taken = shot
        answer = null
        shot = null
        if (resultCode != Activity.RESULT_OK) {
            taken?.parentFile?.deleteRecursively()
            result.success(null)
            return true
        }
        // Off the main thread: a picked file may be on Drive, or a film.
        Thread {
            val attached = mutableListOf<Map<String, Any>>()
            val tooBig = mutableListOf<String>()
            if (requestCode == TAKE) {
                if (taken != null && taken.length() > 0) {
                    attached.add(entry(taken, taken.name, "image/jpeg"))
                } else {
                    taken?.parentFile?.deleteRecursively()
                }
            } else {
                for (uri in urisOf(data)) {
                    try {
                        copy(uri, attached, tooBig)
                    } catch (_: Exception) {
                        // One that cannot be read is left out; the rest go in.
                    }
                }
            }
            activity.runOnUiThread {
                result.success(mapOf("attached" to attached, "tooBig" to tooBig))
            }
        }.start()
        return true
    }

    private fun urisOf(data: Intent?): List<Uri> {
        val clip = data?.clipData
        if (clip != null) return (0 until clip.itemCount).map { clip.getItemAt(it).uri }
        return listOfNotNull(data?.data)
    }

    /**
     * Copies [uri] into [dir]. Anything over [LIMIT] is left where it is:
     * one picked by mistake can be a film, and a copy is kept for as long
     * as the task is.
     */
    private fun copy(uri: Uri, attached: MutableList<Map<String, Any>>, tooBig: MutableList<String>) {
        val resolver = activity.contentResolver
        var name: String? = null
        var size = -1L
        resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { c ->
            if (c.moveToFirst()) {
                if (!c.isNull(0)) name = c.getString(0)
                if (!c.isNull(1)) size = c.getLong(1)
            }
        }
        val shown = name ?: uri.lastPathSegment ?: "file"
        if (size > LIMIT) {
            tooBig.add(shown)
            return
        }
        val ext = MimeTypeMap.getFileExtensionFromUrl(Uri.encode(shown))
            .ifEmpty { shown.substringAfterLast('.', "") }
            .lowercase()
        val mime = resolver.getType(uri)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
        val target = place(shown)
        var written = 0L
        resolver.openInputStream(uri)!!.use { input ->
            target.outputStream().use { out ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    written += n
                    // A size the provider did not report is found out here.
                    if (written > LIMIT) break
                    out.write(buffer, 0, n)
                }
            }
        }
        if (written > LIMIT) {
            target.parentFile?.deleteRecursively()
            tooBig.add(shown)
            return
        }
        attached.add(entry(target, shown, mime))
    }

    /** Where a copy of [name] goes: a folder of its own, under that name. */
    private fun place(name: String): File {
        val safe = name.map { if (it in "/\\\u0000") '_' else it }
            .joinToString("").trim().ifEmpty { "file" }.take(120)
        return File(File(dir, UUID.randomUUID().toString()).apply { mkdirs() }, safe)
    }

    private fun entry(file: File, name: String, mime: String): Map<String, Any> =
        mapOf(
            "file" to file.relativeTo(dir).path,
            "name" to name,
            "mime" to mime,
            "size" to file.length(),
        )

    /** A photo taken from the camera is named as the camera app would. */
    private fun photoName() =
        "IMG_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + ".jpg"

    private fun open(name: String, mime: String): Boolean {
        val file = File(dir, name)
        if (!file.exists()) return false
        return try {
            // The provider refuses anything outside the attachments.
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uriOf(file), mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: IllegalArgumentException) {
            false
        }
    }

    private fun uriOf(file: File): Uri =
        FileProvider.getUriForFile(activity, "${activity.packageName}.files", file)

    private companion object {
        const val DIR = "attachments"
        const val PICK = 10
        const val TAKE = 11
        const val LIMIT = 100L * 1024 * 1024
    }
}

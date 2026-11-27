package com.igor.caldo

import android.Manifest.permission
import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.util.Size
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/** A read-only view of the images Android lets the chat picker see. */
class AttachmentGallery(
    private val activity: Activity,
    private val copy: (List<Uri>, MethodChannel.Result) -> Unit,
) {
    private var asking: MethodChannel.Result? = null

    fun call(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "galleryPage" -> {
                val offset = call.argument<Int>("offset") ?: 0
                read(result) { page(offset) }
            }
            "galleryAccess" -> requestAccess(result)
            "galleryThumbnail" -> {
                val id = call.argument<String>("id")?.toLongOrNull()
                val side = (call.argument<Int>("side") ?: 256).coerceIn(1, 384)
                read(result) { id?.let { thumbnail(it, side) } }
            }
            "galleryPick" -> {
                val ids = call.argument<List<String>>("ids").orEmpty()
                copy(ids.mapNotNull { it.toLongOrNull()?.let(::uriOf) }, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun requestAccess(result: MethodChannel.Result) {
        if (asking != null || access() == "full" || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(null)
            return
        }
        val permissions = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
                arrayOf(permission.READ_MEDIA_IMAGES, permission.READ_MEDIA_VISUAL_USER_SELECTED)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
                arrayOf(permission.READ_MEDIA_IMAGES)
            else -> arrayOf(permission.READ_EXTERNAL_STORAGE)
        }
        asking = result
        activity.requestPermissions(permissions, REQUEST)
    }

    fun permissionAnswered(requestCode: Int): Boolean {
        if (requestCode != REQUEST) return false
        val result = asking
        asking = null
        result?.success(null)
        return true
    }

    private fun allowed(name: String) =
        activity.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED

    private fun access(): String = when {
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q -> "unsupported"
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ->
            if (allowed(permission.READ_EXTERNAL_STORAGE)) "full" else "none"
        allowed(permission.READ_MEDIA_IMAGES) -> "full"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            allowed(permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "partial"
        else -> "none"
    }

    private fun page(offset: Int): Map<String, Any> {
        val access = access()
        val photos = mutableListOf<Map<String, String>>()
        if (access == "full" || access == "partial") {
            val images = MediaStore.Images.Media
                .getContentUri(MediaStore.VOLUME_EXTERNAL)
            val fields = arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.DATE_ADDED,
            )
            val args = Bundle().apply {
                putStringArray(
                    ContentResolver.QUERY_ARG_SORT_COLUMNS,
                    arrayOf(MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media._ID),
                )
                putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
                putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
                putInt(ContentResolver.QUERY_ARG_LIMIT, PAGE_SIZE + 1)
            }
            activity.contentResolver.query(images, fields, args, null)?.use { cursor ->
                while (photos.size <= PAGE_SIZE && cursor.moveToNext()) {
                    photos.add(mapOf("id" to cursor.getLong(0).toString(), "name" to cursor.getString(1).orEmpty()))
                }
            }
        }
        return mapOf("access" to access, "photos" to photos.take(PAGE_SIZE), "more" to (photos.size > PAGE_SIZE))
    }

    private fun uriOf(id: Long) =
        ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)

    private fun thumbnail(id: Long, side: Int): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        if (access() == "none") return null
        val image = activity.contentResolver.loadThumbnail(uriOf(id), Size(side, side), null)
        return try {
            ByteArrayOutputStream().use { out ->
                if (image.compress(Bitmap.CompressFormat.JPEG, 85, out)) out.toByteArray() else null
            }
        } finally {
            image.recycle()
        }
    }

    private fun read(result: MethodChannel.Result, action: () -> Any?) {
        reads.execute {
            val value = try {
                action()
            } catch (_: Exception) {
                // Access or a photo can disappear while the sheet is open.
                null
            }
            activity.runOnUiThread { result.success(value) }
        }
    }

    companion object {
        private const val REQUEST = 12
        private const val PAGE_SIZE = 60
        private val reads = Executors.newFixedThreadPool(2)
    }
}

package com.igor.caldo

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.view.Choreographer
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Settings › Debug's recording (`services/recording.dart`): a video of
 * Caldo and its keyboard and nothing else, for the user to send on with
 * the log Dart writes beside it.
 *
 * The app is copied out of Flutter's own surface ([PixelCopy]) as it
 * draws, so the status bar, notifications, the shade and other apps never
 * reach the video. The keyboard is the system's own window, which only a
 * capture of the screen sees: Android lends the screen (its consent, every
 * time, and [RecordService] holding it in the foreground) and the strip
 * the keyboard takes up — its inset, no more — is laid from that over the
 * app's copy, while Caldo has the focus. A frame is made only after Dart
 * says one was drawn (`drew`) or the screen changed with the keyboard up,
 * at most [FPS] a second, so an idle app costs nothing. At most 1280 on
 * its long side, without sound; one recording is kept, in the cache, and
 * the next clears it.
 */
class ScreenRecord(private val activity: Activity, private val channel: MethodChannel) {
    private var session: Session? = null

    /** The start waiting on the consent and the service. */
    private var answer: MethodChannel.Result? = null

    init {
        // The notification's Stop.
        RecordService.stop = { session?.finish() }
    }

    private val dir: File
        get() = File(activity.cacheDir, DIR).apply { mkdirs() }

    fun call(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> ask(result)
            "drew" -> {
                session?.drew()
                result.success(null)
            }
            "stop" -> {
                session?.finish()
                result.success(null)
            }
            "recording" -> result.success(session != null)
            "files" -> result.success(
                dir.listFiles()?.filter { it.isFile }?.map { it.absolutePath } ?: emptyList<String>(),
            )
            "share" -> result.success(share(call.argument<List<String>>("files")!!))
            "device" -> result.success(device())
            else -> result.notImplemented()
        }
    }

    /** The activity is going: what is recorded so far is kept. */
    fun release() {
        session?.finish()
    }

    private fun ask(result: MethodChannel.Result) {
        if (session != null || answer != null) {
            result.error("running", "Already recording", null)
            return
        }
        answer = result
        val projections = activity.getSystemService(MediaProjectionManager::class.java)
        // The whole display, never one app's: the keyboard is not the app's.
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            projections.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            projections.createScreenCaptureIntent()
        }
        try {
            activity.startActivityForResult(intent, ASK)
        } catch (_: ActivityNotFoundException) {
            answer = null
            result.error("unavailable", "No screen capture on this device", null)
        }
    }

    /** The consent's answer; false if the result was another's. */
    fun answered(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != ASK) return false
        val result = answer ?: return true
        if (resultCode != Activity.RESULT_OK || data == null) {
            answer = null
            result.success(null)
            return true
        }
        RecordService.ready = { projection, problem ->
            activity.runOnUiThread { begin(projection, problem) }
        }
        val service = Intent(activity, RecordService::class.java)
            .putExtra(RecordService.CODE, resultCode)
            .putExtra(RecordService.DATA, data)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(service)
        } else {
            activity.startService(service)
        }
        return true
    }

    private fun begin(projection: MediaProjection?, problem: String?) {
        val result = answer
        answer = null
        if (result == null || projection == null) {
            projection?.stop()
            RecordService.end(activity)
            result?.error("failed", problem ?: "The screen was not handed over", null)
            return
        }
        val view = flutterSurface(activity.window.decorView)
        if (view == null || view.width == 0 || view.height == 0) {
            projection.stop()
            RecordService.end(activity)
            result.error("unavailable", "Nothing drawn to record", null)
            return
        }
        dir.listFiles()?.forEach { it.delete() }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val file = File(dir, "caldo-$stamp.mp4")
        val (width, height) = videoSize(view.width, view.height)
        try {
            val started = Session(activity, view, projection, file, width, height) { kept ->
                session = null
                RecordService.end(activity)
                channel.invokeMethod("stopped", kept)
            }
            session = started
            result.success(
                mapOf(
                    "path" to file.absolutePath,
                    "startedUs" to started.startUs,
                    "width" to width,
                    "height" to height,
                    "fps" to FPS,
                ),
            )
        } catch (e: Exception) {
            projection.stop()
            RecordService.end(activity)
            file.delete()
            result.error("failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /** Flutter's surface: the largest [SurfaceView] in the window. */
    private fun flutterSurface(view: View): SurfaceView? {
        if (view is SurfaceView) return view
        if (view !is ViewGroup) return null
        var best: SurfaceView? = null
        for (i in 0 until view.childCount) {
            val found = flutterSurface(view.getChildAt(i)) ?: continue
            if (best == null || found.width * found.height > best.width * best.height) best = found
        }
        return best
    }

    /**
     * The surface brought within 1280 on its long side and to multiples of
     * 16, which some encoders insist on. The few points the rounding
     * loses are a thin stretch, not a crop.
     */
    private fun videoSize(w: Int, h: Int): Pair<Int, Int> {
        val scale = min(1.0, LONG / max(w, h))
        fun even(v: Int) = max(16, (v * scale).toInt() / 16 * 16)
        return even(w) to even(h)
    }

    /** The recording and its log, handed to whatever the user sends them with. */
    private fun share(files: List<String>): Boolean {
        val uris = ArrayList(
            files.map { FileProvider.getUriForFile(activity, "${activity.packageName}.files", File(it)) },
        )
        if (uris.isEmpty()) return false
        val send = Intent(Intent.ACTION_SEND_MULTIPLE)
            .setType("*/*")
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        // The grant goes with the clip; the extra alone isn't read for one.
        send.clipData = ClipData.newRawUri(null, uris[0]).apply {
            uris.drop(1).forEach { addItem(ClipData.Item(it)) }
        }
        return try {
            activity.startActivity(Intent.createChooser(send, null))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    /** What the log says of the phone it was made on. */
    private fun device(): Map<String, Any> {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        return mapOf(
            "maker" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "android" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "app" to (info.versionName ?: ""),
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
        )
    }

    companion object {
        const val DIR = "recordings"
        private const val ASK = 13
        private const val LONG = 1280.0
        const val FPS = 30
    }
}

/**
 * One recording: copies of Flutter's surface, with the keyboard's strip
 * of the screen over them while it is up, drawn onto an H.264 encoder's
 * own surface and muxed into an MP4 on a thread of its own. Ends on
 * [finish], when the system takes the screen back, or after [MOST_MS].
 */
private class Session(
    private val activity: Activity,
    private val view: SurfaceView,
    private val projection: MediaProjection,
    private val file: File,
    private val width: Int,
    private val height: Int,
    private val done: (String?) -> Unit,
) : Choreographer.FrameCallback {
    private val main = Handler(Looper.getMainLooper())
    private val thread = HandlerThread("Caldo recording").apply { start() }
    private val worker = Handler(thread.looper)
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private val app = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    private val input: Surface

    /** The screen as Android lends it, scaled to the video's size. */
    private val screen = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
    private val display: VirtualDisplay

    /** Flutter's surface's height, which the keyboard's inset is out of. */
    private val surfaceHeight = view.height

    /**
     * When it began, on the monotonic clock in microseconds: the video's
     * nought. Dart's Timeline, pointer events and frame timings read the
     * same clock, so the log lines up with the video.
     */
    val startUs: Long

    // The main thread's.
    private var copying = false
    private var lastCopyNs = 0L
    private var wantedUntilNs = 0L
    private var posted = false
    private var finishing = false

    // Read on the main thread, used on the worker.
    @Volatile private var keyboard = 0
    @Volatile private var focused = true

    // The worker's.
    private var shown: Bitmap? = null
    private var padded: ByteBuffer? = null
    private var track = -1
    private var samples = 0
    private var closed = false
    @Volatile private var ending = false

    private val tooLong = Runnable { finish() }

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
            setInteger(MediaFormat.KEY_FRAME_RATE, ScreenRecord.FPS)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        codec.setCallback(
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    track = muxer.addTrack(format)
                    muxer.start()
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) = written(index, info)

                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) = close()
            },
            worker,
        )
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        input = codec.createInputSurface()
        // Before the display is made, as Android 14 insists: the system's
        // own "stop sharing" ends the recording as Stop does.
        projection.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() = finish()
            },
            main,
        )
        screen.setOnImageAvailableListener({ took(it) }, worker)
        display = projection.createVirtualDisplay(
            "Caldo recording",
            width,
            height,
            activity.resources.displayMetrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            screen.surface,
            null,
            null,
        ) ?: error("No display to mirror the screen into")
        codec.start()
        startUs = System.nanoTime() / 1000
        main.postDelayed(tooLong, MOST_MS)
        // The app as it stands, before anything moves.
        drew()
    }

    /**
     * Something was drawn. Copies follow for a little while after, as a
     * frame is rastered after Dart has said so.
     */
    fun drew() {
        if (finishing) return
        wantedUntilNs = System.nanoTime() + FOLLOW_NS
        if (!posted) {
            posted = true
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    override fun doFrame(frameTimeNanos: Long) {
        posted = false
        if (finishing) return
        val now = System.nanoTime()
        if (now > wantedUntilNs) return
        if (!copying && now - lastCopyNs >= 1_000_000_000L / ScreenRecord.FPS) copy(now)
        posted = true
        Choreographer.getInstance().postFrameCallback(this)
    }

    /**
     * How much of the bottom the keyboard takes, and whether Caldo has the
     * focus: with the shade or another app's window over it, no strip of
     * the screen is let in.
     */
    private fun look() {
        focused = activity.hasWindowFocus()
        keyboard = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val settled = activity.window.decorView.rootWindowInsets
                ?.getInsets(WindowInsets.Type.ime())?.bottom ?: 0
            // While the keys slide, all the room they can take: what is
            // shown there is the screen itself, keys and field alike.
            max(settled, (activity as? MainActivity)?.keysSliding ?: 0)
        } else {
            0
        }
    }

    private fun copy(now: Long) {
        // Gone while Caldo is in the background: the video has a gap.
        if (!view.holder.surface.isValid) return
        look()
        copying = true
        lastCopyNs = now
        try {
            PixelCopy.request(view, app, { result ->
                if (!ending) {
                    // A surface it may not read — the open vault's — is
                    // black, as it is in a screenshot.
                    if (result != PixelCopy.SUCCESS) app.eraseColor(Color.BLACK)
                    compose()
                }
                main.post { copying = false }
            }, worker)
        } catch (_: IllegalArgumentException) {
            copying = false
        }
    }

    /** The app, and the keyboard's strip of the screen over it. */
    private fun compose() {
        val canvas = input.lockHardwareCanvas()
        canvas.drawBitmap(app, 0f, 0f, null)
        val keys = shown
        val inset = keyboard
        if (keys != null && inset > 0 && focused) {
            val strip = (inset.toFloat() / surfaceHeight * height).roundToInt().coerceIn(0, height)
            val bottom = min(keys.height, height)
            canvas.drawBitmap(
                keys,
                Rect(0, bottom - strip, width, bottom),
                Rect(0, height - strip, width, height),
                null,
            )
        }
        input.unlockCanvasAndPost(canvas)
    }

    /** A new picture of the screen, kept for the keyboard's strip. */
    private fun took(reader: ImageReader) {
        val image = try {
            reader.acquireLatestImage()
        } catch (_: IllegalStateException) {
            null
        } ?: return
        try {
            val plane = image.planes[0]
            // Rows may be padded: the bitmap is as wide as a row is long,
            // and only its first [width] columns are drawn.
            val across = plane.rowStride / plane.pixelStride
            val keys = shown?.takeIf { it.width == across && it.height == image.height }
                ?: Bitmap.createBitmap(across, image.height, Bitmap.Config.ARGB_8888)
                    .also { shown = it }
            val needed = plane.rowStride * image.height
            val source = plane.buffer
            val buffer = if (source.remaining() >= needed) {
                source
            } else {
                // The last row may come without its padding.
                val room = padded?.takeIf { it.capacity() >= needed } ?: ByteBuffer.allocate(needed)
                padded = room
                room.clear()
                room.put(source)
                room.rewind()
                room
            }
            keys.copyPixelsFromBuffer(buffer)
        } finally {
            image.close()
        }
        // The keyboard can change with nothing drawn by Flutter.
        if (keyboard > 0) main.post { drew() }
    }

    /** One piece of the encoded video, moved onto the video's clock. */
    private fun written(index: Int, info: MediaCodec.BufferInfo) {
        if (closed) return
        val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
        if (!config && info.size > 0 && track >= 0) {
            val buffer = codec.getOutputBuffer(index)!!
            info.presentationTimeUs = max(0, info.presentationTimeUs - startUs)
            muxer.writeSampleData(track, buffer, info)
            samples++
        }
        codec.releaseOutputBuffer(index, false)
        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) close()
    }

    fun finish() {
        if (finishing) return
        finishing = true
        main.removeCallbacks(tooLong)
        worker.post {
            ending = true
            try {
                codec.signalEndOfInputStream()
            } catch (_: IllegalStateException) {
                close()
            }
        }
        // Should the end of the stream never come out.
        worker.postDelayed({ close() }, 3000)
    }

    private fun close() {
        if (closed) return
        closed = true
        ending = true
        var kept: String? = file.absolutePath
        try {
            muxer.stop()
        } catch (_: IllegalStateException) {
            kept = null
        }
        if (samples == 0) kept = null
        muxer.release()
        codec.release()
        input.release()
        display.release()
        screen.close()
        if (kept == null) file.delete()
        thread.quitSafely()
        main.post {
            projection.stop()
            done(kept)
        }
    }

    companion object {
        private const val BITRATE = 4_000_000
        private const val MOST_MS = 5 * 60 * 1000L
        private const val FOLLOW_NS = 80_000_000L
    }
}

/**
 * Holds the screen while a recording lets the keyboard in: Android 14
 * hands it only to a service in the foreground for it. Started with the
 * consent's answer; its notification's Stop ends the recording.
 */
class RecordService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            stop?.invoke()
            return START_NOT_STICKY
        }
        val ready = ready ?: return START_NOT_STICKY
        RecordService.ready = null
        try {
            // Before the projection is asked for.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else {
                startForeground(ID, notification())
            }
            val data = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent!!.getParcelableExtra(DATA, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent!!.getParcelableExtra(DATA)
            }
            val projection = getSystemService(MediaProjectionManager::class.java)
                .getMediaProjection(intent.getIntExtra(CODE, 0), data!!)
                ?: error("The screen was not handed over")
            ready(projection, null)
        } catch (e: Exception) {
            ready(null, e.message ?: e.javaClass.simpleName)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val notifications = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifications.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Recording", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val stop = PendingIntent.getService(
            this,
            0,
            Intent(this, RecordService::class.java).setAction(STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Recording Caldo")
            .setContentText("Only Caldo and its keyboard are kept")
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_notification),
                    "Stop",
                    stop,
                ).build(),
            )
            .build()
    }

    companion object {
        const val CODE = "code"
        const val DATA = "data"
        private const val STOP = "com.igor.caldo.STOP_RECORDING"
        private const val ID = 7301
        private const val CHANNEL_ID = "recording"

        /** Told once the screen is lent, or why it was not. */
        var ready: ((MediaProjection?, String?) -> Unit)? = null

        /** The notification's Stop. */
        var stop: (() -> Unit)? = null

        fun end(activity: Activity) {
            activity.stopService(Intent(activity, RecordService::class.java))
        }
    }
}

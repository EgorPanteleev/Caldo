package com.igor.caldo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Choreographer
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

/**
 * Settings › Debug's recording (`services/recording.dart`): a video of
 * Caldo and nothing else, for the user to send on with the log Dart
 * writes beside it.
 *
 * Not the screen: what Flutter draws is copied out of its own surface
 * ([PixelCopy]) as it draws it and encoded here, so other apps, the
 * status bar, the system's sheets and the keyboard never reach the video
 * — and Android has nothing to ask, as it would to lend the screen. A
 * frame is copied only after Dart says one was drawn (`drew`), at most
 * [FPS] a second, so an idle app costs nothing. At most 1280 on its long
 * side, without sound; one recording is kept, in the cache, and the next
 * clears it.
 */
class ScreenRecord(private val activity: Activity, private val channel: MethodChannel) {
    private var session: Session? = null

    private val dir: File
        get() = File(activity.cacheDir, DIR).apply { mkdirs() }

    fun call(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result)
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

    private fun start(result: MethodChannel.Result) {
        if (session != null) {
            result.error("running", "Already recording", null)
            return
        }
        val view = flutterSurface(activity.window.decorView)
        if (view == null || view.width == 0 || view.height == 0) {
            result.error("unavailable", "Nothing drawn to record", null)
            return
        }
        dir.listFiles()?.forEach { it.delete() }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val file = File(dir, "caldo-$stamp.mp4")
        val (width, height) = videoSize(view.width, view.height)
        try {
            val started = Session(view, file, width, height) { kept ->
                session = null
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
        private const val LONG = 1280.0
        const val FPS = 30
    }
}

/**
 * One recording: copies of Flutter's surface drawn onto an H.264
 * encoder's own surface, muxed into an MP4 on a thread of its own. Ends
 * on [finish], or after [MOST_MS].
 */
private class Session(
    private val view: SurfaceView,
    private val file: File,
    width: Int,
    height: Int,
    private val done: (String?) -> Unit,
) : Choreographer.FrameCallback {
    private val main = Handler(Looper.getMainLooper())
    private val thread = HandlerThread("Caldo recording").apply { start() }
    private val worker = Handler(thread.looper)
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    private val input: Surface

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

    // The worker's.
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
        codec.start()
        startUs = System.nanoTime() / 1000
        main.postDelayed(tooLong, MOST_MS)
        // The app as it stands, before anything moves.
        drew()
    }

    /**
     * Dart has drawn a frame. Copies follow for a little while after, as
     * the frame is rastered after Dart has said so.
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

    private fun copy(now: Long) {
        // Gone while Caldo is in the background: the video has a gap.
        if (!view.holder.surface.isValid) return
        copying = true
        lastCopyNs = now
        try {
            PixelCopy.request(view, bitmap, { result ->
                if (!ending) {
                    // A surface it may not read — the open vault's — is
                    // black, as it is in a screenshot.
                    if (result != PixelCopy.SUCCESS) bitmap.eraseColor(Color.BLACK)
                    val canvas = input.lockHardwareCanvas()
                    canvas.drawBitmap(bitmap, 0f, 0f, null)
                    input.unlockCanvasAndPost(canvas)
                }
                main.post { copying = false }
            }, worker)
        } catch (_: IllegalArgumentException) {
            copying = false
        }
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
        if (kept == null) file.delete()
        thread.quitSafely()
        main.post { done(kept) }
    }

    companion object {
        private const val BITRATE = 4_000_000
        private const val MOST_MS = 5 * 60 * 1000L
        private const val FOLLOW_NS = 80_000_000L
    }
}

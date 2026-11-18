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
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.min

/**
 * Settings › Debug's screen recording (`services/recording.dart`): a video
 * of the screen, for the user to send on with the log Dart writes beside
 * it. Android's own consent first, every time; then [RecordService], a
 * foreground service, since Android 14 hands a screen over only to one.
 *
 * The video is at most 1920 on its long side and the display's rate up to
 * 60, without sound. Like `screenrecord`, it shows what moved and where,
 * not how smoothly: frame times are in the log. One recording is kept, in
 * the cache; the next one clears it.
 */
class ScreenRecord(private val activity: Activity, private val channel: MethodChannel) {
    /** The start waiting on the consent and the service. */
    private var answer: MethodChannel.Result? = null

    init {
        // Stopped by the notification, the system's own chip, or the
        // length running out as much as by Dart: it hears of each.
        RecordService.stopped = { path ->
            activity.runOnUiThread { channel.invokeMethod("stopped", path) }
        }
    }

    private val dir: File
        get() = File(activity.cacheDir, DIR).apply { mkdirs() }

    fun call(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result)
            "stop" -> {
                if (RecordService.running) {
                    activity.startService(
                        Intent(activity, RecordService::class.java).setAction(RecordService.STOP),
                    )
                }
                result.success(null)
            }
            "recording" -> result.success(RecordService.running)
            "files" -> result.success(
                dir.listFiles()?.filter { it.isFile }?.map { it.absolutePath } ?: emptyList<String>(),
            )
            "share" -> result.success(share(call.argument<List<String>>("files")!!))
            "device" -> result.success(device())
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        if (RecordService.running) {
            result.error("running", "Already recording", null)
            return
        }
        answer?.success(null)
        answer = result
        val projections = activity.getSystemService(MediaProjectionManager::class.java)
        try {
            activity.startActivityForResult(projections.createScreenCaptureIntent(), ASK)
        } catch (_: ActivityNotFoundException) {
            answer = null
            result.error("unavailable", "No screen capture on this device", null)
        }
    }

    /** The consent's answer; false if the result was another's. */
    fun answered(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != ASK) return false
        val result = answer ?: return true
        answer = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(null)
            return true
        }
        dir.listFiles()?.forEach { it.delete() }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val file = File(dir, "caldo-$stamp.mp4")
        val (width, height) = videoSize()
        RecordService.started = { started, problem ->
            activity.runOnUiThread {
                if (started != null) result.success(started) else result.error("failed", problem, null)
            }
        }
        val intent = Intent(activity, RecordService::class.java)
            .putExtra(RecordService.CODE, resultCode)
            .putExtra(RecordService.DATA, data)
            .putExtra(RecordService.PATH, file.absolutePath)
            .putExtra(RecordService.WIDTH, width)
            .putExtra(RecordService.HEIGHT, height)
            .putExtra(RecordService.DPI, activity.resources.displayMetrics.densityDpi)
            .putExtra(RecordService.FPS, min(60, refreshRate().toInt()))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
        return true
    }

    /**
     * The display's size brought within 1920×1080 either way up, which
     * every phone's encoder takes, and to a multiple of 16, which some
     * insist on. The few points lost to the rounding are a thin edge.
     */
    private fun videoSize(): Pair<Int, Int> {
        val (w, h) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = activity.windowManager.currentWindowMetrics.bounds
            bounds.width() to bounds.height()
        } else {
            val metrics = android.util.DisplayMetrics()
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.getRealMetrics(metrics)
            metrics.widthPixels to metrics.heightPixels
        }
        val long = maxOf(w, h).toDouble()
        val short = minOf(w, h).toDouble()
        val scale = min(1.0, min(LONG / long, SHORT / short))
        fun even(v: Int) = (v * scale).toInt() / 16 * 16
        return even(w) to even(h)
    }

    private fun refreshRate(): Float = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        activity.display?.refreshRate ?: 60f
    } else {
        @Suppress("DEPRECATION")
        activity.windowManager.defaultDisplay.refreshRate
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
        private const val LONG = 1920.0
        private const val SHORT = 1080.0
    }
}

/**
 * Holds the screen while it is recorded. Started with the consent's answer;
 * ends on [STOP] — from Dart or the notification's Stop — when the system
 * takes the screen back, or after [MOST_MS].
 */
class RecordService : Service() {
    private var projection: MediaProjection? = null
    private var recorder: MediaRecorder? = null
    private var display: VirtualDisplay? = null
    private var path: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            finish()
            return START_NOT_STICKY
        }
        if (intent == null || running) return START_NOT_STICKY
        try {
            // Before the projection is asked for: Android 14 hands it only
            // to a service already in the foreground for it.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else {
                startForeground(ID, notification())
            }
            begin(intent)
        } catch (e: Exception) {
            release()
            path?.let { File(it).delete() }
            stopSelf()
            started?.invoke(null, e.message ?: e.javaClass.simpleName)
            started = null
        }
        return START_NOT_STICKY
    }

    private fun begin(intent: Intent) {
        val file = intent.getStringExtra(PATH)!!
        path = file
        val width = intent.getIntExtra(WIDTH, 0)
        val height = intent.getIntExtra(HEIGHT, 0)
        val fps = intent.getIntExtra(FPS, 60)
        val data = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(DATA)
        }
        val projections = getSystemService(MediaProjectionManager::class.java)
        val projection = projections.getMediaProjection(intent.getIntExtra(CODE, 0), data!!)
            ?: error("The screen was not handed over")
        this.projection = projection
        // Before the display is made, as Android 14 insists: the system's
        // own "stop sharing" ends the recording as Stop does.
        projection.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() = finish()
            },
            Handler(Looper.getMainLooper()),
        )
        val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(this)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }
        this.recorder = recorder
        recorder.apply {
            setVideoSource(MediaRecorder.VideoSource.SURFACE)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            setVideoSize(width, height)
            setVideoFrameRate(fps)
            setVideoEncodingBitRate(BITRATE)
            setMaxDuration(MOST_MS)
            setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) finish()
            }
            setOutputFile(file)
            prepare()
        }
        display = projection.createVirtualDisplay(
            "Caldo recording",
            width,
            height,
            intent.getIntExtra(DPI, 420),
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            recorder.surface,
            null,
            null,
        )
        recorder.start()
        // On the monotonic clock Dart's Timeline, pointer events and frame
        // timings all read, so the log lines up with the video.
        val at = System.nanoTime() / 1000
        running = true
        started?.invoke(
            mapOf(
                "path" to file,
                "startedUs" to at,
                "width" to width,
                "height" to height,
                "fps" to fps,
            ),
            null,
        )
        started = null
    }

    private fun finish() {
        if (!running) return
        running = false
        var kept = path
        try {
            recorder?.stop()
        } catch (_: RuntimeException) {
            // Stopped before a frame came in: there is no video to keep.
            kept?.let { File(it).delete() }
            kept = null
        }
        release()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        stopped?.invoke(kept)
    }

    private fun release() {
        recorder?.release()
        recorder = null
        display?.release()
        display = null
        projection?.stop()
        projection = null
    }

    private fun notification(): Notification {
        val notifications = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifications.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Screen recording", NotificationManager.IMPORTANCE_LOW),
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
            .setContentTitle("Recording the screen")
            .setContentText("Stop to send it on with its log")
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
        const val STOP = "com.igor.caldo.STOP_RECORDING"
        const val CODE = "code"
        const val DATA = "data"
        const val PATH = "path"
        const val WIDTH = "width"
        const val HEIGHT = "height"
        const val DPI = "dpi"
        const val FPS = "fps"
        private const val ID = 7301
        private const val CHANNEL_ID = "recording"
        private const val BITRATE = 6_000_000
        private const val MOST_MS = 5 * 60 * 1000

        /** Whether the screen is being recorded now. */
        @Volatile
        var running = false

        /** Told once the recording is going, or why it couldn't start. */
        var started: ((Map<String, Any>?, String?) -> Unit)? = null

        /** Told when it ends, with the video, or null if there is none. */
        var stopped: ((String?) -> Unit)? = null
    }
}

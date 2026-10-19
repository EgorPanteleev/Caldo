package com.igor.caldo

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Two things Flutter's stock activity does not do for us.
 *
 * The first is asking for the panel's fastest mode: a window gets 60Hz on a
 * 120Hz screen unless it asks, which is why the app felt like half the
 * refresh rate the phone is capable of. The ask is for the fastest mode *at
 * the resolution already in use* — the list of supported modes mixes
 * resolutions, and taking the fastest of all of them can drop the screen to
 * a coarser one to get there.
 *
 * The second is telling Dart where the keyboard is, in a measurement that
 * means the same thing at every moment of a slide — which `viewInsets` does
 * not. See [send].
 */
class MainActivity : FlutterActivity() {
    private var imeSink: EventChannel.EventSink? = null

    /**
     * How much of the display lies below this window — the navigation bar
     * when the window stops above it, nothing when it is drawn edge to
     * edge. Worked out in [send] from [contentNav].
     */
    private var below = 0

    /**
     * The navigation bar as the content view is told about it: zero when
     * the window fits the system bars, because they have been taken out of
     * the insets before they reach it, and the bar's own height when the
     * window is drawn edge to edge. Negative until it has been told
     * anything.
     */
    private var contentNav = -1

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useFastestRefreshRate()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, IME_CHANNEL)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                        imeSink = sink
                        reportIme()
                    }

                    override fun onCancel(args: Any?) {
                        imeSink = null
                    }
                },
            )
        watchIme()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> result.success(updateInfo())
                    "install" -> result.success(install(call.argument<String>("path")!!))
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * What Dart needs to decide whether a release is newer and which of its
     * files to fetch: the installed version, the processor the files are
     * built for, and the private directory the download is written to.
     */
    private fun updateInfo(): Map<String, Any> {
        val version = packageManager.getPackageInfo(packageName, 0).versionName ?: ""
        val dir = File(cacheDir, "updates").apply { mkdirs() }
        return mapOf(
            "version" to version,
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
            "dir" to dir.absolutePath,
        )
    }

    /**
     * Opens the system installer on a downloaded APK. Android lets an app do
     * that only once the user has said it may install apps; until then the
     * settings page for exactly that is opened instead, and Dart is told so
     * it can say why nothing was installed.
     */
    private fun install(path: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ),
            )
            return "needs-permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
        return "started"
    }

    /**
     * How far the keyboard reaches into this window, in logical pixels.
     *
     * One number, from one place, on every frame of a slide and whenever
     * the insets are applied. `Type.ime()` is measured from the bottom of
     * the display, and the window does not always reach that far: below
     * Android 15 it stops above the navigation bar, which is its own
     * window. What the keys take from us is therefore the keyboard's height
     * less whatever lies between our bottom edge and the display's —
     * nothing at all when the window is drawn edge to edge.
     *
     * This replaced a cleverer thing that sent only what Flutter's own
     * `viewInsets.bottom` was missing, and only while an animation was
     * running. Flutter's number is not one measurement: on an edge-to-edge
     * window it leaves the system bar strip out of a slide's animated
     * values and puts it back at the end, but *which* slides leave it out
     * varies — opening, closing and opening again quickly produced one of
     * each. Correcting a number whose meaning changes needs a flag saying
     * which meaning is in force, and a flag that arrives down one channel
     * while the number arrives down another is a race: it was reported as
     * the field sitting a strip too high for the whole of every other
     * opening, and only when the field was opened and closed quickly.
     * Reporting where the keyboard is cannot race with itself.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun send(insets: WindowInsets) {
        val sink = imeSink ?: return
        val ime = insets.getInsets(WindowInsets.Type.ime()).bottom
        val nav = insets.getInsets(WindowInsets.Type.navigationBars()).bottom
        // Whether this window reaches past the system bars is read from
        // what the bars look like *to the content view*, not from how tall
        // that view happens to be. A window that fits them has them taken
        // out of the insets handed down to it; one drawn edge to edge
        // does not. Nothing about that reading moves with `adjustResize`.
        //
        // It used to be worked out from the content view's height against
        // the display's, and that is what four attempts at one bug came
        // down to: `adjustResize` leaves the view between its two heights
        // for a while after the keys have gone, a reading taken then says
        // the window reaches the bottom of the display when it does not,
        // and once believed it was never contradicted — on this phone no
        // honest reading ever says the opposite, because the honest answer
        // is the default. From then on the keyboard was reported a bar too
        // tall, and the field rode a bar above the keys, for the length of
        // every slide.
        // Until the content view has been handed a set of insets to judge
        // by, assume the window stops above the bars: that under-reports
        // the keyboard on a window that does not, and Dart holds the larger
        // of this and its own number, so an under-report costs nothing
        // while an over-report lifts the bar clear of the keys.
        below = when (contentNav) {
            -1 -> nav
            0 -> nav
            else -> 0
        }
        val off = below
        val reach = (ime - off).coerceAtLeast(0)
        val density = resources.displayMetrics.density
        // The raw figures travel with it, for the numbers a long press puts
        // on screen: a recording of a fault is worth a great deal more when
        // what each side of it believed is written across the top.
        sink.success(
            mapOf(
                "reach" to reach / density,
                "ime" to ime / density,
                "nav" to nav / density,
                "below" to off / density,
            ),
        )
    }

    private fun reportIme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val insets = window.decorView.rootWindowInsets ?: return
        send(insets)
    }

    private fun watchIme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        // Every frame of a slide. Attached to the decor view and passed on
        // through the subtree, so the engine's own inset handling runs
        // exactly as it did — this listens, it does not take over.
        window.decorView.setWindowInsetsAnimationCallback(
            object :
                WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onProgress(
                    insets: WindowInsets,
                    running: MutableList<WindowInsetsAnimation>,
                ): WindowInsets {
                    send(insets)
                    return insets
                }

                override fun onEnd(animation: WindowInsetsAnimation) {
                    reportIme()
                }
            },
        )
        // The animation callback covers the slide; this covers everything
        // else — a rotation, a split-screen resize, a keyboard that appears
        // without animating at all.
        window.decorView.setOnApplyWindowInsetsListener { view: View, insets: WindowInsets ->
            send(insets)
            view.onApplyWindowInsets(insets)
        }
        // What the bars look like by the time they reach the content view,
        // which is how [send] tells a window that fits them from one drawn
        // edge to edge. Passed straight on; this only reads.
        findViewById<View>(android.R.id.content)?.setOnApplyWindowInsetsListener {
            view: View,
            insets: WindowInsets,
            ->
            contentNav = insets.getInsets(WindowInsets.Type.navigationBars()).bottom
            view.onApplyWindowInsets(insets)
        }
        // Once the view tree has been laid out and the insets have been
        // round the houses at least once.
        window.decorView.post { reportIme() }
    }

    @Suppress("DEPRECATION")
    private fun useFastestRefreshRate() {
        val display =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
            else windowManager.defaultDisplay
        val current = display?.mode ?: return
        val fastest = display.supportedModes
            ?.filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            ?.maxByOrNull { it.refreshRate }
            ?: return
        if (fastest.modeId == current.modeId) return
        window.attributes = window.attributes.apply {
            preferredDisplayModeId = fastest.modeId
        }
    }

    private companion object {
        const val IME_CHANNEL = "caldo/ime"
        const val UPDATES_CHANNEL = "caldo/updates"

        /** What a measurement may be out by and still be believed. */
        const val SLACK = 2
    }
}

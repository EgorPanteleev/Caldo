package com.igor.caldo

import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.EventChannel

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

    /** How much of the display lies below this window; see [send]. */
    private var below = 0

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
        // Measured while the keyboard is down, when the content view is at
        // its full height: how much of the display lies below our window.
        // Read during the slide it is unreliable, because `adjustResize` may
        // have shortened the view by then.
        if (ime == 0) {
            val content = findViewById<View>(android.R.id.content)
            if (content != null && content.height > 0) {
                val at = IntArray(2)
                content.getLocationOnScreen(at)
                below = windowManager.currentWindowMetrics.bounds.height() -
                    (at[1] + content.height)
            }
        }
        val reach = (ime - below.coerceAtLeast(0)).coerceAtLeast(0)
        sink.success(reach / resources.displayMetrics.density)
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
        // Once the view tree has been laid out: until then the content view
        // has no height to measure the window against, and a slide that
        // started before the first measurement would be told the strip is
        // ours when it is not.
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
    }
}

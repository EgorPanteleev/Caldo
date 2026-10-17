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
 * The second is telling Dart the one thing about the keyboard that Flutter
 * cannot work out on its own: whether the system bar strip at the foot of
 * the screen is inside this window, and so whether the keyboard covering it
 * is already counted in `viewInsets`. See [send].
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
     * The part of the keyboard that Flutter's `viewInsets.bottom` does not
     * account for while the slide is running, in logical pixels.
     *
     * Flutter's number is how far the keys reach past the system bars. That
     * is the whole story when the window stops above the navigation bar, as
     * it does below Android 15 — the strip is not ours to begin with. Drawn
     * edge to edge, though, the strip *is* inside the window, and the moment
     * the keys cover it Android drops it from `padding.bottom` while the
     * animated inset still leaves it out, so for the length of the slide the
     * app is told some ten points less than the keyboard covers and anything
     * glued to the keyboard rides that much too low. At the end the final
     * inset puts it back in one step — the jump at the end of the slide.
     *
     * So this reports what is missing and when: the system bar strip that
     * lies inside our window, while a slide is running, and nothing at all
     * once it has settled.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun send(insets: WindowInsets, sliding: Boolean) {
        val sink = imeSink ?: return
        val nav = insets.getInsets(WindowInsets.Type.navigationBars()).bottom
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
        val inside = (nav - below.coerceAtLeast(0)).coerceAtLeast(0)
        val missing = if (sliding) inside else 0
        sink.success(missing / resources.displayMetrics.density)
    }

    private fun reportIme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val insets = window.decorView.rootWindowInsets ?: return
        send(insets, sliding = false)
    }

    private fun watchIme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        // While a slide is running, on every frame of it: this is the only
        // way to know the keyboard is moving, and so the only time the
        // correction below is owed. Attached to the decor view and passed on
        // through the subtree, so the engine's own inset handling runs
        // exactly as it did — this listens, it does not take over.
        window.decorView.setWindowInsetsAnimationCallback(
            object :
                WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onProgress(
                    insets: WindowInsets,
                    running: MutableList<WindowInsetsAnimation>,
                ): WindowInsets {
                    send(insets, sliding = true)
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
            send(insets, sliding = false)
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

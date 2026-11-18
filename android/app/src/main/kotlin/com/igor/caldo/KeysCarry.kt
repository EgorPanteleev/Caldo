package com.igor.caldo

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The add field carried on the keyboard by Android, for the length of each
 * of the keyboard's slides (Dart's `KeysCarry`).
 *
 * Flutter draws into a surface of its own, which reaches the screen when its
 * frame is done; the keyboard is another window, which Android moves in step
 * with this window's own frames. However exactly Dart worked out where the
 * keys were (2.11.22–2.11.31), its frame and Android's reached the screen
 * together only some of the time, and the field was a frame ahead of the
 * keys or a frame behind them. A view of this window, moved from a slide's
 * progress, is drawn in the very frame that moves the keyboard: Android
 * applies the two to the screen as one.
 *
 * So Dart hands over a picture of the field whenever it changes while it is
 * up on the keys, and once more before it asks for them. When a slide is
 * prepared the picture goes up over Flutter's view where the field stands,
 * and from then on is drawn at the top of the keys in each frame; Dart
 * leaves its own field
 * undrawn. At rest Dart draws its field again and says so ([drawn]), and a
 * few frames later the picture is put away: the two are in the same place,
 * so the overlap cannot be seen, where a gap between them would be.
 */
class KeysCarry(private val activity: Activity) {
    /** A picture of the field, and where it rests. */
    private class Arm(
        val picture: Bitmap,
        /** Where the picture's left edge is in Flutter's view, px. */
        val left: Float,
        /** Where the field's room ends at rest, px from the view's top. */
        val bottom: Int,
        /** The strip at the foot of the window the field never climbs, px. */
        val reserved: Int,
    )

    /** The picture Dart last handed over, for the next slide. */
    private var armed: Arm? = null

    /** The picture on show, while the field is carried. */
    private var shown: Arm? = null

    /** How far the field is lifted from its rest, px. */
    private var lift = 0

    /** The highest it has been lifted while on show, px. */
    private var highest = 0

    /** Whether a slide is under way. */
    private var sliding = false

    /** Counts hand-backs, so one overtaken by a new slide is let go. */
    private var turn = 0

    /**
     * Whether the picture is put by while the keys finish going. Its lift
     * is nothing once they are into the strip at the window's foot, and
     * they take a while longer to go from there: Dart has the tab bar back
     * as they reach it, so the field is not left standing in its place.
     */
    private var parked = false

    /** Counts parkings, so one called off by the keys coming back is let go. */
    private var parkTurn = 0

    private val view = object : View(activity) {
        override fun onDraw(canvas: Canvas) {
            val arm = shown ?: return
            // The field alone, its foot on the keys: it stands on nothing.
            val foot = (arm.bottom - lift).toFloat()
            canvas.drawBitmap(arm.picture, arm.left, foot - arm.picture.height, null)
        }

        // Never in the way of a finger: what is under it is Flutter's.
        override fun onTouchEvent(event: MotionEvent) = false
    }.apply {
        visibility = View.INVISIBLE
        isClickable = false
        isFocusable = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    /** Puts the view over Flutter's, from the activity's onCreate. */
    fun attach() {
        activity.addContentView(
            view,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    fun call(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "arm" -> {
                armed = read(call) ?: armed
                result.success(null)
            }
            "disarm" -> {
                armed = null
                result.success(null)
            }
            "drawn" -> {
                drawn()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun read(call: MethodCall): Arm? {
        val bytes = call.argument<ByteArray>("picture") ?: return null
        val width = call.argument<Int>("width") ?: return null
        val height = call.argument<Int>("height") ?: return null
        if (width <= 0 || height <= 0 || bytes.size != width * height * 4) return null
        fun number(key: String) = call.argument<Number>(key)?.toFloat() ?: 0f
        // Dart's raw RGBA is premultiplied, as a bitmap's own pixels are,
        // and in the same order of bytes.
        val picture = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        picture.copyPixelsFromBuffer(ByteBuffer.wrap(bytes))
        // Sent to the GPU now rather than in the first frame of a slide.
        picture.prepareToDraw()
        return Arm(
            picture = picture,
            left = number("left"),
            bottom = number("bottom").roundToInt(),
            reserved = number("reserved").roundToInt(),
        )
    }

    private fun liftOf(arm: Arm, reach: Int) = max(0, reach - arm.reserved)

    /**
     * A slide of the keys is about to start, from where they reach now
     * ([reach], px into the window). Whether the field rides it here: if
     * so, it is put up in its place at once, before anything moves.
     */
    fun prepare(reach: Int): Boolean {
        turn++
        parkTurn++
        // The newest picture; else the one on show, if it is: one put by
        // at the foot belongs to keys that have gone.
        val arm = armed ?: shown?.takeIf { !parked }
        if (arm == null) {
            putAway()
            return false
        }
        sliding = true
        if (arm !== shown || parked) {
            shown = arm
            parked = false
            lift = liftOf(arm, reach)
            highest = lift
            view.visibility = View.VISIBLE
        }
        view.invalidate()
        return true
    }

    /**
     * Where the keys reach in this frame of a slide, px into the window.
     * Called from the slide's progress, which Android gives in the frame it
     * moves the keys in, before this window is drawn: the field is drawn on
     * them in that same frame.
     */
    fun follow(reach: Int) {
        val arm = shown ?: return
        val now = liftOf(arm, reach)
        highest = max(highest, now)
        if (now > 0) {
            parkTurn++
            if (parked) {
                parked = false
                view.visibility = View.VISIBLE
            }
        } else if (lift > 0 && sliding) {
            park()
        }
        if (now == lift) return
        lift = now
        view.invalidate()
    }

    /**
     * Puts the picture by a few frames after the field has come down to
     * rest under keys still going, unless they come back first: by then
     * Dart, which reads the same slide, has the tab bar drawn in its place.
     * The picture is still there to go on carrying if the keys come back.
     */
    private fun park() {
        val mine = ++parkTurn
        var left = HAND_BACK_FRAMES
        Choreographer.getInstance().postFrameCallback(
            object : Choreographer.FrameCallback {
                override fun doFrame(frameTimeNanos: Long) {
                    if (mine != parkTurn || lift > 0) return
                    if (--left > 0) {
                        Choreographer.getInstance().postFrameCallback(this)
                        return
                    }
                    parked = true
                    view.visibility = View.INVISIBLE
                }
            },
        )
    }

    private fun putAway() {
        turn++
        parkTurn++
        shown = null
        parked = false
        sliding = false
        view.visibility = View.INVISIBLE
    }

    /** The keys have come to rest, reaching [reach] px into the window. */
    fun settle(reach: Int) {
        if (shown == null) {
            if (reach <= 0) armed = null
            return
        }
        follow(reach)
        sliding = false
        // Gone: the next opening is pictured afresh, and nothing else's
        // keys are taken for the field's.
        if (reach <= 0) armed = null
        // If Dart never says its field is drawn, the picture is not left
        // standing over whatever it types next.
        handBack(LONGEST_FRAMES)
    }

    /** Dart's field is drawn where the picture is: put it away. */
    private fun drawn() {
        if (shown != null && !sliding) handBack(HAND_BACK_FRAMES)
    }

    /**
     * Puts the picture away [frames] frames from now, unless a slide
     * starts first: a few after Dart says it has drawn its field, which
     * is then on the screen by any count, or far later if Dart says
     * nothing.
     */
    private fun handBack(frames: Int) {
        val mine = ++turn
        var left = frames
        Choreographer.getInstance().postFrameCallback(
            object : Choreographer.FrameCallback {
                override fun doFrame(frameTimeNanos: Long) {
                    if (mine != turn || sliding) return
                    if (--left > 0) {
                        Choreographer.getInstance().postFrameCallback(this)
                        return
                    }
                    putAway()
                }
            },
        )
    }

    /**
     * How much of the window's foot the field takes while it is carried,
     * at its highest yet or with the keys reaching [keys] px: a recording
     * lets that much of the screen in, where the picture is. None while
     * Flutter draws the field itself.
     */
    fun covers(keys: Int): Int {
        val arm = shown?.takeIf { !parked } ?: return 0
        val top = arm.bottom - max(highest, liftOf(arm, keys)) - arm.picture.height
        return (view.height - top).coerceAtLeast(0)
    }

    private companion object {
        /** Frames after Dart's field is drawn before the picture goes. */
        const val HAND_BACK_FRAMES = 3

        /** Frames after a slide before the picture goes regardless. */
        const val LONGEST_FRAMES = 40
    }
}

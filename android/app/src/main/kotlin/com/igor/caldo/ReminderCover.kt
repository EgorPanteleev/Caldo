package com.igor.caldo

import android.app.Activity
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.RenderEffect
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver
import org.json.JSONObject

/**
 * A reminder over the lock screen, taking the whole of it as an alarm does:
 * glass buttons over a blurred glow in the task's own colour.
 *
 * It was to show the wallpaper through it, blurred ("a bit transparent …
 * add blur"), and cannot: over the lock screen Android draws the wallpaper
 * behind an app black, with only a ghost of its outline — measured on the
 * emulator at 1/255 where the lock screen itself showed it at 200, with the
 * window translucent and the wallpaper targeted at it. A translucent
 * activity does not cover the lock screen at all, which then draws over it.
 * So the blur is of shapes drawn here, and is real where Android 12 can
 * blur a view.
 *
 * Drawn natively rather than in Flutter, and opaque, over the app's own
 * view: nothing of the app is ever shown on a phone that has not been
 * unlocked, not for the frame or two Flutter would take to draw over it.
 * The cover being opaque is the whole of that guarantee. Hiding the app's
 * view instead was tried twice: Flutter's own `onStart` shows it again (a
 * workaround of theirs for some OnePlus phones), so the Schedule showed
 * through a dimmed cover; and on a cold start Flutter holds the window's
 * first draw until it has drawn a frame of its own, which a hidden view
 * never does, so the phone sat on the splash screen.
 *
 * Its buttons are the notification's: each sends the same broadcast a tap on
 * one of those does, so the answer goes through the same code (Dart's
 * `onReminderAction`) whatever state the app is in. The words come with the
 * reminder, in its payload, written by Dart in the app's own language.
 */
class ReminderCover(
    private val activity: Activity,
    private val onAnswered: () -> Unit,
) {
    private var view: View? = null

    /** The system bars' backdrops, cleared while the cover is up. */
    private var bars: Pair<Int, Int>? = null

    val shown get() = view != null

    /**
     * Puts the reminder up, and says whether it did: one without the words
     * the cover needs — set by a build from before it — is left to the
     * notification, and the app must not then be let over the lock screen.
     */
    fun show(intent: Intent): Boolean {
        val id = intent.getIntExtra(NOTIFICATION_ID, -1)
        val words = try {
            JSONObject(intent.getStringExtra(PAYLOAD) ?: "")
        } catch (_: Exception) {
            return false
        }
        if (id < 0) return false
        hide()

        val cover = build(id, words)
        // The status bar's backdrop drew a band of its own across the top of
        // the glow, which reaches under it; the navigation bar's strip lies
        // below the content, where the glow does not reach, and is the black
        // the glow fades to there — cleared, it showed the window's white.
        val window = activity.window
        @Suppress("DEPRECATION")
        bars = window.statusBarColor to window.navigationBarColor
        @Suppress("DEPRECATION")
        window.statusBarColor = Color.TRANSPARENT
        @Suppress("DEPRECATION")
        window.navigationBarColor = Color.BLACK
        activity.addContentView(
            cover,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        view = cover
        return true
    }

    fun hide() {
        val cover = view ?: return
        (cover.parent as? ViewGroup)?.removeView(cover)
        view = null
        bars?.let { (status, navigation) ->
            @Suppress("DEPRECATION")
            activity.window.statusBarColor = status
            @Suppress("DEPRECATION")
            activity.window.navigationBarColor = navigation
        }
        bars = null
    }

    private fun answer(id: Int, action: String) {
        activity.sendBroadcast(
            Intent(activity, ActionBroadcastReceiver::class.java)
                .setAction(ActionBroadcastReceiver.ACTION_TAPPED)
                .putExtra(NOTIFICATION_ID, id)
                .putExtra(ACTION_ID, action)
                .putExtra(CANCEL_NOTIFICATION, true),
        )
        onAnswered()
    }

    private fun build(id: Int, words: JSONObject): View {
        val white = Color.WHITE
        // Opaque, on the app's true black: whatever happens to the app's view
        // under it, none of it shows through.
        val root = FrameLayout(activity).apply {
            setBackgroundColor(Color.BLACK)
            isClickable = true
        }
        root.addView(glow(words.optInt("colour", ACCENT)), FrameLayout.LayoutParams(MATCH, MATCH))
        // Enough dark over the glow that white type reads on any colour.
        root.addView(
            View(activity).apply { setBackgroundColor(Color.argb(70, 0, 0, 0)) },
            FrameLayout.LayoutParams(MATCH, MATCH),
        )
        val column = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(16), dp(24), dp(20))
        }
        root.addView(column, FrameLayout.LayoutParams(MATCH, MATCH))
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            column.setPadding(dp(24), dp(16) + bars.top, dp(24), dp(20) + bars.bottom)
            insets
        }

        column.addView(space(), LinearLayout.LayoutParams(MATCH, 0, 2f))
        column.addView(
            ImageView(activity).apply {
                setImageResource(R.drawable.ic_notification)
                imageTintList = ColorStateList.valueOf(white)
                scaleType = ImageView.ScaleType.CENTER_INSIDE
                setPadding(dp(20), dp(20), dp(20), dp(20))
                background = glass(GradientDrawable.OVAL)
            },
            LinearLayout.LayoutParams(dp(76), dp(76)),
        )
        column.addView(
            text(words.optString("title"), 28f, white, bold = true).apply {
                maxLines = 4
                ellipsize = android.text.TextUtils.TruncateAt.END
            },
            LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(28) },
        )
        val line = words.optString("text")
        if (line.isNotEmpty()) {
            column.addView(
                text(line, 16f, Color.argb(190, 255, 255, 255)),
                LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(10) },
            )
        }
        column.addView(space(), LinearLayout.LayoutParams(MATCH, 0, 3f))

        column.addView(
            button(words.optString("done"), Color.WHITE, Color.BLACK) {
                answer(id, "done")
            },
            LinearLayout.LayoutParams(MATCH, dp(56)),
        )
        val snoozes = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
        for ((i, action) in listOf("snooze-15", "snooze-60").withIndex()) {
            snoozes.addView(
                button(words.optString(action), Color.TRANSPARENT, white, glass = true) {
                    answer(id, action)
                },
                LinearLayout.LayoutParams(0, dp(56), 1f).apply {
                    if (i > 0) marginStart = dp(12)
                },
            )
        }
        column.addView(
            snoozes,
            LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(12) },
        )
        column.addView(
            button(words.optString("dismiss"), Color.TRANSPARENT, Color.argb(190, 255, 255, 255)) {
                answer(id, "dismiss")
            },
            LinearLayout.LayoutParams(MATCH, dp(52)).apply { topMargin = dp(8) },
        )
        return root
    }

    private fun space() = View(activity)

    private fun text(words: String, size: Float, colour: Int, bold: Boolean = false) =
        TextView(activity).apply {
            text = words
            setTextColor(colour)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            gravity = Gravity.CENTER
            if (bold) typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }

    /**
     * The glow the cover stands on: three soft shapes in the task's colour,
     * a lighter and a deeper one beside it, blurred into each other. Where a
     * view cannot be blurred (before Android 12) each is a radial gradient
     * instead, soft at the edge on its own.
     */
    private fun glow(colour: Int): View {
        val canBlur = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        val layer = FrameLayout(activity)
        val shapes = listOf(
            // colour, size, x, y, strength
            Blob(colour, 380, -110, -70, 0.95f),
            Blob(mix(colour, Color.WHITE, 0.35f), 300, 190, 240, 0.55f),
            Blob(mix(colour, Color.BLACK, 0.35f), 420, -60, 520, 0.8f),
        )
        for (blob in shapes) {
            val tint = withAlpha(blob.colour, blob.strength)
            layer.addView(
                View(activity).apply {
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        if (canBlur) {
                            setColor(tint)
                        } else {
                            gradientType = GradientDrawable.RADIAL_GRADIENT
                            gradientRadius = dp(blob.size) / 2f
                            colors = intArrayOf(tint, Color.TRANSPARENT)
                        }
                    }
                    translationX = dp(blob.x).toFloat()
                    translationY = dp(blob.y).toFloat()
                },
                FrameLayout.LayoutParams(dp(blob.size), dp(blob.size)),
            )
        }
        if (canBlur) {
            val radius = dp(90).toFloat()
            layer.setRenderEffect(
                RenderEffect.createBlurEffect(radius, radius, Shader.TileMode.DECAL),
            )
        }
        return layer
    }

    private class Blob(
        val colour: Int,
        val size: Int,
        val x: Int,
        val y: Int,
        val strength: Float,
    )

    /** A pane of frosted glass: a little white, and a hairline edge. */
    private fun glass(shape: Int) = GradientDrawable().apply {
        this.shape = shape
        if (shape == GradientDrawable.RECTANGLE) cornerRadius = dp(18).toFloat()
        setColor(Color.argb(38, 255, 255, 255))
        setStroke(dp(1), Color.argb(56, 255, 255, 255))
    }

    private fun mix(a: Int, b: Int, t: Float) = Color.rgb(
        (Color.red(a) + (Color.red(b) - Color.red(a)) * t).toInt(),
        (Color.green(a) + (Color.green(b) - Color.green(a)) * t).toInt(),
        (Color.blue(a) + (Color.blue(b) - Color.blue(a)) * t).toInt(),
    )

    private fun withAlpha(colour: Int, alpha: Float) =
        Color.argb((alpha * 255).toInt(), Color.red(colour), Color.green(colour), Color.blue(colour))

    private fun button(
        words: String,
        fill: Int,
        ink: Int,
        glass: Boolean = false,
        onTap: () -> Unit,
    ) =
        text(words, 15.5f, ink, bold = true).apply {
            val shape = if (glass) {
                glass(GradientDrawable.RECTANGLE)
            } else {
                GradientDrawable().apply {
                    cornerRadius = dp(18).toFloat()
                    setColor(fill)
                }
            }
            val mask = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(Color.WHITE)
            }
            background = RippleDrawable(
                ColorStateList.valueOf(Color.argb(50, 128, 128, 128)),
                shape,
                mask,
            )
            setOnClickListener { onTap() }
        }

    private fun dp(value: Int) =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            activity.resources.displayMetrics,
        ).toInt()

    private companion object {
        /** The app's own accent, for a reminder that came without a colour. */
        const val ACCENT = 0xFF7B61E8.toInt()

        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        // The plugin's names for what rides on a reminder's intents.
        const val NOTIFICATION_ID = "notificationId"
        const val PAYLOAD = "payload"
        const val ACTION_ID = "actionId"
        const val CANCEL_NOTIFICATION = "cancelNotification"
    }
}

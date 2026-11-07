package com.igor.caldo

import android.app.Activity
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver
import io.flutter.embedding.android.FlutterActivity
import org.json.JSONObject

/**
 * A reminder over the lock screen, taking the whole of it as an alarm does,
 * with the phone's wallpaper showing through it.
 *
 * Drawn here rather than in Flutter for two reasons. Showing what lies
 * behind would take a Flutter view that draws transparently, which is a
 * change to how every frame of the app is put on the screen, not only this
 * one's. And while it is up the app's own view is hidden outright, so
 * nothing of the app is ever shown on a phone that has not been unlocked —
 * not for the frame or two Flutter would take to draw over it.
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
    private var background: Drawable? = null

    val shown get() = view != null

    fun show(intent: Intent) {
        val id = intent.getIntExtra(NOTIFICATION_ID, -1)
        val words = try {
            JSONObject(intent.getStringExtra(PAYLOAD) ?: "")
        } catch (_: Exception) {
            return
        }
        if (id < 0) return
        hide()

        val window = activity.window
        background = window.decorView.background
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER)
        activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)?.visibility = View.INVISIBLE

        val cover = build(id, words)
        activity.addContentView(
            cover,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        view = cover
    }

    fun hide() {
        val cover = view ?: return
        (cover.parent as? ViewGroup)?.removeView(cover)
        view = null
        val window = activity.window
        window.clearFlags(WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER)
        window.setBackgroundDrawable(background)
        activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)?.visibility = View.VISIBLE
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
        val root = FrameLayout(activity).apply {
            // The wallpaper, dimmed enough that white type reads on any of
            // them.
            setBackgroundColor(Color.argb(150, 0, 0, 0))
            isClickable = true
        }
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
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(Color.argb(40, 255, 255, 255))
                }
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
                button(words.optString(action), Color.argb(42, 255, 255, 255), white) {
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

    private fun button(words: String, fill: Int, ink: Int, onTap: () -> Unit) =
        text(words, 15.5f, ink, bold = true).apply {
            val shape = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(fill)
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
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        // The plugin's names for what rides on a reminder's intents.
        const val NOTIFICATION_ID = "notificationId"
        const val PAYLOAD = "payload"
        const val ACTION_ID = "actionId"
        const val CANCEL_NOTIFICATION = "cancelNotification"
    }
}

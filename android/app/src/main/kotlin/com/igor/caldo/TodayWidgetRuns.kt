package com.igor.caldo

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.text.SpannableString
import android.text.Spanned
import android.text.format.DateFormat
import android.text.style.StrikethroughSpan
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * The widget's runs, read from the copy the app leaves: Overdue, then Today,
 * Tomorrow and each later day with something on it — the order Schedule
 * reads in, and in each day the order Schedule shows it.
 *
 * Drawn straight into the widget rather than handed to a list. A widget's
 * list moves nothing: a card that changed place was rebound where it now
 * stood, so a ticked task teleported to the end of its day — and a list
 * whose rows were whole runs, tried next, swapped each run out whole behind
 * a "Loading…" flash. A plain layout is drawn over the one already on the
 * home screen, and each run and card is added under its own key
 * (`addStableView`), so the launcher keeps the views it has and its layout
 * animates what changed: the ticked card leaves its place, the ones after
 * it rise into the gap, and it comes in at the end. The cost is that the
 * widget does not scroll.
 */
class TodayWidgetRuns(private val context: Context) {
    /**
     * A run's heading as Schedule writes it (`DayHeader`): [word] on a
     * badge — Today, Tomorrow, Overdue — and [date] beside it.
     */
    private data class Heading(val word: String?, val date: String?, val overdue: Boolean)

    /**
     * A run: its heading, a quiet [note] when it has nothing in it, and its
     * cards. [key] is the run's own, the same from one drawing to the next,
     * so the launcher keeps the views it had for it.
     */
    private data class Run(
        val key: Long,
        val heading: Heading,
        val note: String?,
        val items: List<Item>,
    )

    private data class Item(
        val id: Long,
        val title: String,
        val minute: Int?,
        val done: Boolean,
        val colour: Int,
        /** Its time written in red, as the app writes an overdue task's. */
        val late: Boolean,
    )

    private var rows: List<Run> = emptyList()

    /** Words and dates in the language the app is speaking. */
    private var locale: Locale = Locale.getDefault()
    private var words: Context = context

    /** Reads the copy, as it is now, into runs. */
    fun load() {
        val prefs = TodayWidget.prefs(context)
        val copy = prefs.getString(TodayWidget.KEY, null) ?: run {
            rows = emptyList()
            return
        }
        locale = TodayWidget.language(context)
        words = TodayWidget.speaking(context, locale)
        val showDone = prefs.getBoolean(TodayWidget.KEY_SHOW_DONE, true)
        val iso = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val now = Calendar.getInstance()
        val today = iso.format(now.time)
        val minuteNow = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
        val tomorrow = iso.format(
            Calendar.getInstance().apply { add(Calendar.DAY_OF_MONTH, 1) }.time,
        )

        // Worked out against today as it is now, not as it was when the copy
        // was written: a copy from last night has yesterday's open tasks in
        // what is this morning's backlog.
        val overdue = mutableListOf<Item>()
        val days = linkedMapOf<String, MutableList<Item>>()
        val tasks = JSONObject(copy).getJSONArray("tasks")
        for (i in 0 until tasks.length()) {
            val task = tasks.getJSONObject(i)
            val day = task.getString("day")
            val minute = if (task.isNull("time")) null else task.getInt("time")
            val done = task.getBoolean("done")
            val item = Item(
                id = task.getLong("id"),
                title = task.getString("title"),
                minute = minute,
                done = done,
                colour = task.getLong("colour").toInt(),
                // `Task.isOverdue`: an earlier day, or a time today gone by.
                late = !done && (day < today || (day == today && minute != null && minute < minuteNow)),
            )
            when {
                day < today -> if (!item.done) overdue.add(item)
                item.done && !showDone -> {}
                else -> days.getOrPut(day) { mutableListOf() }.add(item)
            }
        }

        // "Sat, 4 Oct", and the year as well when it is not this one, as
        // `Dates.dayDate` writes it.
        val label = SimpleDateFormat(TodayWidget.pattern(locale, "EEEdMMM", "EEE, d MMM"), locale)
        val labelYear = SimpleDateFormat(TodayWidget.pattern(locale, "yEEEdMMM", "EEE, d MMM yyyy"), locale)
        fun date(day: String) = TodayWidget.capitalised(
            (if (day.take(4) == today.take(4)) label else labelYear).format(iso.parse(day)!!),
            locale,
        )
        // A day's key is its date as a number, 20261102; the backlog's is 0.
        fun key(day: String) = day.replace("-", "").toLong()
        rows = buildList {
            if (overdue.isNotEmpty()) {
                val heading = Heading(words.getString(R.string.widget_overdue), null, overdue = true)
                add(Run(0, heading, null, overdue))
            }
            // Today is said even when it is empty, once there is anything
            // else to show: a list that opens on Tomorrow leaves today to be
            // guessed at.
            if (today !in days && (overdue.isNotEmpty() || days.isNotEmpty())) {
                val heading = Heading(words.getString(R.string.widget_today), date(today), overdue = false)
                add(Run(key(today), heading, words.getString(R.string.widget_nothing_today), emptyList()))
            }
            for ((day, items) in days) {
                val word = when (day) {
                    today -> words.getString(R.string.widget_today)
                    tomorrow -> words.getString(R.string.widget_tomorrow)
                    else -> null
                }
                add(Run(key(day), Heading(word, date(day), overdue = false), null, items))
            }
        }.let(::trimmed)
    }

    /**
     * The runs cut down to [MOST] cards — more than the tallest widget
     * shows, since nothing scrolls, and every card drawn is sent to the
     * launcher whole.
     */
    private fun trimmed(runs: List<Run>): List<Run> {
        var left = MOST
        return buildList {
            for (run in runs) {
                if (left <= 0) break
                add(run.copy(items = run.items.take(left)))
                left -= run.items.size
            }
        }
    }

    val isEmpty get() = rows.isEmpty()

    /** Adds the runs to [container] in [views], each under its own key. */
    fun addTo(views: RemoteViews, container: Int) {
        views.removeAllViews(container)
        for (run in rows) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                views.addStableView(container, view(run), run.key.toInt())
            } else {
                views.addView(container, view(run))
            }
        }
    }

    private fun view(run: Run): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_run)
        val heading = run.heading
        if (heading.word == null) {
            views.setViewVisibility(R.id.widget_badge, View.GONE)
        } else {
            views.setViewVisibility(R.id.widget_badge, View.VISIBLE)
            views.setTextViewText(R.id.widget_badge, heading.word)
            views.setInt(
                R.id.widget_badge,
                "setBackgroundResource",
                if (heading.overdue) R.drawable.widget_badge_overdue else R.drawable.widget_badge,
            )
            views.setTextColor(R.id.widget_badge, if (heading.overdue) Color.WHITE else Color.BLACK)
        }
        views.setViewVisibility(R.id.widget_heading, if (heading.date == null) View.GONE else View.VISIBLE)
        views.setTextViewText(R.id.widget_heading, heading.date ?: "")
        views.setViewVisibility(R.id.widget_note, if (run.note == null) View.GONE else View.VISIBLE)
        views.setTextViewText(R.id.widget_note, run.note ?: "")
        // Cleared and added again in the new order — which, drawn over the
        // run as it stands, keeps every card with an id it already has and
        // only moves it (see [Rows]). Before Android 12 there are no stable
        // ids, and the run is simply drawn afresh.
        views.removeAllViews(R.id.widget_cards)
        for (item in run.items) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                views.addStableView(R.id.widget_cards, box(item), item.id.toInt())
            } else {
                views.addView(R.id.widget_cards, item(item))
            }
        }
        return views
    }

    /**
     * A task from Android 12 on, drawn as the app's card is — inked with its
     * colour, crossed out and sunk once done — with a real checkbox for a
     * tick. The launcher animates a box's change itself the moment it is
     * tapped, from the drawable the row carries (`widget_check_*`): the
     * square fills, then the check is drawn through it. A drawable cannot be
     * tinted without the check going the same colour, so there is a row
     * layout per colour, each with its own; `tool/make_widget_ticks.py`
     * writes them.
     */
    private fun box(row: Item) = RemoteViews(context.packageName, layoutFor(row.colour)).apply {
        card(row)
        setCompoundButtonChecked(R.id.widget_tick, row.done)
        setOnCheckedChangeResponse(
            R.id.widget_tick,
            RemoteViews.RemoteResponse.fromPendingIntent(tap(TodayWidget.OP_TOGGLE, row.id)),
        )
    }

    /**
     * A tap on a card: an intent of its own, one per task and tap, since
     * there is no list to hold a template. Mutable, so the box's new state
     * can be filled in when it is sent.
     */
    private fun tap(op: String, id: Long): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, TodayWidget::class.java)
            .setAction(TodayWidget.ACTION_ITEM)
            // One intent per task and tap, not one shared and overwritten.
            .setData(Uri.parse("caldo://widget/$op/$id"))
            .putExtra(TodayWidget.EXTRA_OP, op)
            .putExtra(TodayWidget.EXTRA_TASK, id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )


    /** What every task row has, whichever tick it wears. */
    private fun RemoteViews.card(row: Item) {
        setInt(R.id.widget_ink, "setColorFilter", row.colour)
        setInt(R.id.widget_ink, "setImageAlpha", if (row.done) INK_DONE else INK)
        val title = SpannableString(row.title)
        if (row.done) {
            title.setSpan(StrikethroughSpan(), 0, title.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        setTextViewText(R.id.widget_title, title)
        setTextColor(R.id.widget_title, if (row.done) FAINT else TEXT)
        setTextViewText(
            R.id.widget_time,
            if (row.minute == null) words.getString(R.string.widget_all_day) else time(row.minute),
        )
        setTextColor(R.id.widget_time, if (row.late) OVERDUE else MUTED)
        setOnClickPendingIntent(R.id.widget_card, tap(TodayWidget.OP_OPEN, row.id))
    }

    /** The row layout in the swatch nearest [colour]. */
    private fun layoutFor(colour: Int): Int {
        fun distance(a: Int, b: Int): Int {
            val r = Color.red(a) - Color.red(b)
            val g = Color.green(a) - Color.green(b)
            val bl = Color.blue(a) - Color.blue(b)
            return r * r + g * g + bl * bl
        }
        return SWATCHES.minBy { distance(it.key, colour) }.value
    }

    /**
     * A task before Android 12, which has no checkbox for a widget: the
     * tick is an image that changes when the list is next drawn.
     */
    private fun item(row: Item) = RemoteViews(context.packageName, R.layout.widget_task).apply {
        card(row)
        setImageViewResource(
            R.id.widget_tick,
            if (row.done) R.drawable.widget_tick_done else R.drawable.widget_tick_open,
        )
        setInt(R.id.widget_tick, "setColorFilter", row.colour)
        setViewVisibility(R.id.widget_check, if (row.done) View.VISIBLE else View.GONE)
        setOnClickPendingIntent(R.id.widget_tick_area, tap(TodayWidget.OP_TOGGLE, row.id))
    }

    /** On the clock Settings names, or the phone's until one is named. */
    private fun time(minute: Int): String {
        val prefs = TodayWidget.prefs(context)
        val h24 =
            if (prefs.contains(TodayWidget.KEY_24_HOUR)) {
                prefs.getBoolean(TodayWidget.KEY_24_HOUR, false)
            } else {
                DateFormat.is24HourFormat(context)
            }
        val at = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, minute / 60)
            set(Calendar.MINUTE, minute % 60)
        }
        return SimpleDateFormat(if (h24) "HH:mm" else "h:mm a", locale).format(at.time)
    }

    private companion object {
        // The app's dark palette (`AppColors`).
        const val TEXT = 0xFFE9E9EB.toInt()
        const val MUTED = 0xFF9B9BA1.toInt()
        const val FAINT = 0xFF6A6A70.toInt()
        const val OVERDUE = 0xFFE05252.toInt()

        /**
         * The card's ink, out of 255, as the app inks it over the same
         * black: a quarter of the task's colour, and a fourteenth once done.
         */
        const val INK = 61
        const val INK_DONE = 18

        const val MOST = 24

        /** `ListStyle`'s swatches, each with its row (see [box]). */
        val SWATCHES = mapOf(
            0xFF7B61E8.toInt() to R.layout.widget_task_violet,
            0xFF3B7DD8.toInt() to R.layout.widget_task_blue,
            0xFF16A394.toInt() to R.layout.widget_task_teal,
            0xFF35A06A.toInt() to R.layout.widget_task_green,
            0xFFD99A2B.toInt() to R.layout.widget_task_amber,
            0xFFD9528A.toInt() to R.layout.widget_task_pink,
            0xFF1E94B0.toInt() to R.layout.widget_task_cyan,
            0xFFDB7A33.toInt() to R.layout.widget_task_orange,
        )
    }
}

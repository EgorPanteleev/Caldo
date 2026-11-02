package com.igor.caldo

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.text.SpannableString
import android.text.Spanned
import android.text.format.DateFormat
import android.text.style.StrikethroughSpan
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/** Hands the widget's list its rows. */
class TodayWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = Rows(applicationContext)
}

/**
 * The widget's runs, read from the copy the app leaves: Overdue, then Today,
 * Tomorrow and each later day with something on it — the order Schedule
 * reads in, and in each day the order Schedule shows it.
 */
private class Rows(private val context: Context) : RemoteViewsService.RemoteViewsFactory {
    private sealed interface Row

    private data class Heading(val label: String, val overdue: Boolean) : Row

    /** A quiet line under a day with nothing on it. */
    private data class Note(val text: String) : Row

    private data class Item(
        val id: Long,
        val title: String,
        val minute: Int?,
        val done: Boolean,
        val colour: Int,
    ) : Row

    private var rows: List<Row> = emptyList()

    /** Words and dates in the language the app is speaking. */
    private var locale: Locale = Locale.getDefault()
    private var words: Context = context

    override fun onCreate() {}

    override fun onDestroy() {}

    override fun onDataSetChanged() {
        val prefs = TodayWidget.prefs(context)
        val copy = prefs.getString(TodayWidget.KEY, null) ?: run {
            rows = emptyList()
            return
        }
        locale = TodayWidget.language(context)
        words = TodayWidget.speaking(context, locale)
        val showDone = prefs.getBoolean(TodayWidget.KEY_SHOW_DONE, true)
        val iso = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val today = iso.format(Calendar.getInstance().time)
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
            val item = Item(
                id = task.getLong("id"),
                title = task.getString("title"),
                minute = if (task.isNull("time")) null else task.getInt("time"),
                done = task.getBoolean("done"),
                colour = task.getLong("colour").toInt(),
            )
            val day = task.getString("day")
            when {
                day < today -> if (!item.done) overdue.add(item)
                item.done && !showDone -> {}
                else -> days.getOrPut(day) { mutableListOf() }.add(item)
            }
        }

        val label = SimpleDateFormat(
            TodayWidget.pattern(locale, "EEEdMMM", "EEE, d MMM"),
            locale,
        )
        rows = buildList {
            if (overdue.isNotEmpty()) {
                add(Heading(words.getString(R.string.widget_overdue), overdue = true))
                addAll(overdue)
            }
            // Today is said even when it is empty, once there is anything
            // else to show: a list that opens on Tomorrow under a header
            // that says Monday leaves today to be guessed at.
            if (today !in days && (overdue.isNotEmpty() || days.isNotEmpty())) {
                add(Heading(words.getString(R.string.widget_today), overdue = false))
                add(Note(words.getString(R.string.widget_nothing_today)))
            }
            for ((day, items) in days) {
                val name = when (day) {
                    today -> words.getString(R.string.widget_today)
                    tomorrow -> words.getString(R.string.widget_tomorrow)
                    else -> TodayWidget.capitalised(label.format(iso.parse(day)!!), locale)
                }
                add(Heading(name, overdue = false))
                addAll(items)
            }
        }
    }

    override fun getCount() = rows.size

    override fun getViewAt(position: Int): RemoteViews {
        return when (val row = rows.getOrNull(position)) {
            is Heading -> RemoteViews(context.packageName, R.layout.widget_heading).apply {
                setTextViewText(R.id.widget_heading, row.label)
                setTextColor(R.id.widget_heading, if (row.overdue) OVERDUE else MUTED)
            }
            is Note -> RemoteViews(context.packageName, R.layout.widget_note).apply {
                setTextViewText(R.id.widget_note, row.text)
            }
            is Item -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) box(row) else item(row)
            null -> RemoteViews(context.packageName, R.layout.widget_heading)
        }
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
            RemoteViews.RemoteResponse.fromFillInIntent(
                Intent()
                    .putExtra(TodayWidget.EXTRA_OP, TodayWidget.OP_TOGGLE)
                    .putExtra(TodayWidget.EXTRA_TASK, row.id),
            ),
        )
    }

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
        // A time where there is one; "All day" on every untimed card was
        // the same two words down the whole list.
        if (row.minute == null) {
            setViewVisibility(R.id.widget_time, View.GONE)
        } else {
            setViewVisibility(R.id.widget_time, View.VISIBLE)
            setTextViewText(R.id.widget_time, time(row.minute))
        }
        setOnClickFillInIntent(
            R.id.widget_card,
            Intent()
                .putExtra(TodayWidget.EXTRA_OP, TodayWidget.OP_OPEN)
                .putExtra(TodayWidget.EXTRA_TASK, row.id),
        )
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
        setOnClickFillInIntent(
            R.id.widget_tick_area,
            Intent()
                .putExtra(TodayWidget.EXTRA_OP, TodayWidget.OP_TOGGLE)
                .putExtra(TodayWidget.EXTRA_TASK, row.id),
        )
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

    override fun getLoadingView(): RemoteViews? = null

    // A heading, a note, the old tick's row and a row per swatch.
    override fun getViewTypeCount() = 3 + SWATCHES.size

    override fun getItemId(position: Int): Long =
        when (val row = rows.getOrNull(position)) {
            is Item -> row.id
            else -> -1L - position
        }

    override fun hasStableIds() = true

    private companion object {
        // The app's dark palette (`AppColors`).
        const val TEXT = 0xFFE9E9EB.toInt()
        const val MUTED = 0xFF9B9BA1.toInt()
        const val FAINT = 0xFF6A6A70.toInt()
        const val OVERDUE = 0xFFE05252.toInt()

        /**
         * The card's ink, out of 255: a sixth of the task's colour, and a
         * fifteenth once done. Lighter than the app's quarter — on a
         * graphite panel rather than true black the same ink came out as
         * heavy purple bricks.
         */
        const val INK = 42
        const val INK_DONE = 16

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

package com.igor.caldo

import android.content.Context
import android.content.Intent
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

        val label = SimpleDateFormat("EEE, d MMM", locale)
        rows = buildList {
            if (overdue.isNotEmpty()) {
                add(Heading(words.getString(R.string.widget_overdue), overdue = true))
                addAll(overdue)
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
            is Item -> item(row)
            null -> RemoteViews(context.packageName, R.layout.widget_heading)
        }
    }

    /**
     * A task, drawn as the app's card is: inked with its colour over the
     * ground — a quarter of it, a fourteenth once done — with a tick in the
     * colour, filled once ticked, and the title crossed out.
     */
    private fun item(row: Item) = RemoteViews(context.packageName, R.layout.widget_task).apply {
        setInt(R.id.widget_ink, "setColorFilter", row.colour)
        setInt(R.id.widget_ink, "setImageAlpha", if (row.done) 18 else 61)
        setImageViewResource(
            R.id.widget_tick,
            if (row.done) R.drawable.widget_tick_done else R.drawable.widget_tick_open,
        )
        setInt(R.id.widget_tick, "setColorFilter", row.colour)
        setViewVisibility(R.id.widget_check, if (row.done) View.VISIBLE else View.GONE)

        val title = SpannableString(row.title)
        if (row.done) {
            title.setSpan(StrikethroughSpan(), 0, title.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        setTextViewText(R.id.widget_title, title)
        setTextColor(R.id.widget_title, if (row.done) FAINT else TEXT)
        setTextViewText(R.id.widget_time, time(row.minute))

        setOnClickFillInIntent(
            R.id.widget_tick_area,
            Intent()
                .putExtra(TodayWidget.EXTRA_OP, TodayWidget.OP_TOGGLE)
                .putExtra(TodayWidget.EXTRA_TASK, row.id),
        )
        setOnClickFillInIntent(
            R.id.widget_card,
            Intent()
                .putExtra(TodayWidget.EXTRA_OP, TodayWidget.OP_OPEN)
                .putExtra(TodayWidget.EXTRA_TASK, row.id),
        )
    }

    /** On the clock Settings names, or the phone's until one is named. */
    private fun time(minute: Int?): String {
        if (minute == null) return words.getString(R.string.widget_all_day)
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

    override fun getViewTypeCount() = 2

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
    }
}

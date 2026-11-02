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
import android.util.TypedValue.COMPLEX_UNIT_PX
import android.view.View
import android.widget.FrameLayout
import android.widget.RemoteViews
import android.widget.TextView
import org.json.JSONObject
import kotlin.math.abs
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
 * (`addStableView`), so the launcher keeps the views it has. The cost is
 * that the widget does not scroll.
 *
 * Keeping a view is not moving it, though. The launcher keeps the views
 * whose keys come in the order it already has them and takes out the ones
 * in between, so a card stacked under the others that went to the end of
 * its day was taken out and a new one put in at the end: it faded out
 * where it stood and in where it went, which read as the same teleport.
 * So a run's cards are not stacked. They stand in a frame in the order of
 * their ids, which a move never changes, each placed by a top margin
 * worked out from the heights of the cards above it ([fit]), and a move is
 * only a margin changed. The frame animates its changes, and a nudge
 * ([nudge]) on every drawing has it slide each card from where it was to
 * where it now stands — the ticked one down past the rest, the rest up
 * into its gap.
 */
class TodayWidgetRuns(private val context: Context, private val widget: Int) {
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

    /**
     * Adds the runs to [container] in [views], each under its own key, for
     * cards [width] pixels wide.
     */
    fun addTo(views: RemoteViews, container: Int, width: Int) {
        views.removeAllViews(container)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            for (run in rows) views.addView(container, view(run, width))
            return
        }
        for (run in rows) views.addStableView(container, view(run, width), run.key.toInt())
        // The runs below one that grew or shrank slide too.
        views.addStableView(container, nudge(), NUDGE)
    }

    private fun view(run: Run, width: Int): RemoteViews {
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
        // Cleared and added again — which, drawn over the run as it
        // stands, keeps every card with an id it already has. Before
        // Android 12 there are no stable ids, and the run is simply drawn
        // afresh, stacked.
        views.removeAllViews(R.id.widget_cards)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            for (item in run.items) views.addView(R.id.widget_cards, item(item))
            return views
        }
        var top = 0
        val cards = run.items.associate { item ->
            val card = box(item)
            card.setViewLayoutMargin(R.id.widget_row, RemoteViews.MARGIN_TOP, top.toFloat(), COMPLEX_UNIT_PX)
            val at = top
            top += fit(card, width)
            item.id to (card to at)
        }
        // The card that travels furthest is drawn over the rest, so it is
        // seen going past them rather than sliding under the cards it
        // passes and coming out at the end.
        val before = placed[widget].orEmpty()
        val mover = cards.entries
            .filter { (id, it) -> before[id] != null && before[id] != it.second }
            .maxByOrNull { (id, it) -> abs(before.getValue(id) - it.second) }?.key
        placed[widget] = before + cards.mapValues { it.value.second }
        for ((id, entry) in cards.toSortedMap()) {
            val card = entry.first
            card.setFloat(R.id.widget_row, "setTranslationZ", if (id == mover) 1f else 0f)
            views.addStableView(R.id.widget_cards, card, id.toInt())
        }
        views.addStableView(R.id.widget_cards, nudge(), NUDGE)
        // As tall as its cards, said outright. Left to wrap them, the frame
        // is held to what the widget has left above its foot, and gives each
        // card only the room left above that: a card sent past the foot —
        // the ticked one going to the end of a long day — was measured to
        // nothing and vanished instead of sliding.
        views.setViewLayoutHeight(R.id.widget_cards, top.toFloat(), COMPLEX_UNIT_PX)
        return views
    }

    /** What [fit] lays a card out in, for the layout parameters it takes. */
    private val frame by lazy { FrameLayout(context) }

    /**
     * How tall [card] stands at [width], gap included — laid out here, as
     * the launcher will lay it out. Its title is then held to the lines it
     * took: the launcher's width can be a pixel or two from the one the
     * widget is told, and a title that wrapped there and not here would
     * make the card taller than the room left for it.
     */
    private fun fit(card: RemoteViews, width: Int): Int {
        val view = card.apply(context, frame)
        view.measure(
            View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
        )
        val lines = view.findViewById<TextView>(R.id.widget_title).lineCount
        card.setInt(R.id.widget_title, "setLines", lines.coerceAtLeast(1))
        return view.measuredHeight
    }

    /**
     * A view shown and hidden again on every drawing. A layout that
     * animates its changes only watches where its views go when one is
     * added, taken out, shown or hidden; a card whose margin changed and
     * nothing else would jump. Shown first: the first of these sets how
     * every view slides, and a removal waits 300ms before it moves anything.
     */
    private fun nudge() = RemoteViews(context.packageName, R.layout.widget_nudge).apply {
        setViewVisibility(R.id.widget_nudge, View.VISIBLE)
        setViewVisibility(R.id.widget_nudge, View.GONE)
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
        setInt(R.id.widget_ink, "setColorFilter", inked(row.colour, if (row.done) INK_DONE else INK))
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

    /**
     * [colour] at [strength] over the widget's black, worked out rather
     * than left translucent: cards cross while they slide, and the one
     * underneath would show through.
     */
    private fun inked(colour: Int, strength: Int) = Color.rgb(
        Color.red(colour) * strength / 255,
        Color.green(colour) * strength / 255,
        Color.blue(colour) * strength / 255,
    )

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

        /**
         * Where each widget last drew each card, by task, to tell which
         * card is moving furthest. Held in memory: the process lives from a
         * tick to the drawing that moves its card, and a card missing here
         * only means nothing is raised.
         */
        val placed = mutableMapOf<Int, Map<Long, Int>>()

        /** The nudge's key; -1 is no key at all, and the rest are ids. */
        const val NUDGE = -2

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

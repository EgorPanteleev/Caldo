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
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

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
 * So nothing is stacked. Every heading and card stands in one frame in the
 * order of its key, which a move never changes, placed by a top margin
 * worked out from the heights of everything above it ([fit]), and a move is
 * only a margin changed.
 *
 * And it moves as the app's card does, on the app's timings and curves
 * rather than the launcher's (`SlideIntoPlace`, `TaskCard`): a view that
 * has moved is drawn back where it was (`translationY`) and an animator of
 * its own eases it home, started by flipping the view's enabled state —
 * the one thing a widget may change on a view that an animator answers to
 * (animator/widget_*.xml). The ink sinking and the title being crossed out
 * are started the same way.
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
        /** Where a task with a length ends, in minutes from midnight. */
        val end: Int?,
        val done: Boolean,
        val colour: Int,
        /** Its time written in red, as the app writes an overdue task's. */
        val late: Boolean,
        /** Set for an event from the phone's calendars, which is no task. */
        val event: PhoneEvents.Event? = null,
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
        val read = JSONObject(copy)
        val tasks = read.getJSONArray("tasks")
        for (i in 0 until tasks.length()) {
            val task = tasks.getJSONObject(i)
            val day = task.getString("day")
            val minute = if (task.isNull("time")) null else task.getInt("time")
            val done = task.getBoolean("done")
            val item = Item(
                id = task.getLong("id"),
                title = task.getString("title"),
                minute = minute,
                end = if (task.isNull("end")) null else task.optInt("end"),
                done = done,
                colour = task.getLong("colour").toInt(),
                // `Task.isOverdue`: an earlier day, or a time today gone by.
                late = !done && (day < today || (day == today && minute != null && minute < minuteNow)),
            )
            when {
                // Shown while fading out of the run, though by then done.
                day < today -> if (!item.done || item.id in leaving) overdue.add(item)
                item.done && !showDone && item.id !in leaving -> {}
                else -> days.getOrPut(day) { mutableListOf() }.add(item)
            }
        }

        // A day's events go ahead of its tasks, as Schedule puts them, and a
        // day with only events on it has a run of its own.
        val events = eventsByDay(read.optJSONObject("events"), iso, today)
        val all = (days.keys + events.keys).toSortedSet().associateWith {
            events[it].orEmpty() + days[it].orEmpty()
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
            if (today !in all && (overdue.isNotEmpty() || all.isNotEmpty())) {
                val heading = Heading(words.getString(R.string.widget_today), date(today), overdue = false)
                add(Run(key(today), heading, words.getString(R.string.widget_nothing_today), emptyList()))
            }
            for ((day, items) in all) {
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
     * The phone's events for today and the agenda's days after it, by day,
     * all-day ones first and then by when they start. Read here, as the
     * widget is drawn, rather than from the copy: they change in other apps,
     * and the copy only changes when Caldo does. The copy says whether they
     * are wanted, and which calendars are left out ([wanted]).
     *
     * An all-day event is on every day it covers; a timed one on the day it
     * starts, with its end written only when it ends that day.
     */
    private fun eventsByDay(
        wanted: JSONObject?,
        iso: SimpleDateFormat,
        today: String,
    ): Map<String, List<Item>> {
        if (wanted == null || !wanted.optBoolean("on")) return emptyMap()
        val hidden = wanted.optJSONArray("hidden")
            ?.let { list -> (0 until list.length()).map { list.getString(it) }.toSet() }
            .orEmpty()
        val start = iso.parse(today)!!.time
        val to = Calendar.getInstance().apply {
            timeInMillis = start
            add(Calendar.DAY_OF_MONTH, DAYS)
        }.timeInMillis
        // All-day events are stored at midnight UTC on their dates, which is
        // the day before somewhere west of Greenwich: read off in UTC.
        val utc = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val byDay = sortedMapOf<String, MutableList<Item>>()
        fun put(day: String, item: Item) = byDay.getOrPut(day) { mutableListOf() }.add(item)
        for (event in PhoneEvents.between(context, start, to)) {
            if (event.calendar in hidden) continue
            if (event.allDay) {
                var at = event.begin
                while (at < event.end) {
                    val day = utc.format(Date(at))
                    if (day >= today) put(day, eventItem(event, day, null, null))
                    at += DAY_MS
                }
                continue
            }
            if (event.begin < start) continue
            val from = Calendar.getInstance().apply { timeInMillis = event.begin }
            val until = Calendar.getInstance().apply { timeInMillis = event.end }
            val day = iso.format(from.time)
            fun minute(at: Calendar) = at.get(Calendar.HOUR_OF_DAY) * 60 + at.get(Calendar.MINUTE)
            val sameDay = iso.format(until.time) == day
            put(day, eventItem(event, day, minute(from), if (sameDay) minute(until) else null))
        }
        for (items in byDay.values) items.sortBy { it.minute ?: -1 }
        return byDay
    }

    private fun eventItem(event: PhoneEvents.Event, day: String, minute: Int?, end: Int?) = Item(
        // Kept clear of the tasks' ids and the headings' negative keys, and
        // one for each day an event is on.
        id = EVENT_KEYS + (event.id % 100_000) * 1_000 + day.replace("-", "").toLong() % 1_000,
        title = event.title,
        minute = minute,
        end = end,
        done = false,
        colour = event.colour,
        late = false,
        event = event,
    )

    /**
     * The runs cut down to [MOST] cards: the list scrolls them, but it is
     * one row, and every card in it is sent to the launcher whole each time
     * the widget is drawn.
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
     * Adds the runs to [container] in [views], each heading and card under
     * its own key, for cards [width] pixels wide.
     */
    fun addTo(views: RemoteViews, container: Int, width: Int) {
        views.removeAllViews(container)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            for (run in rows) {
                views.addView(container, heading(run))
                for (item in run.items) {
                    views.addView(container, if (item.event != null) event(item) else item(item))
                }
            }
            return
        }

        // Laid out top to bottom. A card leaving its run keeps its place
        // while it fades, and takes no room: what comes after it closes up
        // over it, as the app's run does.
        val laid = mutableListOf<Laid>()
        var top = 0
        for (run in rows) {
            val head = heading(run)
            laid += Laid(headingKey(run), head, top, leaving = false)
            top += fit(head, width, "head|${run.heading.word}|${run.heading.date}|${run.note}")
            for (item in run.items) {
                val isEvent = item.event != null
                val card = if (isEvent) event(item) else box(item)
                val going = item.id in leaving
                laid += Laid(item.id.toInt(), card, top, going)
                val height = fit(
                    card,
                    width,
                    "${if (isEvent) "event" else "card"}|${item.title}",
                    crossed = !isEvent,
                )
                if (!going) top += height
            }
        }

        val before = placed[widget].orEmpty()
        // A card has just started leaving: what closes up after it does so
        // over the app's 280ms, not the 260 of a slide.
        val closing = laid.any { it.leaving && before[it.key] != null && it.key !in left[widget].orEmpty() }
        laid.forEachIndexed { index, it ->
            it.views.setViewLayoutMargin(R.id.widget_row, RemoteViews.MARGIN_TOP, it.top.toFloat(), COMPLEX_UNIT_PX)
            // Drawn in the order of the run, as the app paints it: a card
            // going to the end of its day passes over those it overtakes,
            // and one leaving is covered by the cards closing up over it.
            it.views.setFloat(R.id.widget_row, "setTranslationZ", index.toFloat())
            val was = before[it.key]
            // Only what has moved is touched. Drawn again in place — when
            // Dart's copy confirms the order already shown — a card in the
            // middle of its slide is left to finish it.
            if (was != null && was != it.top) {
                it.views.setFloat(R.id.widget_row, "setTranslationY", (was - it.top).toFloat())
                it.views.setBoolean(R.id.widget_row, "setEnabled", closing)
                it.views.setBoolean(R.id.widget_row, "setEnabled", !closing)
            }
        }
        placed[widget] = laid.associate { it.key to it.top }
        left[widget] = laid.filter { it.leaving }.map { it.key }.toSet()
        for (it in laid.sortedBy { it.key }) views.addStableView(container, it.views, it.key)
        // As tall as what is in it, said outright. Left to wrap it, the
        // frame is held to what the widget has left above its foot, and
        // gives each card only the room left above that: a card sent past
        // the foot — the ticked one going to the end of a long day — was
        // measured to nothing and vanished instead of sliding.
        views.setViewLayoutHeight(container, top.toFloat(), COMPLEX_UNIT_PX)
    }

    /** A heading or card, its key, and where it is laid out. */
    private class Laid(val key: Int, val views: RemoteViews, val top: Int, val leaving: Boolean)

    /** A run's heading's key, kept clear of the cards' (task ids) and of -1, which is none. */
    private fun headingKey(run: Run) = -2 - run.key.toInt()

    private fun heading(run: Run): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_heading)
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
        return views
    }

    /** What [fit] lays a view out in, for the layout parameters it takes. */
    private val frame by lazy { FrameLayout(context) }

    /**
     * How tall [views] stands at [width], a card's gap included — laid out
     * here, as the launcher will lay it out. A card's title is then held to
     * the lines it took: the launcher's width can be a pixel or two from the
     * one the widget is told, and a title that wrapped there and not here
     * would make the card taller than the room left for it.
     */
    private fun fit(views: RemoteViews, width: Int, what: String, crossed: Boolean = true): Int {
        // Laid out once for each text, width and text size, not on every
        // drawing: a list of fifty cards is drawn twice in a tick.
        val config = context.resources.configuration
        val key = "$what|$width|${config.fontScale}|${config.densityDpi}"
        val (height, lines) = measured.getOrPut(key) {
            if (measured.size > 500) measured.clear()
            val view = views.apply(context, frame)
            view.measure(
                View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            )
            view.measuredHeight to (view.findViewById<TextView>(R.id.widget_title)?.lineCount ?: 0)
        }
        if (lines > 0) {
            views.setInt(R.id.widget_title, "setLines", lines)
            // Only a task's row has a crossed-out title: an action on a view
            // a row does not have fails the whole widget.
            if (crossed) views.setInt(R.id.widget_title_done, "setLines", lines)
        }
        return height
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
        // Open is enabled, done is not: the ink and both titles each play
        // their part of the crossing out when it changes.
        for (part in intArrayOf(R.id.widget_ink, R.id.widget_title, R.id.widget_title_done)) {
            setBoolean(part, "setEnabled", !row.done)
        }
        setTextViewText(R.id.widget_title, row.title)
        setTextViewText(R.id.widget_title_done, crossedOut(row.title))
        setBoolean(R.id.widget_card, "setEnabled", row.id !in leaving)
        setCompoundButtonChecked(R.id.widget_tick, row.done)
        // Filled in on the list's intent, as a card in a list must be; the
        // box adds what it now shows.
        setOnCheckedChangeResponse(
            R.id.widget_tick,
            RemoteViews.RemoteResponse.fromFillInIntent(fillIn(TodayWidget.OP_TOGGLE, row.id)),
        )
        setOnClickFillInIntent(R.id.widget_card, fillIn(TodayWidget.OP_OPEN, row.id))
    }

    /**
     * An event from the phone's calendars: its colour's ink and mark, its
     * title and time, and a tap that opens it in the calendar app.
     */
    private fun event(row: Item) = RemoteViews(context.packageName, R.layout.widget_event).apply {
        val event = row.event!!
        card(row)
        setInt(R.id.widget_event_icon, "setColorFilter", row.colour)
        setTextViewText(R.id.widget_title, row.title)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            setOnClickFillInIntent(R.id.widget_card, opening(fillIn(TodayWidget.OP_EVENT, row.id), event))
        } else {
            setOnClickPendingIntent(
                R.id.widget_card,
                tap(TodayWidget.OP_EVENT, row.id) { opening(it, event) },
            )
        }
    }

    /** [intent], saying which occurrence of [event] to open. */
    private fun opening(intent: Intent, event: PhoneEvents.Event) = intent
        .putExtra(TodayWidget.EXTRA_EVENT, event.id)
        .putExtra(TodayWidget.EXTRA_BEGIN, event.begin)
        .putExtra(TodayWidget.EXTRA_END, event.end)

    /** Which task, and which tap, for the list's intent. */
    private fun fillIn(op: String, id: Long) = Intent()
        .putExtra(TodayWidget.EXTRA_OP, op)
        .putExtra(TodayWidget.EXTRA_TASK, id)

    /**
     * A tap on a card before Android 12: an intent of its own, one per task
     * and tap, since there is no list to hold a template.
     */
    private fun tap(
        op: String,
        id: Long,
        more: (Intent) -> Intent = { it },
    ): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, TodayWidget::class.java)
            .setAction(TodayWidget.ACTION_ITEM)
            // One intent per task and tap, not one shared and overwritten.
            .setData(Uri.parse("caldo://widget/$op/$id"))
            .putExtra(TodayWidget.EXTRA_OP, op)
            .putExtra(TodayWidget.EXTRA_TASK, id)
            .let(more),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

    /** What every task row has, whichever tick it wears. */
    private fun RemoteViews.card(row: Item) {
        setInt(R.id.widget_ink, "setColorFilter", row.colour)
        setTextViewText(
            R.id.widget_time,
            when {
                row.minute == null -> words.getString(R.string.widget_all_day)
                row.end == null -> time(row.minute)
                // As the app writes it on its cards.
                else -> "${time(row.minute)} – ${time(row.end)}"
            },
        )
        setTextColor(R.id.widget_time, if (row.late) OVERDUE else MUTED)
    }

    private fun crossedOut(title: String) = SpannableString(title).apply {
        setSpan(StrikethroughSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
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
        setInt(R.id.widget_ink, "setImageAlpha", if (row.done) INK_DONE else INK)
        setTextViewText(R.id.widget_title, if (row.done) crossedOut(row.title) else row.title)
        setTextColor(R.id.widget_title, if (row.done) FAINT else TEXT)
        setImageViewResource(
            R.id.widget_tick,
            if (row.done) R.drawable.widget_tick_done else R.drawable.widget_tick_open,
        )
        setInt(R.id.widget_tick, "setColorFilter", row.colour)
        setViewVisibility(R.id.widget_check, if (row.done) View.VISIBLE else View.GONE)
        setOnClickPendingIntent(R.id.widget_tick_area, tap(TodayWidget.OP_TOGGLE, row.id))
        setOnClickPendingIntent(R.id.widget_card, tap(TodayWidget.OP_OPEN, row.id))
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

    companion object {
        // The app's dark palette (`AppColors`).
        private const val TEXT = 0xFFE9E9EB.toInt()
        private const val MUTED = 0xFF9B9BA1.toInt()
        private const val FAINT = 0xFF6A6A70.toInt()
        private const val OVERDUE = 0xFFE05252.toInt()

        /**
         * The card's ink before Android 12, out of 255, as the app inks it
         * over the same black: a quarter of the task's colour, and a
         * fourteenth once done. From Android 12 the same is played out by
         * animator/widget_ink.xml.
         */
        private const val INK = 61
        private const val INK_DONE = 18

        private const val MOST = 60

        /** How many days past today events are read for: the agenda's. */
        private const val DAYS = 31
        private const val DAY_MS = 24 * 60 * 60 * 1000L

        /** Where events' keys start, clear of any task's id. */
        private const val EVENT_KEYS = 1_000_000_000L

        /**
         * Where each widget last laid out each heading and card, by key, so
         * what has moved can be drawn back there and slide. Held in memory:
         * the process lives from a tick to the drawing that moves its card,
         * and a view missing here is only drawn in its place.
         */
        private val placed = mutableMapOf<Int, Map<Int, Int>>()

        /** Heights and title lines [fit] has worked out, by what was measured. */
        private val measured = HashMap<String, Pair<Int, Int>>()

        /** What each widget last drew leaving, so only a new leaver closes up. */
        private val left = mutableMapOf<Int, Set<Int>>()

        /**
         * Tasks ticked on the widget that are fading out of the run they are
         * in ([TodayWidget.tick]) — out of the backlog, or rolling on to
         * another date — drawn in their place but taking no room.
         */
        val leaving: MutableSet<Long> = mutableSetOf()

        /** `ListStyle`'s swatches, each with its row (see [box]). */
        private val SWATCHES = mapOf(
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

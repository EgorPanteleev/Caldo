package com.igor.caldo

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import kotlin.math.roundToInt

/**
 * The home-screen widget: what is overdue and what is coming, each with a
 * tick that works without opening the app.
 *
 * It draws from a copy of the agenda the app leaves in its preferences
 * (`today_widget.dart`), and is redrawn whenever that copy changes
 * ([CaldoApplication]). A tick is shown at once, in the copy, and then done
 * for real by Dart on an engine of its own ([Headless]) — which writes the
 * task, puts its alarm right and leaves a fresh copy behind it.
 */
class TodayWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context, manager, id))
        wakeAtMidnight(context)
    }

    // Resized: the cards are placed by their measured heights, and a title
    // that wraps at one width need not at another.
    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        options: Bundle,
    ) {
        manager.updateAppWidget(id, views(context, manager, id))
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_ITEM -> {
                val id = intent.getLongExtra(EXTRA_TASK, -1)
                if (id < 0) return
                when (intent.getStringExtra(EXTRA_OP)) {
                    // The box says what it now is, where it is a box; an
                    // older phone's tick is a plain tap, and turns over.
                    OP_TOGGLE -> tick(
                        context,
                        id,
                        if (intent.hasExtra(RemoteViews.EXTRA_CHECKED)) {
                            intent.getBooleanExtra(RemoteViews.EXTRA_CHECKED, false)
                        } else {
                            null
                        },
                    )
                    OP_OPEN -> context.startActivity(openApp(context, id))
                    OP_EVENT -> try {
                        context.startActivity(
                            PhoneEvents.view(
                                intent.getLongExtra(EXTRA_EVENT, -1),
                                intent.getLongExtra(EXTRA_BEGIN, 0),
                                intent.getLongExtra(EXTRA_END, 0),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                    } catch (_: android.content.ActivityNotFoundException) {
                        // No app on the phone keeps a calendar to open it in.
                    }
                }
            }
            ACTION_MIDNIGHT -> refresh(context)
            else -> super.onReceive(context, intent)
        }
    }

    /**
     * Ticks [id] — or takes the tick back — as [done] says, or turns it
     * over when the tap does not say.
     *
     * Played step for step as the app plays it (`TaskProvider.toggleDone`).
     * From Android 12 the box is a checkbox the launcher animates itself the
     * moment it is tapped, the square filling and the check drawn through
     * it. [SETTLE] after the tap — the tick and then a beat — the card is
     * crossed out. A card that stays in its run holds there [HOLD] and then
     * slides to the end of its day; one that leaves its run — out of the
     * backlog, rolling on to its next date — fades while the cards after it
     * close up, over [LEAVE]. Taken back, a tick is un-crossed at once and
     * the run read back once the box has emptied.
     *
     * The moves are worked out here, in the copy, rather than waited for:
     * Dart writes the task only once the card has gone where it is going,
     * and its copy, landing tens of milliseconds later, then says what is
     * already shown. Asked any sooner, a warm engine's copy rebuilt the row
     * before its square had filled. The receiver is held open until Dart has
     * finished, or the process could be let go mid-write.
     */
    private fun tick(context: Context, id: Long, done: Boolean?) {
        val task = task(context, id) ?: return
        val ticking = done ?: !task.getBoolean("done")
        val pending = goAsync()
        val main = Handler(Looper.getMainLooper())
        val args = mapOf<String, Any>("id" to id, "done" to ticking)
        // A last drawing once Dart is done, should its copy say nothing new:
        // a card that was leaving is shown again if it has only rolled on.
        val write = Runnable {
            Headless.call(context, "toggle", args) {
                refresh(context)
                pending.finish()
            }
        }
        if (!ticking) {
            mark(context, id, false)
            main.postDelayed(write, UNSETTLE)
            return
        }
        val prefs = prefs(context)
        val leaves = task.getString("day") < today() ||
            task.optBoolean("repeats") ||
            !prefs.getBoolean(KEY_SHOW_DONE, true)
        main.postDelayed({
            if (leaves) TodayWidgetRuns.leaving.add(id)
            mark(context, id, true)
        }, SETTLE)
        if (leaves) {
            main.postDelayed({
                TodayWidgetRuns.leaving.remove(id)
                write.run()
            }, SETTLE + LEAVE)
        } else {
            main.postDelayed({
                last(context, id)
                write.run()
            }, SETTLE + HOLD)
        }
    }

    /** Task [id] as the copy has it. */
    private fun task(context: Context, id: Long): JSONObject? {
        val copy = prefs(context).getString(KEY, null) ?: return null
        val tasks = JSONObject(copy).getJSONArray("tasks")
        for (i in 0 until tasks.length()) {
            if (tasks.getJSONObject(i).getLong("id") == id) return tasks.getJSONObject(i)
        }
        return null
    }

    private fun today() = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Calendar.getInstance().time)

    /** Shows [id] ticked or not in the copy, ahead of Dart's own. */
    private fun mark(context: Context, id: Long, done: Boolean) {
        edit(context) { tasks ->
            for (i in 0 until tasks.length()) {
                val task = tasks.getJSONObject(i)
                if (task.getLong("id") == id) task.put("done", done)
            }
        }
    }

    /**
     * Moves [id] to the end of its day in the copy, where the app puts a
     * task just ticked: after its day's open tasks and after every task
     * ticked before it.
     */
    private fun last(context: Context, id: Long) {
        edit(context) { tasks ->
            val at = (0 until tasks.length()).firstOrNull { tasks.getJSONObject(it).getLong("id") == id }
                ?: return@edit
            val task = tasks.getJSONObject(at)
            val day = task.getString("day")
            tasks.remove(at)
            val end = (0 until tasks.length()).lastOrNull { tasks.getJSONObject(it).getString("day") == day }
            // A JSONArray only appends; the rest is moved along by hand.
            val to = if (end == null) at else end + 1
            tasks.put(task)
            for (i in tasks.length() - 1 downTo to + 1) tasks.put(i, tasks.getJSONObject(i - 1))
            tasks.put(to, task)
        }
    }

    private fun edit(context: Context, change: (JSONArray) -> Unit) {
        val prefs = prefs(context)
        val copy = prefs.getString(KEY, null) ?: return
        val json = JSONObject(copy)
        change(json.getJSONArray("tasks"))
        prefs.edit().putString(KEY, json.toString()).apply()
    }

    companion object {
        const val ACTION_ITEM = "com.igor.caldo.widget.ITEM"
        const val ACTION_MIDNIGHT = "com.igor.caldo.widget.MIDNIGHT"
        const val EXTRA_OP = "op"
        const val EXTRA_TASK = "task"
        const val OP_TOGGLE = "toggle"
        const val OP_OPEN = "open"
        const val OP_EVENT = "event"
        const val EXTRA_EVENT = "event"
        const val EXTRA_BEGIN = "begin"
        const val EXTRA_END = "end"

        /**
         * From the tap to the card being crossed out: the tick drawn, then
         * a beat (`TaskProvider.settle` and `linger`).
         */
        const val SETTLE = 490L

        /** From a tick taken back to the run read back (`TaskProvider.settle`). */
        const val UNSETTLE = 240L

        /** From crossed out to moving to the end of its day (`TaskProvider.hold`). */
        const val HOLD = 150L

        /** The id of the list's one row (see [views]). */
        private const val PAGE = 1L

        /** How long a leaving card takes to fade and close up (`TaskProvider.leave`). */
        const val LEAVE = 280L

        /** Read by [MainActivity]: the task a tap asked to have opened. */
        const val EXTRA_OPEN_TASK = "caldo.open_task"

        /** Read by [MainActivity]: the add button was tapped. */
        const val EXTRA_NEW_TASK = "caldo.new_task"

        /** Where the app leaves the copy, as `shared_preferences` writes it. */
        const val PREFS = "FlutterSharedPreferences"
        const val KEY = "flutter.today_widget"
        const val KEY_SHOW_DONE = "flutter.show_completed"
        const val KEY_24_HOUR = "flutter.use_24_hour"

        fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /**
         * The language the app is speaking, which the copy carries: the
         * widget is drawn by the launcher in the phone's language, and the
         * one chosen in Caldo's Settings need not be that.
         */
        fun language(context: Context): Locale {
            val copy = prefs(context).getString(KEY, null) ?: return Locale.getDefault()
            val code = runCatching { JSONObject(copy).optString("lang") }.getOrNull()
            return if (code.isNullOrEmpty()) Locale.getDefault() else Locale(code)
        }

        /** [context] answering in [locale], for the widget's own words. */
        fun speaking(context: Context, locale: Locale): Context =
            context.createConfigurationContext(
                Configuration(context.resources.configuration).apply { setLocale(locale) },
            )

        /**
         * A date pattern for [skeleton] — which fields, in no order — as
         * [locale] orders and punctuates them: "d MMMM" is "2 ноября" in
         * Russian and "2. November" in German. English keeps the order
         * the app writes it in, day before month.
         */
        fun pattern(locale: Locale, skeleton: String, english: String): String =
            if (locale.language == "en") english
            else android.text.format.DateFormat.getBestDateTimePattern(locale, skeleton)

        /** "понедельник" opens a line as "Понедельник". */
        fun capitalised(text: String, locale: Locale) =
            text.replaceFirstChar { if (it.isLowerCase()) it.titlecase(locale) else it.toString() }

        /** Redraws every copy of the widget on the home screen. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, TodayWidget::class.java))
            if (ids.isEmpty()) return
            for (id in ids) manager.updateAppWidget(id, views(context, manager, id))
        }

        private fun views(context: Context, manager: AppWidgetManager, id: Int): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_today)
            val words = speaking(context, language(context))
            views.setTextViewText(R.id.widget_screen, words.getString(R.string.widget_schedule))
            views.setTextViewText(R.id.widget_empty_text, words.getString(R.string.widget_nothing))
            val runs = TodayWidgetRuns(context, id).apply { load() }
            val width = cardWidth(context, manager, id)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // The agenda is the one row of a list, which scrolls it; the
                // row keeps its id and its layout, so the launcher draws the
                // new one over the view it has rather than making another.
                val page = RemoteViews(context.packageName, R.layout.widget_page)
                runs.addTo(page, R.id.widget_page, width)
                views.setRemoteAdapter(
                    R.id.widget_list,
                    RemoteViews.RemoteCollectionItems.Builder()
                        .addItem(PAGE, page)
                        .setHasStableIds(true)
                        .setViewTypeCount(1)
                        .build(),
                )
                // Inside a list a card cannot carry an intent of its own:
                // each fills in which task and which tap, on this one.
                views.setPendingIntentTemplate(
                    R.id.widget_list,
                    PendingIntent.getBroadcast(
                        context,
                        0,
                        Intent(context, TodayWidget::class.java).setAction(ACTION_ITEM),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                    ),
                )
            } else {
                runs.addTo(views, R.id.widget_runs, width)
            }
            views.setViewVisibility(R.id.widget_empty, if (runs.isEmpty) View.VISIBLE else View.GONE)
            views.setOnClickPendingIntent(
                R.id.widget_header,
                PendingIntent.getActivity(
                    context,
                    1,
                    openApp(context, null),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            views.setOnClickPendingIntent(
                R.id.widget_add,
                PendingIntent.getActivity(
                    context,
                    2,
                    openApp(context, null).putExtra(EXTRA_NEW_TASK, true),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            return views
        }

        /**
         * How wide widget [id]'s cards are, in pixels: its width on the home
         * screen as the phone is held now, less its padding. The launcher
         * reports the width upright as the least and on its side as the
         * most.
         */
        private fun cardWidth(context: Context, manager: AppWidgetManager, id: Int): Int {
            val res = context.resources
            val options = manager.getAppWidgetOptions(id)
            val dp = options.getInt(
                if (res.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
                    AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH
                } else {
                    AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH
                },
            )
            val width = if (dp > 0) dp * res.displayMetrics.density else res.displayMetrics.widthPixels.toFloat()
            return (width - 2 * res.getDimension(R.dimen.widget_padding)).roundToInt()
        }

        /**
         * The app brought forward — onto [task]'s form when there is one.
         * Brought forward rather than started again: a Caldo already open
         * is handed the request ([MainActivity.onNewIntent]).
         */
        private fun openApp(context: Context, task: Long?) =
            Intent(context, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
                if (task != null) putExtra(EXTRA_OPEN_TASK, task)
            }

        /**
         * The runs are sorted into Today, Tomorrow and the rest when the
         * widget is drawn, so it has to be drawn again when the date
         * changes — the copy is the same, but yesterday's Today is not.
         */
        private fun wakeAtMidnight(context: Context) {
            val midnight = Calendar.getInstance().apply {
                add(Calendar.DAY_OF_MONTH, 1)
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 5)
                set(Calendar.MILLISECOND, 0)
            }
            val alarm = context.getSystemService(AlarmManager::class.java) ?: return
            alarm.set(
                AlarmManager.RTC,
                midnight.timeInMillis,
                PendingIntent.getBroadcast(
                    context,
                    3,
                    Intent(context, TodayWidget::class.java).setAction(ACTION_MIDNIGHT),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
    }
}

/**
 * Runs Dart for the widget while the app may not be open, on one engine
 * kept for the life of the process and fed one request at a time.
 *
 * One engine rather than one per tap: two ticks in quick succession on two
 * engines would each redraw the widget from their own read of the database,
 * and whichever finished last would win even if it read first.
 */
object Headless {
    private const val CHANNEL = "caldo/headless"

    /** Long enough for a cold engine; short of the receiver's own limit. */
    private const val PATIENCE = 9_000L

    private class Request(val method: String, val args: Map<String, Any>, val done: () -> Unit)

    private var channel: io.flutter.plugin.common.MethodChannel? = null
    private var ready = false
    private val waiting = ArrayDeque<Request>()
    private val main = Handler(Looper.getMainLooper())

    fun call(context: Context, method: String, args: Map<String, Any>, done: () -> Unit) {
        // Once only, whether Dart answers or the wait runs out.
        var finished = false
        val once = {
            if (!finished) {
                finished = true
                done()
            }
        }
        main.postDelayed(once, PATIENCE)
        waiting.addLast(Request(method, args, once))
        if (channel == null) start(context.applicationContext) else if (ready) drain()
    }

    private fun start(context: Context) {
        val loader = io.flutter.FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)
        val engine = io.flutter.embedding.engine.FlutterEngine(context)
        channel = io.flutter.plugin.common.MethodChannel(
            engine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "ready") {
                    ready = true
                    drain()
                }
                result.success(null)
            }
        }
        engine.dartExecutor.executeDartEntrypoint(
            io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "package:caldo/services/background.dart",
                "widgetMain",
            ),
        )
    }

    private fun drain() {
        val channel = channel ?: return
        while (waiting.isNotEmpty()) {
            val request = waiting.removeFirst()
            channel.invokeMethod(
                request.method,
                request.args,
                object : io.flutter.plugin.common.MethodChannel.Result {
                    override fun success(result: Any?) = request.done()

                    override fun error(code: String, message: String?, details: Any?) =
                        request.done()

                    override fun notImplemented() = request.done()
                },
            )
        }
    }
}

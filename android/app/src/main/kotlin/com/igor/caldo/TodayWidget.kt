package com.igor.caldo

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale

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
        for (id in ids) manager.updateAppWidget(id, views(context, id))
        manager.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
        wakeAtMidnight(context)
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
     * Played as the app's card plays it. From Android 12 the box is a
     * checkbox the launcher animates itself the moment it is tapped, the
     * square filling and the check drawn through it; [SETTLE] after the tap
     * — the tick and then a beat — the copy is changed and the card is
     * crossed out; [HOLD] after that Dart writes the task, and its copy puts
     * the card at the end of its day. Taking a tick back goes at once.
     *
     * Dart is held back as well as the copy: a warm engine wrote the task
     * and its copy within a few tens of milliseconds, the row was rebuilt
     * under the tick before its square had filled, and a tick that was a
     * quarter of a second in the app was a blink on the home screen. The
     * receiver is held open until Dart has finished, or the process could
     * be let go mid-write.
     */
    private fun tick(context: Context, id: Long, done: Boolean?) {
        val pending = goAsync()
        val settle = if (done == false) UNSETTLE else SETTLE
        val hold = if (done == false) 0L else HOLD
        val main = Handler(Looper.getMainLooper())
        main.postDelayed({ mark(context, id, done) }, settle)
        val args = buildMap<String, Any> {
            put("id", id)
            if (done != null) put("done", done)
        }
        main.postDelayed({ Headless.call(context, "toggle", args) { pending.finish() } }, settle + hold)
    }

    /** Shows [id] ticked or not in the copy, ahead of Dart's own. */
    private fun mark(context: Context, id: Long, done: Boolean?) {
        val prefs = prefs(context)
        val copy = prefs.getString(KEY, null) ?: return
        val json = JSONObject(copy)
        val tasks = json.getJSONArray("tasks")
        for (i in 0 until tasks.length()) {
            val task = tasks.getJSONObject(i)
            if (task.getLong("id") == id) task.put("done", done ?: !task.getBoolean("done"))
        }
        prefs.edit().putString(KEY, json.toString()).apply()
    }

    companion object {
        const val ACTION_ITEM = "com.igor.caldo.widget.ITEM"
        const val ACTION_MIDNIGHT = "com.igor.caldo.widget.MIDNIGHT"
        const val EXTRA_OP = "op"
        const val EXTRA_TASK = "task"
        const val OP_TOGGLE = "toggle"
        const val OP_OPEN = "open"

        /**
         * From the tap to the card being crossed out: the tick drawn, then
         * a beat (`TaskProvider.settle` and `linger`).
         */
        const val SETTLE = 490L

        /** How long a tick takes to come off (`_Tick`'s reverse). */
        const val UNSETTLE = 110L

        /** From crossed out to moving to the end of its day (`TaskProvider.hold`). */
        const val HOLD = 150L

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
            for (id in ids) manager.updateAppWidget(id, views(context, id))
            manager.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
        }

        private fun views(context: Context, widgetId: Int): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_today)
            val words = speaking(context, language(context))
            views.setTextViewText(R.id.widget_screen, words.getString(R.string.widget_schedule))
            views.setTextViewText(R.id.widget_empty_text, words.getString(R.string.widget_nothing))
            // The data URI tells one widget's list apart from another's;
            // without it Android hands every widget the first one's factory.
            val adapter = Intent(context, TodayWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
            }
            views.setRemoteAdapter(R.id.widget_list, adapter)
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)
            // One template for every row; each row fills in which task and
            // whether its tick or the rest of it was tapped.
            views.setPendingIntentTemplate(
                R.id.widget_list,
                PendingIntent.getBroadcast(
                    context,
                    0,
                    Intent(context, TodayWidget::class.java).setAction(ACTION_ITEM),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                ),
            )
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

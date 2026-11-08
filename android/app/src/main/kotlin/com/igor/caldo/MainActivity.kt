package com.igor.caldo

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.CalendarContract
import android.provider.Settings
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Two things Flutter's stock activity does not do for us.
 *
 * The first is asking for the panel's fastest mode: a window gets 60Hz on a
 * 120Hz screen unless it asks, which is why the app felt like half the
 * refresh rate the phone is capable of. The ask is for the fastest mode *at
 * the resolution already in use* — the list of supported modes mixes
 * resolutions, and taking the fastest of all of them can drop the screen to
 * a coarser one to get there.
 *
 * The second is telling Dart where the keyboard is, in a measurement that
 * means the same thing at every moment of a slide — which `viewInsets` does
 * not. See [send].
 */
class MainActivity : FlutterActivity() {
    private var imeSink: EventChannel.EventSink? = null

    /**
     * How much of the display lies below this window — the navigation bar
     * when the window stops above it, nothing when it is drawn edge to
     * edge. Worked out in [send] from [contentNav].
     */
    private var below = 0

    /**
     * The navigation bar as the content view is told about it: zero when
     * the window fits the system bars, because they have been taken out of
     * the insets before they reach it, and the bar's own height when the
     * window is drawn edge to edge. Negative until it has been told
     * anything.
     */
    private var contentNav = -1

    /** Where the home-screen widget asks the app to go ([TodayWidget]). */
    private var launches: MethodChannel? = null

    /** A request to read the calendars, waiting on the user's answer. */
    private var askingCalendars: MethodChannel.Result? = null

    /** The backup waiting on the document picker, and what it is to write. */
    private var backupAnswer: MethodChannel.Result? = null
    private var backupText: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useFastestRefreshRate()
        wakeFor(intent)
    }

    /** The reminder over the lock screen, while one is up. */
    private val cover by lazy { ReminderCover(this, ::answered) }

    /**
     * A reminder's own intent — the one the notification plugin puts on it,
     * for a tap and for taking the screen — puts the reminder up full screen,
     * over the lock screen, but only while the phone is locked or asleep: a
     * tap with the phone in use opens the task instead (Dart asks
     * `covered`). Leaving the app, or answering, gives the lock screen back:
     * the app is never left showing on a locked phone.
     */
    private fun wakeFor(intent: Intent?) {
        if (intent?.action != REMINDER_ACTION || !isLocked()) return
        if (cover.show(intent)) overLock(true)
    }

    private fun isLocked(): Boolean {
        val keyguard = getSystemService(KeyguardManager::class.java)
        val power = getSystemService(PowerManager::class.java)
        return keyguard?.isKeyguardLocked == true || power?.isInteractive == false
    }

    /**
     * The reminder has been answered or put aside: off the lock screen, and
     * out of the way if the phone is still locked, so it goes back to its
     * lock screen rather than to the app.
     */
    private fun answered() {
        cover.hide()
        overLock(false)
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard?.isKeyguardLocked == true) moveTaskToBack(true)
    }

    @Deprecated("Flutter's activity still routes Back through here")
    override fun onBackPressed() {
        if (cover.shown) answered() else super.onBackPressed()
    }

    private fun overLock(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
    }

    /**
     * Whether a reminder may take the screen. Android 14 made it a
     * permission the user can take away, and some phones' own builds of it
     * start with it taken; before that it was always allowed.
     */
    private fun canFullScreen(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
            getSystemService(NotificationManager::class.java)
                ?.canUseFullScreenIntent() != false

    /** Opens the page where Caldo is allowed to take the screen. */
    private fun allowFullScreen(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                    Uri.parse("package:$packageName"),
                ),
            )
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    override fun onStop() {
        super.onStop()
        overLock(false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, IME_CHANNEL)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                        imeSink = sink
                        reportIme()
                    }

                    override fun onCancel(args: Any?) {
                        imeSink = null
                    }
                },
            )
        watchIme()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> result.success(updateInfo())
                    "install" -> result.success(install(call.argument<String>("path")!!))
                    else -> result.notImplemented()
                }
            }
        // The request the app was started with is asked for once Dart is
        // ready to act on it; one made while it is open is sent straight on.
        launches = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIDGET_CHANNEL)
            .apply {
                setMethodCallHandler { call, result ->
                    if (call.method == "take") {
                        result.success(launchRequest(intent))
                        intent.removeExtra(TodayWidget.EXTRA_OPEN_TASK)
                        intent.removeExtra(TodayWidget.EXTRA_NEW_TASK)
                    } else {
                        result.notImplemented()
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALENDARS_CHANNEL)
            .setMethodCallHandler(::calendarCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKUP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "save" -> {
                        backupText = call.argument<String>("text")!!
                        pick(
                            Intent(Intent.ACTION_CREATE_DOCUMENT)
                                .addCategory(Intent.CATEGORY_OPENABLE)
                                .setType("application/json")
                                .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name")),
                            SAVE_BACKUP,
                            result,
                        )
                    }
                    // Any type: Drive and the rest do not all call a .json
                    // file JSON, and Dart says whether it is a backup.
                    "open" -> pick(
                        Intent(Intent.ACTION_OPEN_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("*/*"),
                        OPEN_BACKUP,
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REMINDER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "covered" -> result.success(cover.shown)
                    "canFullScreen" -> result.success(canFullScreen())
                    "allowFullScreen" -> result.success(allowFullScreen())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * The phone's own calendars, read and never written: the events in them
     * are shown beside the tasks the way public holidays are. Everything is
     * read off the main thread — a busy calendar is not instant — and
     * answered back on it.
     */
    private fun calendarCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permitted" -> result.success(canReadCalendars())
            "ask" -> {
                if (canReadCalendars()) {
                    result.success(true)
                } else {
                    askingCalendars?.success(false)
                    askingCalendars = result
                    requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR), ASK_CALENDARS)
                }
            }
            "calendars" -> readOffMain(result) { calendars() }
            "events" -> {
                val from = call.argument<Number>("from")!!.toLong()
                val to = call.argument<Number>("to")!!.toLong()
                readOffMain(result) { events(from, to) }
            }
            "open" -> result.success(
                openEvent(
                    call.argument<Number>("id")!!.toLong(),
                    call.argument<Number>("begin")!!.toLong(),
                    call.argument<Number>("end")!!.toLong(),
                ),
            )
            else -> result.notImplemented()
        }
    }

    /**
     * A backup is a file the user keeps somewhere else, chosen in Android's
     * own picker, which can hand over a document on Drive as readily as one
     * in Downloads and needs no storage permission. Answered with null when
     * the picker is backed out of.
     */
    private fun pick(intent: Intent, code: Int, result: MethodChannel.Result) {
        backupAnswer?.success(null)
        backupAnswer = result
        try {
            startActivityForResult(intent, code)
        } catch (_: ActivityNotFoundException) {
            backupAnswer = null
            result.success(null)
        }
    }

    @Deprecated("Flutter's activity is not an AndroidX one, so it has no result API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAVE_BACKUP && requestCode != OPEN_BACKUP) return
        val result = backupAnswer ?: return
        val text = backupText
        backupAnswer = null
        backupText = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        // Off the main thread: the document may be on Drive.
        Thread {
            val answer: Any? = try {
                if (requestCode == SAVE_BACKUP) {
                    contentResolver.openOutputStream(uri, "w")!!.use {
                        it.write(text!!.toByteArray())
                    }
                    true
                } else {
                    contentResolver.openInputStream(uri)!!.use(::readBackup)
                }
            } catch (e: Exception) {
                e
            }
            runOnUiThread {
                if (answer is Exception) {
                    result.error("io", answer.message, null)
                } else {
                    result.success(answer)
                }
            }
        }.start()
    }

    /**
     * The file as text, or nothing past [BACKUP_LIMIT]: one picked by
     * mistake can be a film, and a backup of years of tasks is a few
     * megabytes. Nothing is a file Dart turns down as not a backup.
     */
    private fun readBackup(input: java.io.InputStream): String {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
            if (out.size() > BACKUP_LIMIT) return ""
        }
        return out.toString(Charsets.UTF_8.name())
    }

    private fun canReadCalendars() =
        checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != ASK_CALENDARS) return
        askingCalendars?.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
        askingCalendars = null
    }

    /** Runs [read] on a thread of its own; nothing at all if not allowed. */
    private fun readOffMain(result: MethodChannel.Result, read: () -> Any) {
        if (!canReadCalendars()) {
            result.success(emptyList<Any>())
            return
        }
        Thread {
            val answer = try {
                read()
            } catch (_: SecurityException) {
                emptyList<Any>()
            }
            runOnUiThread { result.success(answer) }
        }.start()
    }

    private fun calendars(): List<Map<String, Any?>> {
        val columns = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.CALENDAR_COLOR,
        )
        val found = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            columns,
            "${CalendarContract.Calendars.VISIBLE} = 1",
            null,
            "${CalendarContract.Calendars.ACCOUNT_NAME}, " +
                CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
        )?.use { c ->
            while (c.moveToNext()) {
                found.add(
                    mapOf(
                        "id" to c.getLong(0).toString(),
                        "name" to c.getString(1),
                        "account" to c.getString(2),
                        "colour" to c.getInt(3),
                    ),
                )
            }
        }
        return found
    }

    /** Every event between [from] and [to], as Dart reads them. */
    private fun events(from: Long, to: Long): List<Map<String, Any?>> =
        PhoneEvents.between(this, from, to).map {
            mapOf(
                "id" to it.id,
                "begin" to it.begin,
                "end" to it.end,
                "allDay" to it.allDay,
                "title" to it.title,
                "colour" to it.colour,
                "calendar" to it.calendar,
                "calendarName" to it.calendarName,
            )
        }

    /** Shows an event in whichever app keeps the calendar. */
    private fun openEvent(id: Long, begin: Long, end: Long): Boolean = try {
        startActivity(PhoneEvents.view(id, begin, end))
        true
    } catch (_: ActivityNotFoundException) {
        false
    }

    override fun onNewIntent(intent: Intent) {
        // Before the plugins hear of it, so the cover is up by the time Dart
        // asks whether the reminder is on one.
        wakeFor(intent)
        super.onNewIntent(intent)
        launchRequest(intent)?.let { launches?.invokeMethod("open", it) }
    }

    /**
     * What a tap on the widget asked for: a task's form (its id), the form
     * for a new one (no id), or nothing beyond the app itself (null).
     */
    private fun launchRequest(intent: Intent?): Map<String, Any?>? {
        intent ?: return null
        if (intent.getBooleanExtra(TodayWidget.EXTRA_NEW_TASK, false)) return mapOf("task" to null)
        val id = intent.getLongExtra(TodayWidget.EXTRA_OPEN_TASK, -1)
        return if (id >= 0) mapOf("task" to id) else null
    }

    /**
     * What Dart needs to decide whether a release is newer and which of its
     * files to fetch: the installed version, the processor the files are
     * built for, and the private directory the download is written to.
     */
    private fun updateInfo(): Map<String, Any> {
        val version = packageManager.getPackageInfo(packageName, 0).versionName ?: ""
        val dir = File(cacheDir, "updates").apply { mkdirs() }
        return mapOf(
            "version" to version,
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
            "dir" to dir.absolutePath,
        )
    }

    /**
     * Opens the system installer on a downloaded APK. Android lets an app do
     * that only once the user has said it may install apps; until then the
     * settings page for exactly that is opened instead, and Dart is told so
     * it can say why nothing was installed.
     */
    private fun install(path: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ),
            )
            return "needs-permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
        // A task of its own, kept out of the recent apps: left in them, it
        // outlived the install as a blank card beside Caldo. Not in Caldo's
        // own task either — the update clears that task out from under it,
        // and its "Open" then landed on the home screen.
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
            },
        )
        return "started"
    }

    /**
     * How far the keyboard reaches into this window, in logical pixels.
     *
     * One number, from one place, on every frame of a slide and whenever
     * the insets are applied. `Type.ime()` is measured from the bottom of
     * the display, and the window does not always reach that far: below
     * Android 15 it stops above the navigation bar, which is its own
     * window. What the keys take from us is therefore the keyboard's height
     * less whatever lies between our bottom edge and the display's —
     * nothing at all when the window is drawn edge to edge.
     *
     * This replaced a cleverer thing that sent only what Flutter's own
     * `viewInsets.bottom` was missing, and only while an animation was
     * running. Flutter's number is not one measurement: on an edge-to-edge
     * window it leaves the system bar strip out of a slide's animated
     * values and puts it back at the end, but *which* slides leave it out
     * varies — opening, closing and opening again quickly produced one of
     * each. Correcting a number whose meaning changes needs a flag saying
     * which meaning is in force, and a flag that arrives down one channel
     * while the number arrives down another is a race: it was reported as
     * the field sitting a strip too high for the whole of every other
     * opening, and only when the field was opened and closed quickly.
     * Reporting where the keyboard is cannot race with itself.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun send(insets: WindowInsets) {
        val sink = imeSink ?: return
        val ime = insets.getInsets(WindowInsets.Type.ime()).bottom
        val nav = insets.getInsets(WindowInsets.Type.navigationBars()).bottom
        // Whether this window reaches past the system bars is read from
        // what the bars look like *to the content view*, not from how tall
        // that view happens to be. A window that fits them has them taken
        // out of the insets handed down to it; one drawn edge to edge
        // does not. Nothing about that reading moves with `adjustResize`.
        //
        // It used to be worked out from the content view's height against
        // the display's, and that is what four attempts at one bug came
        // down to: `adjustResize` leaves the view between its two heights
        // for a while after the keys have gone, a reading taken then says
        // the window reaches the bottom of the display when it does not,
        // and once believed it was never contradicted — on this phone no
        // honest reading ever says the opposite, because the honest answer
        // is the default. From then on the keyboard was reported a bar too
        // tall, and the field rode a bar above the keys, for the length of
        // every slide.
        // Until the content view has been handed a set of insets to judge
        // by, assume the window stops above the bars: that under-reports
        // the keyboard on a window that does not, and Dart holds the larger
        // of this and its own number, so an under-report costs nothing
        // while an over-report lifts the bar clear of the keys.
        below = when (contentNav) {
            -1 -> nav
            0 -> nav
            else -> 0
        }
        val off = below
        val reach = (ime - off).coerceAtLeast(0)
        val density = resources.displayMetrics.density
        // The raw figures travel with it, for the numbers a long press puts
        // on screen: a recording of a fault is worth a great deal more when
        // what each side of it believed is written across the top.
        sink.success(
            mapOf(
                "reach" to reach / density,
                "ime" to ime / density,
                "nav" to nav / density,
                "below" to off / density,
            ),
        )
    }

    private fun reportIme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val insets = window.decorView.rootWindowInsets ?: return
        send(insets)
    }

    private fun watchIme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        // Every frame of a slide. Attached to the decor view and passed on
        // through the subtree, so the engine's own inset handling runs
        // exactly as it did — this listens, it does not take over.
        window.decorView.setWindowInsetsAnimationCallback(
            object :
                WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onProgress(
                    insets: WindowInsets,
                    running: MutableList<WindowInsetsAnimation>,
                ): WindowInsets {
                    send(insets)
                    return insets
                }

                override fun onEnd(animation: WindowInsetsAnimation) {
                    reportIme()
                }
            },
        )
        // The animation callback covers the slide; this covers everything
        // else — a rotation, a split-screen resize, a keyboard that appears
        // without animating at all.
        window.decorView.setOnApplyWindowInsetsListener { view: View, insets: WindowInsets ->
            send(insets)
            view.onApplyWindowInsets(insets)
        }
        // What the bars look like by the time they reach the content view,
        // which is how [send] tells a window that fits them from one drawn
        // edge to edge. Passed straight on; this only reads.
        findViewById<View>(android.R.id.content)?.setOnApplyWindowInsetsListener {
            view: View,
            insets: WindowInsets,
            ->
            contentNav = insets.getInsets(WindowInsets.Type.navigationBars()).bottom
            view.onApplyWindowInsets(insets)
        }
        // Once the view tree has been laid out and the insets have been
        // round the houses at least once.
        window.decorView.post { reportIme() }
    }

    @Suppress("DEPRECATION")
    private fun useFastestRefreshRate() {
        val display =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
            else windowManager.defaultDisplay
        val current = display?.mode ?: return
        val fastest = display.supportedModes
            ?.filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            ?.maxByOrNull { it.refreshRate }
            ?: return
        if (fastest.modeId == current.modeId) return
        window.attributes = window.attributes.apply {
            preferredDisplayModeId = fastest.modeId
        }
    }

    private companion object {
        const val IME_CHANNEL = "caldo/ime"
        const val UPDATES_CHANNEL = "caldo/updates"
        const val WIDGET_CHANNEL = "caldo/widget"
        const val CALENDARS_CHANNEL = "caldo/calendars"
        const val REMINDER_CHANNEL = "caldo/reminder"
        const val BACKUP_CHANNEL = "caldo/backup"

        /** What the notification plugin calls the intent on a reminder. */
        const val REMINDER_ACTION = "SELECT_NOTIFICATION"
        const val ASK_CALENDARS = 7
        const val SAVE_BACKUP = 8
        const val OPEN_BACKUP = 9
        const val BACKUP_LIMIT = 64 * 1024 * 1024

        /** What a measurement may be out by and still be believed. */
        const val SLACK = 2
    }
}

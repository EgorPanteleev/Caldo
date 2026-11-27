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
import android.provider.DocumentsContract
import android.provider.Settings
import android.animation.ValueAnimator
import android.view.Choreographer
import android.view.View
import android.view.animation.AnimationUtils
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.max

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

    /**
     * The keyboard's slides now running, each null until it has started
     * and then its [Slide]. While any is here the window's own insets are
     * the slide's end, not where the keys are.
     */
    private val slides = HashMap<Any, Slide?>()

    /**
     * One slide of the keyboard as Dart is told it: which it is, the IME
     * inset it runs from and to, and its curve read at [CURVE_STEPS]
     * even steps — sent once, with the slide's first report.
     */
    private class Slide(val id: Int, val from: Int, val to: Int, val curve: DoubleArray) {
        var told = false

        fun along(fraction: Float): Double {
            val at = fraction.coerceIn(0f, 1f) * (curve.size - 1)
            val i = at.toInt().coerceAtMost(curve.size - 2)
            val y = curve[i] + (curve[i + 1] - curve[i]) * (at - i)
            return from + (to - from) * y
        }
    }

    private var slideIds = 0

    /**
     * The vsync of the frame now being made, in `System.nanoTime`'s clock,
     * kept by [clock] while a slide runs. The slide's own animator reads
     * the same frame time, and so does Flutter's.
     */
    private var vsync = 0L
    private var clockRunning = false
    private val clock = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            vsync = frameTimeNanos
            if (slides.isEmpty()) {
                clockRunning = false
            } else {
                Choreographer.getInstance().postFrameCallback(this)
            }
        }
    }

    /** The keyboard's full height, from the last slide's bounds. */
    private var keysOpen = 0

    /**
     * The keyboard's full height while one of its slides runs, else 0: the
     * strip of the screen [ScreenRecord] lays over the app then. The
     * window's own insets are the slide's end — nothing at all from the
     * first frame of a closing — so a recording never showed where the
     * keys really were while they went, only the field following them.
     */
    val keysSliding: Int
        get() = max(if (slides.isNotEmpty()) keysOpen else 0, carry.covers(keysOpen))

    /** The add field as Android carries it on the keys ([KeysCarry]). */
    private val carry by lazy { KeysCarry(this) }

    /** How far the keys reach into the window, px, as [send] last found. */
    private var lastReach = 0

    /** Where the home-screen widget asks the app to go ([TodayWidget]). */
    private var launches: MethodChannel? = null

    /** A request to read the calendars, waiting on the user's answer. */
    private var askingCalendars: MethodChannel.Result? = null

    /** The backup waiting on the document picker, and what it is to write. */
    private var backupAnswer: MethodChannel.Result? = null
    private var backupText: String? = null

    /** The files and photos attached to tasks, and the pickers for them. */
    private val attachments by lazy { Attachments(this) }

    /** The vault's fingerprint, screen and clipboard. */
    private val vault by lazy { Vault(this) }

    /** Settings › Debug's screen recording, once Dart has its channel. */
    private var recording: ScreenRecord? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        carry.attach()
        useFastestRefreshRate()
        wakeFor(intent)
        SelfUpdate.answer(this, intent)
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

    override fun onDestroy() {
        // A recording going keeps what it has.
        recording?.release()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        Push.inFront = true
    }

    override fun onPause() {
        Push.inFront = false
        super.onPause()
    }

    override fun onStop() {
        super.onStop()
        overLock(false)
        if (leftForGood()) LauncherIcon.pick(this)
    }

    /**
     * Whether this stop is the user leaving Caldo rather than something
     * opening over it, which is the only moment the launcher icon can be
     * switched (LauncherIcon): Android closes a task whose launcher entry
     * is switched off. Done on opening, it threw the first launch back to
     * the home screen; on onUserLeaveHint, it did the same under the
     * notification permission's prompt, which counts as the user leaving.
     * So: the screen still on (switched as it goes off, unlocking would
     * land on the home screen), and nothing of another app's over this one
     * in its own task — the backup's document picker, an event opened in
     * the calendar app — which would be closed along with it.
     */
    private fun leftForGood(): Boolean {
        if (isChangingConfigurations) return false
        if (!(getSystemService(POWER_SERVICE) as PowerManager).isInteractive) return false
        val top = (getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager)
            .appTasks.firstOrNull { it.taskInfo.taskId == taskId }?.taskInfo?.topActivity
        return top?.className == MainActivity::class.java.name
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CARRY_CHANNEL)
            .setMethodCallHandler(carry::call)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> result.success(updateInfo())
                    // A web page in the browser: an agent account's sign-in.
                    "open" -> result.success(
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                            true
                        } catch (e: ActivityNotFoundException) {
                            false
                        },
                    )
                    "install" -> install(
                        call.argument<String>("path")!!,
                        call.argument<Map<String, String>>("words") ?: emptyMap(),
                        result,
                    )
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
                        intent.removeExtra(Push.EXTRA_OPEN_CHAT)
                        intent.data = null
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
                    // A folder for the automatic backups, kept for good:
                    // they are written with nobody there to pick a file.
                    "folder" -> pick(
                        Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                        PICK_FOLDER,
                        result,
                    )
                    "write" -> {
                        val folder = Uri.parse(call.argument<String>("folder")!!)
                        val name = call.argument<String>("name")!!
                        val prefix = call.argument<String>("prefix")!!
                        val text = call.argument<String>("text")!!
                        val keep = call.argument<Int>("keep")!!
                        Thread {
                            val failure = try {
                                writeInto(folder, name, prefix, text, keep)
                                null
                            } catch (e: Exception) {
                                e
                            }
                            runOnUiThread {
                                if (failure != null) {
                                    result.error("io", failure.message, null)
                                } else {
                                    result.success(true)
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
        // Both ways: Dart books the daily round while signed in, and the
        // round, when it comes, is run here while this engine lives.
        DailySync.app = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYNC_CHANNEL)
            .apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "keep" -> DailySync.keep(applicationContext)
                        "stop" -> DailySync.stop(applicationContext)
                        else -> return@setMethodCallHandler result.notImplemented()
                    }
                    result.success(null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ATTACHMENTS_CHANNEL)
            .setMethodCallHandler { call, result -> attachments.call(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VAULT_CHANNEL)
            .setMethodCallHandler { call, result -> vault.call(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RECORD_CHANNEL).let { channel ->
            val recording = ScreenRecord(this, channel)
            this.recording = recording
            channel.setMethodCallHandler { call, result -> recording.call(call, result) }
        }
        Push.dart = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PUSH_CHANNEL)
            .apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "token" -> Push.token(
                            applicationContext,
                            call.argument<String>("name"),
                            call.argument<String>("hint"),
                            result,
                        )
                        "looking" -> {
                            val chat = call.arguments as String?
                            Push.looking = chat
                            if (chat != null) Push.seen(applicationContext, chat)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Gone with the engine: a round asked of it now would never answer,
        // and the widget's engine takes the session over.
        DailySync.app = null
        Push.dart = null
        super.cleanUpFlutterEngine(flutterEngine)
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
        if (attachments.answered(requestCode, resultCode, data)) return
        if (recording?.answered(requestCode, resultCode, data) == true) return
        if (requestCode != SAVE_BACKUP && requestCode != OPEN_BACKUP &&
            requestCode != PICK_FOLDER
        ) {
            return
        }
        val result = backupAnswer ?: return
        val text = backupText
        backupAnswer = null
        backupText = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        if (requestCode == PICK_FOLDER) {
            result.success(keepFolder(uri))
            return
        }
        // Off the main thread: the document may be on Drive.
        Thread {
            val answer: Any? = try {
                if (requestCode == SAVE_BACKUP) {
                    // "wt", as the automatic ones are written: some
                    // providers take "w" as leave the old bytes past the
                    // end, and a shorter backup over a longer file is then
                    // JSON with the old one's tail after it.
                    contentResolver.openOutputStream(uri, "wt")!!.use {
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
     * Holds on to [tree] across restarts and lets go of any folder held
     * before it, since only one is written into. Answered with the folder's
     * address and the name it goes by, for Settings to show.
     */
    private fun keepFolder(tree: Uri): Map<String, String>? {
        val both = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            contentResolver.takePersistableUriPermission(tree, both)
        } catch (_: SecurityException) {
            return null
        }
        for (held in contentResolver.persistedUriPermissions) {
            if (held.uri != tree && DocumentsContract.isTreeUri(held.uri)) {
                contentResolver.releasePersistableUriPermission(held.uri, both)
            }
        }
        val folder = DocumentsContract.buildDocumentUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree),
        )
        val name = contentResolver.query(
            folder,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
        return mapOf("uri" to tree.toString(), "name" to (name ?: tree.lastPathSegment ?: ""))
    }

    /**
     * Writes [text] into [tree] as [name], over a file of that name if there
     * is one, and then deletes all but the latest [keep] files starting with
     * [prefix]. The names carry the date, so the latest sort last; files of
     * any other name are the user's and are left alone.
     */
    private fun writeInto(tree: Uri, name: String, prefix: String, text: String, keep: Int) {
        val id = DocumentsContract.getTreeDocumentId(tree)
        val ours = sortedMapOf<String, Uri>()
        contentResolver.query(
            DocumentsContract.buildChildDocumentsUriUsingTree(tree, id),
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null,
            null,
            null,
        )?.use {
            while (it.moveToNext()) {
                val child = it.getString(1) ?: continue
                if (child.startsWith(prefix) && child.endsWith(".json")) {
                    ours[child] = DocumentsContract.buildDocumentUriUsingTree(tree, it.getString(0))
                }
            }
        }
        val file = ours[name] ?: DocumentsContract.createDocument(
            contentResolver,
            DocumentsContract.buildDocumentUriUsingTree(tree, id),
            "application/json",
            name,
        ) ?: throw java.io.IOException("$name could not be made")
        // "wt" cuts an older, longer copy of the same day down to this one.
        contentResolver.openOutputStream(file, "wt")!!.use { it.write(text.toByteArray()) }
        ours[name] = file
        for (old in ours.keys.toList().dropLast(keep)) {
            DocumentsContract.deleteDocument(contentResolver, ours[old]!!)
        }
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
        if (attachments.gallery.permissionAnswered(requestCode)) return
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
        if (SelfUpdate.answer(this, intent)) return
        // Before the plugins hear of it, so the cover is up by the time Dart
        // asks whether the reminder is on one.
        wakeFor(intent)
        super.onNewIntent(intent)
        launchRequest(intent)?.let { launches?.invokeMethod("open", it) }
    }

    /**
     * What a tap on the widget asked for: a task's form (its id), the form
     * for a new one (no id), or nothing beyond the app itself (null). Or an
     * invite link followed, caldo://invite/<code>, or a chat's notification
     * tapped (Push).
     */
    private fun launchRequest(intent: Intent?): Map<String, Any?>? {
        intent ?: return null
        val link = intent.data
        if (intent.action == Intent.ACTION_VIEW && link?.scheme == "caldo" && link.host == "invite") {
            return link.lastPathSegment?.let { mapOf("invite" to it) }
        }
        intent.getStringExtra(Push.EXTRA_OPEN_CHAT)?.let { return mapOf("chat" to it) }
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
     * Installs a downloaded APK over this one ([SelfUpdate]). Android lets
     * an app do that only once the user has said it may install apps; until
     * then the settings page for exactly that is opened instead, and Dart is
     * told so it can say why nothing was installed. The copy into the
     * session is twenty to sixty megabytes, so it is made off this thread.
     */
    private fun install(path: String, words: Map<String, String>, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ),
            )
            result.success("needs-permission")
            return
        }
        Thread {
            val outcome = runCatching { SelfUpdate.install(applicationContext, File(path), words) }
            runOnUiThread {
                outcome.fold(
                    { result.success("started") },
                    { result.error("install", it.message, null) },
                )
            }
        }.start()
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
    private fun send(
        insets: WindowInsets,
        sliding: Boolean = false,
        running: List<WindowInsetsAnimation> = emptyList(),
    ) {
        val keys = insets.getInsets(WindowInsets.Type.ime()).bottom
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
        val reach = (keys - off).coerceAtLeast(0)
        lastReach = reach
        val sink = imeSink ?: return
        val density = resources.displayMetrics.density
        // The raw figures travel with it, for the numbers a long press puts
        // on screen: a recording of a fault is worth a great deal more when
        // what each side of it believed is written across the top.
        // `sliding` rides in the same message as the number it qualifies,
        // so the two cannot arrive apart.
        val report = mutableMapOf<String, Any>(
            "reach" to reach / density,
            "ime" to keys / density,
            "nav" to nav / density,
            "below" to off / density,
            "sliding" to sliding,
            // Android 11 and later carry the add field on the keys.
            "carries" to true,
        )
        if (sliding) {
            report["at"] = frameNow() / 1000
            report["period"] = framePeriod() / 1000.0
            clockOf(keys, running)?.let { report.putAll(it) }
        }
        sink.success(report)
    }

    /**
     * The vsync of the frame now being made, in `System.nanoTime`'s clock:
     * [clock]'s reading when it has run this frame — it is posted from
     * onPrepare, and so can miss a slide's first frame — else the
     * animation clock, which Android holds at the frame's time to the
     * millisecond.
     */
    private fun frameNow(): Long {
        val frameMs = AnimationUtils.currentAnimationTimeMillis()
        return if (vsync / 1_000_000 == frameMs) vsync else frameMs * 1_000_000 + 500_000
    }

    /** How long a frame of the display lasts, in nanoseconds. */
    @Suppress("DEPRECATION")
    private fun framePeriod(): Double {
        val display =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
            else windowManager.defaultDisplay
        val rate = display?.refreshRate ?: 60f
        return 1e9 / (if (rate > 1f) rate else 60f)
    }

    /**
     * The slide under way as a clock Dart can read for itself, or null
     * when it cannot be read as one.
     *
     * A report made in Android's frame reaches Dart after Flutter has
     * begun its own frame for that vsync: in a 2.11.23 recording from the
     * 120Hz Galaxy every report of an opening came 0.2–1.1ms after the
     * frame it belonged to had started, so the field was drawn a frame
     * behind the keys, every frame. Reading a few milliseconds ahead
     * (2.11.23–2.11.27) only moved the error from one side to the other,
     * and it rode on when each message happened to land. So Dart is given
     * the slide itself — where it was at which vsync, how long it runs and
     * its curve — and places the field for the vsync each of its frames
     * starts at, on the same clock. Messages then only correct the clock;
     * when one lands no longer matters.
     *
     * Only when the curve read at the slide's fraction gives back what is
     * being reported; a slide driven by a finger (Android 16's swipe
     * back) has no length or curve, and Dart carries its last two reports
     * on instead.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun clockOf(keys: Int, running: List<WindowInsetsAnimation>): Map<String, Any>? {
        val near = 2 * resources.displayMetrics.density
        val scale = ValueAnimator.getDurationScale()
        for (animation in running) {
            if (animation.typeMask and WindowInsets.Type.ime() == 0) continue
            val slide = slides[animation] ?: continue
            val length = animation.durationMillis * scale
            if (length <= 0) continue
            if (Math.abs(slide.along(animation.fraction) - keys) > near) continue
            val density = resources.displayMetrics.density
            val clock = mutableMapOf<String, Any>(
                "slide" to slide.id,
                "fraction" to animation.fraction.toDouble(),
                "length" to length.toDouble(),
                "from" to slide.from / density,
                "to" to slide.to / density,
            )
            if (!slide.told) {
                clock["curve"] = slide.curve.toList()
                slide.told = true
            }
            return clock
        }
        return null
    }

    private fun reportIme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val insets = window.decorView.rootWindowInsets ?: return
        send(insets)
    }

    /**
     * The keys' slides are over. Dart hears where they came to rest first,
     * so it draws its field there, and then says so ([KeysCarry]).
     */
    private fun rested() {
        reportIme()
        carry.settle(lastReach)
    }

    private fun watchIme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        // Every frame of a slide. Attached to the decor view and passed on
        // through the subtree, so the engine's own inset handling runs
        // exactly as it did — this listens, it does not take over.
        window.decorView.setWindowInsetsAnimationCallback(
            object :
                WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onPrepare(animation: WindowInsetsAnimation) {
                    if (animation.typeMask and WindowInsets.Type.ime() != 0) {
                        slides[animation] = null
                        if (!clockRunning) {
                            clockRunning = true
                            Choreographer.getInstance().postFrameCallback(clock)
                        }
                        // One prepared and then dropped before it starts
                        // gets no end, and must not hold the reports up.
                        window.decorView.postDelayed({
                            if (slides.containsKey(animation) && slides[animation] == null) {
                                slides.remove(animation)
                                if (slides.isEmpty()) rested()
                            }
                        }, 500)
                        // The field goes up over Flutter's where it stands,
                        // before anything moves, and Dart is told to leave
                        // its own undrawn.
                        if (carry.prepare(lastReach)) imeSink?.success(mapOf("carry" to true))
                    }
                }

                override fun onStart(
                    animation: WindowInsetsAnimation,
                    bounds: WindowInsetsAnimation.Bounds,
                ): WindowInsetsAnimation.Bounds {
                    if (animation.typeMask and WindowInsets.Type.ime() != 0) {
                        // The window's insets are already the slide's end,
                        // so they say which way it goes.
                        val opening = window.decorView.rootWindowInsets
                            ?.isVisible(WindowInsets.Type.ime()) ?: true
                        val shut = bounds.lowerBound.bottom
                        val open = bounds.upperBound.bottom
                        if (open > 0) keysOpen = open
                        val curve = animation.interpolator
                        slides[animation] = Slide(
                            ++slideIds,
                            if (opening) shut else open,
                            if (opening) open else shut,
                            DoubleArray(CURVE_STEPS + 1) { i ->
                                val x = i.toFloat() / CURVE_STEPS
                                (curve?.getInterpolation(x) ?: x).toDouble()
                            },
                        )
                    }
                    return bounds
                }

                override fun onProgress(
                    insets: WindowInsets,
                    running: MutableList<WindowInsetsAnimation>,
                ): WindowInsets {
                    // Where Android says the keys are, with the slide as a
                    // clock for Dart to read at its own frames ([clockOf]).
                    send(insets, sliding = slides.isNotEmpty(), running = running)
                    // In this frame of the slide, the one that moves the
                    // keys: the carried field is drawn on them in it.
                    carry.follow(lastReach)
                    return insets
                }

                override fun onEnd(animation: WindowInsetsAnimation) {
                    slides.remove(animation)
                    // A slide overtaken by another is not the end of the
                    // keys' moving: the window's insets are the new one's
                    // end, and sending them would jump the field there.
                    if (slides.isEmpty()) rested()
                }
            },
        )
        // The animation callback covers the slide; this covers everything
        // else — a rotation, a split-screen resize, a keyboard that appears
        // without animating at all. Not during a slide: the insets applied
        // then are where it will end, handed over before it starts.
        window.decorView.setOnApplyWindowInsetsListener { view: View, insets: WindowInsets ->
            if (slides.isEmpty()) send(insets)
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
        const val CARRY_CHANNEL = "caldo/carry"

        /**
         * How finely a slide's curve is read for Dart: a straight line
         * between readings this close is within half a point of the
         * keyboard's own curve at its steepest.
         */
        const val CURVE_STEPS = 128
        const val UPDATES_CHANNEL = "caldo/updates"
        const val WIDGET_CHANNEL = "caldo/widget"
        const val CALENDARS_CHANNEL = "caldo/calendars"
        const val REMINDER_CHANNEL = "caldo/reminder"
        const val BACKUP_CHANNEL = "caldo/backup"
        const val ATTACHMENTS_CHANNEL = "caldo/attachments"
        const val SYNC_CHANNEL = "caldo/sync"
        const val VAULT_CHANNEL = "caldo/vault"
        const val RECORD_CHANNEL = "caldo/record"
        const val PUSH_CHANNEL = "caldo/push"

        /** What the notification plugin calls the intent on a reminder. */
        const val REMINDER_ACTION = "SELECT_NOTIFICATION"
        const val ASK_CALENDARS = 7
        const val SAVE_BACKUP = 8
        const val OPEN_BACKUP = 9
        const val PICK_FOLDER = 12
        const val BACKUP_LIMIT = 64 * 1024 * 1024

        /** What a measurement may be out by and still be believed. */
        const val SLACK = 2
    }
}

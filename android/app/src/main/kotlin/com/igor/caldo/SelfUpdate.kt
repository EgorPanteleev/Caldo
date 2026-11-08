package com.igor.caldo

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import java.io.File

/**
 * Installs a downloaded release over Caldo through an install session of
 * Caldo's own, rather than by handing the file to the system's installer
 * app.
 *
 * Handed over, the update is that app's install, and on Android 14 an
 * install by it turns off full-screen reminders: every update came back
 * with the banner asking for them again, though nothing else the user had
 * allowed was lost. A session can say what that permission is to be, and
 * says it stays as it was.
 *
 * The cost is the way back into the app. Android stops Caldo to replace
 * it, and will not let it open itself again afterwards — not from the
 * session's answer, which the system sends, and not from the broadcast
 * the new version is woken with (both refused, BAL_BLOCK). The system
 * installer's "Open" did that. What is left is a notification, which may
 * open the app when tapped ([UpdateDone]).
 */
object SelfUpdate {
    private const val TAG = "CaldoUpdate"
    const val STATUS_ACTION = "com.igor.caldo.UPDATE_STATUS"
    private const val PREFS = "caldo_update"
    private const val STARTED = "started"
    private const val TITLE = "title"
    private const val TEXT = "text"
    private const val CHANNEL = "channel"
    private const val CHANNEL_ID = "caldo_updates"

    /** How long after a commit a replacement is still taken for this one. */
    private const val WINDOW_MS = 10 * 60 * 1000L

    /**
     * Writes [apk] into a new session and commits it; blocks while copying.
     * [words] are the notification's, in the app's language: the title, the
     * line under it, and the channel's name.
     */
    fun install(context: Context, apk: File, words: Map<String, String>) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        ).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
            // Once Caldo installed the version standing, Android lets it put
            // the next one over it without asking; the first time, it asks.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                setPermissionState(
                    Manifest.permission.USE_FULL_SCREEN_INTENT,
                    PackageInstaller.SessionParams.PERMISSION_STATE_GRANTED,
                )
            }
        }
        val id = installer.createSession(params)
        try {
            installer.openSession(id).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("caldo.apk", 0, apk.length()).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }
                // Answers come to the activity, which is in front while the
                // user is asked to confirm.
                val status = PendingIntent.getActivity(
                    context,
                    id,
                    Intent(context, MainActivity::class.java).setAction(STATUS_ACTION),
                    // Mutable: the installer writes its answer into it.
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putLong(STARTED, System.currentTimeMillis())
                    .putString(TITLE, words["title"])
                    .putString(TEXT, words["text"])
                    .putString(CHANNEL, words["channel"])
                    .commit()
                session.commit(status.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(id)
            throw error
        }
    }

    /**
     * Acts on an answer from the session, if [intent] is one. The only one
     * that needs anything done is the one asking the user to confirm, which
     * carries the screen to show; done, the activity being started at all
     * was the point.
     */
    fun answer(activity: Activity, intent: Intent?): Boolean {
        if (intent?.action != STATUS_ACTION) return false
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        Log.i(TAG, "install status $status: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}")
        if (status != PackageInstaller.STATUS_PENDING_USER_ACTION) return true
        @Suppress("DEPRECATION")
        val confirm = (
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
            ) ?: return true
        // A task of its own, kept out of the recent apps, as the installer
        // was when it was opened on the file.
        confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
        activity.startActivity(confirm)
        return true
    }

    /**
     * Says the update is in, if the replacement that has just happened is
     * the one committed from inside the app — not `adb install`, not the
     * system installer. The words are used up either way.
     */
    fun announce(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val started = prefs.getLong(STARTED, 0)
        val title = prefs.getString(TITLE, null)
        val text = prefs.getString(TEXT, null)
        val channel = prefs.getString(CHANNEL, null)
        prefs.edit().clear().commit()
        if (System.currentTimeMillis() - started !in 0..WINDOW_MS) return
        if (title == null || channel == null) return

        val notifications = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // High, so it comes down over whatever is on screen: it is
            // standing in for the app coming back by itself.
            notifications.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, channel, NotificationManager.IMPORTANCE_HIGH),
            )
        }
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        val tap = PendingIntent.getActivity(
            context,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setTimeoutAfter(WINDOW_MS)
            .build()
        try {
            notifications.notify(CHANNEL_ID.hashCode(), notification)
        } catch (_: SecurityException) {
            // Notifications not allowed: nothing to be done about it here.
        }
    }
}

/** Woken in the new version once it has replaced the old one. */
class UpdateDone : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) SelfUpdate.announce(context)
    }
}

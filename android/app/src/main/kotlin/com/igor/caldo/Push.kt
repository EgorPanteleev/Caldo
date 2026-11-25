package com.igor.caldo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugin.common.MethodChannel

/**
 * The Agents tab's notifications, pushed through Firebase by the Edge
 * Function `push`: a chat waiting on the user, or its agent's own word.
 *
 * They come as data only and are drawn here, not by Firebase, so the chat
 * already on screen isn't told of itself, and each chat has one
 * notification, its latest. This runs with the app closed too: Firebase
 * starts the process for it.
 *
 * Firebase is set up from the strings the build writes from
 * `~/keys/caldo-google-services.json`; a build without that file has no
 * Firebase, and so no token and no pushes.
 */
class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        Push.renewed(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        Push.show(this, message.data)
    }
}

object Push {
    private const val CHANNEL = "caldo_agents"
    private const val ID = 1
    const val EXTRA_OPEN_CHAT = "com.igor.caldo.OPEN_CHAT"

    /** The app's engine, while there is one; set by [MainActivity]. */
    var dart: MethodChannel? = null

    /** The chat on screen, while the app is in front. */
    @Volatile var looking: String? = null
    @Volatile var inFront = false

    private val main = Handler(Looper.getMainLooper())

    /**
     * This phone's token and name, for Dart to keep on the server, or null
     * without Firebase. The channel is made (or renamed) with [name] and
     * [hint] in the app's language.
     */
    fun token(context: Context, name: String?, hint: String?, result: MethodChannel.Result) {
        if (FirebaseApp.getApps(context).isEmpty()) return result.success(null)
        channel(context, name, hint)
        FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
            result.success(
                if (task.isSuccessful) mapOf("token" to task.result, "device" to Build.MODEL) else null,
            )
        }
    }

    /**
     * Firebase renewed the token. With the app's engine up it is kept at
     * once; otherwise on the next opening, which asks for the token anew.
     */
    fun renewed(token: String) {
        main.post { dart?.invokeMethod("token", mapOf("token" to token, "device" to Build.MODEL)) }
    }

    fun show(context: Context, data: Map<String, String>) {
        val chat = data["chat"] ?: return
        // Signed out since, its token not let go of: nothing of the
        // account's to show.
        if (!TodayWidget.prefs(context).contains("flutter.sync_session")) return
        if (inFront && looking == chat) return
        channel(context, null, null)
        val open = Intent(context, MainActivity::class.java).apply {
            putExtra(EXTRA_OPEN_CHAT, chat)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val tap = PendingIntent.getActivity(
            context,
            chat.hashCode(),
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val text = data["text"].orEmpty()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(data["title"] ?: "Caldo")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        manager(context).notify(chat, ID, notification)
    }

    /** [chat] opened in the app: what it said is read now. */
    fun seen(context: Context, chat: String) = manager(context).cancel(chat, ID)

    private fun manager(context: Context) =
        context.getSystemService(NotificationManager::class.java)

    /**
     * The channel, named in the app's language once Dart has said it;
     * before that, if a push comes first, in English.
     */
    private fun channel(context: Context, name: String?, hint: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = manager(context)
        val had = manager.getNotificationChannel(CHANNEL)
        if (had != null && name == null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, name ?: "Agents", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = hint ?: "A chat waiting on you, or its agent's word." },
        )
    }
}

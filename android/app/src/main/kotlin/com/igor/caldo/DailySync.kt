package com.igor.caldo

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/**
 * A sync round while the app is closed, so a device left alone for days
 * still sends what was changed on it and hears what was changed elsewhere —
 * and its reminders go off for tasks added on another one.
 *
 * Twice a day, with a network: Android puts off a job of a little-used app
 * to once a day or so, and the slack keeps a round inside every day.
 *
 * The round is run by whichever engine holds the session. With the app's
 * engine alive (open, or only put away) it is asked to, through [app]; a
 * second engine renewing the same session would spend the refresh token the
 * first still holds, and Supabase takes a token used twice as stolen and
 * ends the session. Otherwise the widget's engine ([Headless]) runs it,
 * renews the session if it must and keeps the new one where the app reads it.
 */
class DailySync(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
        val reached = suspendCancellableCoroutine { going ->
            val answer = { result: Any? ->
                // Only a round that says it reached the server counts: an
                // error, or a wait run out, is tried again.
                if (going.isActive) going.resume(result == true)
            }
            val app = app
            if (app != null) {
                app.invokeMethod(
                    "sync",
                    null,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) = answer(result)

                        override fun error(code: String, message: String?, details: Any?) =
                            answer(false)

                        override fun notImplemented() = answer(false)
                    },
                )
            } else {
                // The widget's engine has no activity to ask where the
                // attachments are kept.
                val attachments = File(applicationContext.filesDir, Attachments.DIR).path
                Headless.call(
                    applicationContext,
                    "sync",
                    mapOf("attachments" to attachments),
                    PATIENCE,
                    answer,
                )
            }
        }
        // Offline after all, or the server asleep: again in a while rather
        // than in twelve hours.
        if (reached) Result.success() else Result.retry()
    }

    companion object {
        private const val NAME = "caldo-sync"

        /**
         * A cold engine, a renewed session, a round of a few pages and the
         * files it names: a few photos up or down. Short of the ten minutes
         * Android gives a job.
         */
        private const val PATIENCE = 8 * 60_000L

        /** The app's own engine, while there is one; set by [MainActivity]. */
        var app: MethodChannel? = null

        /** While signed in. Kept as it is if already booked. */
        fun keep(context: Context) {
            val request = PeriodicWorkRequestBuilder<DailySync>(12, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build(),
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }

        /** Signed out: nothing left to send anywhere. */
        fun stop(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(NAME)
        }
    }
}

package com.igor.caldo

import android.app.Application
import android.content.SharedPreferences

/**
 * Redraws the home-screen widget whenever what it shows changes.
 *
 * The widget's copy of the agenda is written by Dart, from whichever engine
 * made the change — the app's own, the one a reminder's button starts, or
 * the widget's ([Headless]) — and only the app's has a channel of ours on
 * it. So nobody tells the widget anything: it is redrawn here, from the
 * preferences the copy is written to, which every engine in the process
 * shares.
 */
class CaldoApplication : Application() {
    // Held here because the preferences only keep a weak hold on it.
    private val watcher = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key in WATCHED) TodayWidget.refresh(this)
    }

    override fun onCreate() {
        super.onCreate()
        TodayWidget.prefs(this).registerOnSharedPreferenceChangeListener(watcher)
    }

    private companion object {
        /** The copy itself, and the two settings that change how it reads. */
        val WATCHED = setOf(TodayWidget.KEY, TodayWidget.KEY_SHOW_DONE, TodayWidget.KEY_24_HOUR)
    }
}

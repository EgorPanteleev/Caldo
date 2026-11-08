package com.igor.caldo

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.CalendarContract

/**
 * The phone's own calendars, read and never written: the app shows their
 * events beside its tasks, and so does the home-screen widget. One query
 * for both, so the two cannot come to disagree about what an event is.
 */
object PhoneEvents {
    /** One occurrence of an event. */
    data class Event(
        val id: Long,
        val begin: Long,
        val end: Long,
        val allDay: Boolean,
        val title: String,
        val colour: Int,
        val calendar: String,
        val calendarName: String?,
    )

    fun permitted(context: Context) =
        context.checkSelfPermission(Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Every instance of every event between [from] and [to] — a repeating
     * event is a row per time it happens, which is what Instances is for.
     * Nothing at all when the calendars may not be read.
     */
    fun between(context: Context, from: Long, to: Long): List<Event> {
        if (!permitted(context)) return emptyList()
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            ContentUris.appendId(it, from)
            ContentUris.appendId(it, to)
        }.build()
        val columns = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.DISPLAY_COLOR,
            CalendarContract.Instances.CALENDAR_ID,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
        )
        val found = mutableListOf<Event>()
        try {
            context.contentResolver.query(
                uri,
                columns,
                "${CalendarContract.Instances.VISIBLE} = 1",
                null,
                "${CalendarContract.Instances.BEGIN} ASC",
            )?.use { c ->
                while (c.moveToNext()) {
                    found.add(
                        Event(
                            id = c.getLong(0),
                            begin = c.getLong(1),
                            end = c.getLong(2),
                            allDay = c.getInt(3) != 0,
                            title = c.getString(4) ?: "",
                            colour = c.getInt(5),
                            calendar = c.getLong(6).toString(),
                            calendarName = c.getString(7),
                        ),
                    )
                }
            }
        } catch (_: SecurityException) {
            return emptyList()
        }
        return found
    }

    /** Opens an event at one occurrence in whichever app keeps the calendar. */
    fun view(id: Long, begin: Long, end: Long): Intent =
        Intent(
            Intent.ACTION_VIEW,
            ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id),
        )
            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin)
            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
}

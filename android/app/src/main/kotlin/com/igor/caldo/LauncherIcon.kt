package com.igor.caldo

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * Which of the two launcher entries is on (the two `activity-alias`es in
 * the manifest). Samsung's launcher leaves an adaptive icon's transparent
 * ground transparent, so Caldo can be a page standing free there, as
 * Samsung's own Calendar is. Every other launcher cuts the icon to its
 * shape and fills what is transparent — the Pixel's black — so there the
 * page fills the shape instead.
 *
 * The free page is the one on out of the box, and only a phone that is not
 * a Samsung switches: a launcher can take an icon off the home screen when
 * the entry under it changes, and a Samsung already updated past the switch
 * should not lose its place a second time on first opening. The switch
 * comes on leaving the app (MainActivity.onStop), so until a
 * phone that is not a Samsung has been left once, it shows the free page.
 */
object LauncherIcon {
    fun pick(context: Context) {
        if (Build.MANUFACTURER.equals("samsung", ignoreCase = true)) return
        val pm = context.packageManager
        val filled = ComponentName(context, "com.igor.caldo.LauncherFilled")
        if (pm.getComponentEnabledSetting(filled) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) return
        pm.setComponentEnabledSetting(
            filled, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP,
        )
        pm.setComponentEnabledSetting(
            ComponentName(context, "com.igor.caldo.LauncherFree"),
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP,
        )
    }
}

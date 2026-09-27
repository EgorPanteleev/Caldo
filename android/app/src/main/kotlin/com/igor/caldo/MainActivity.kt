package com.igor.caldo

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * Android gives a window 60Hz on a 120Hz panel unless the window asks for
 * better, and Flutter's stock activity never asks — which is why the app felt
 * like half the refresh rate the phone is capable of.
 *
 * The ask is for the fastest mode *at the resolution already in use*: the list
 * of supported modes mixes resolutions, and taking the fastest of all of them
 * can drop the screen to a coarser one to get there.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useFastestRefreshRate()
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
}

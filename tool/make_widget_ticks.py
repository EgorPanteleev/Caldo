#!/usr/bin/env python3
"""Writes the home-screen widget's animated ticks and the row layout for each
task colour, into android/app/src/main/res.

A widget cannot tint a drawable without tinting all of it, and the tick is a
white check on a square of the task's colour: so each swatch has a drawable
of its own, and a row layout that uses it. The swatches are `ListStyle`'s in
lib/models/task_list.dart; change one there, change it here and run this.

    python3 tool/make_widget_ticks.py
"""

import os

SWATCHES = {
    "violet": "#7B61E8",
    "blue": "#3B7DD8",
    "teal": "#16A394",
    "green": "#35A06A",
    "amber": "#D99A2B",
    "pink": "#D9528A",
    "cyan": "#1E94B0",
    "orange": "#DB7A33",
}

RES = os.path.join(os.path.dirname(__file__), "..", "android", "app", "src", "main", "res")

HEADER = '<?xml version="1.0" encoding="utf-8"?>\n<!-- Written by tool/make_widget_ticks.py; edit that, not this. -->\n'

# The card's tick (`_Tick`, `CheckMark`): a 24-point square with corners of
# 7, outlined in the task's colour, filled in it once ticked, with a white
# check drawn through it.
OUTLINE = "M7,0.9 H17 A6.1,6.1 0 0 1 23.1,7 V17 A6.1,6.1 0 0 1 17,23.1 H7 A6.1,6.1 0 0 1 0.9,17 V7 A6.1,6.1 0 0 1 7,0.9 Z"
BOX = "M7,0 H17 A7,7 0 0 1 24,7 V17 A7,7 0 0 1 17,24 H7 A7,7 0 0 1 0,17 V7 A7,7 0 0 1 7,0 Z"
CHECK = "M6.24,12.48 L10.56,16.8 L18.24,7.68"


def vector(colour, fill, check):
    return HEADER + f"""<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:name="outline"
        android:pathData="{OUTLINE}"
        android:strokeColor="{colour}"
        android:strokeWidth="1.8"/>
    <group
        android:name="fill"
        android:pivotX="12"
        android:pivotY="12"
        android:scaleX="{fill}"
        android:scaleY="{fill}">
        <path
            android:name="box"
            android:pathData="{BOX}"
            android:fillColor="{colour}"/>
    </group>
    <path
        android:name="check"
        android:pathData="{CHECK}"
        android:strokeColor="#FFFFFFFF"
        android:strokeWidth="2.2"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:trimPathEnd="{check}"/>
</vector>
"""


def animated(name, base, fill_anim, check_anim):
    return HEADER + f"""<animated-vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:drawable="@drawable/{base}">
    <target android:name="fill" android:animation="@animator/{fill_anim}"/>
    <target android:name="check" android:animation="@animator/{check_anim}"/>
</animated-vector>
"""


def selector(name):
    return HEADER + f"""<!-- A widget task's tick in {name}: the square fills and the check is drawn
     through it, as the app's card does, played by the launcher the moment
     the box is tapped. -->
<animated-selector xmlns:android="http://schemas.android.com/apk/res/android">
    <item
        android:id="@+id/ticked"
        android:drawable="@drawable/widget_tick_{name}_on"
        android:state_checked="true"/>
    <item
        android:id="@+id/open"
        android:drawable="@drawable/widget_tick_{name}_off"/>
    <transition
        android:drawable="@drawable/widget_tick_{name}_ticking"
        android:fromId="@id/open"
        android:toId="@id/ticked"/>
    <transition
        android:drawable="@drawable/widget_tick_{name}_unticking"
        android:fromId="@id/ticked"
        android:toId="@id/open"/>
</animated-selector>
"""


def row(name):
    return HEADER + f"""<!-- A task card in {name}: its ink behind, the tick, the title and its time.
     The outer frame's padding is the gap to the next card. -->
<FrameLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:paddingBottom="5dp">

    <FrameLayout
        android:id="@+id/widget_card"
        android:layout_width="match_parent"
        android:layout_height="wrap_content">

        <ImageView
            android:id="@+id/widget_ink"
            android:layout_width="match_parent"
            android:layout_height="match_parent"
            android:scaleType="fitXY"
            android:src="@drawable/widget_ink"/>

        <LinearLayout
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:gravity="center_vertical"
            android:minHeight="46dp"
            android:orientation="horizontal"
            android:paddingEnd="14dp">

            <CheckBox
                android:id="@+id/widget_tick"
                android:layout_width="wrap_content"
                android:layout_height="46dp"
                android:layout_marginStart="12dp"
                android:background="@null"
                android:button="@drawable/widget_check_{name}"
                android:minWidth="0dp"
                android:minHeight="0dp"
                android:paddingEnd="12dp"/>

            <TextView
                android:id="@+id/widget_title"
                android:layout_width="0dp"
                android:layout_height="wrap_content"
                android:layout_weight="1"
                android:ellipsize="end"
                android:maxLines="2"
                android:paddingTop="9dp"
                android:paddingBottom="9dp"
                android:textColor="#FFE9E9EB"
                android:textSize="14.5sp"/>

            <TextView
                android:id="@+id/widget_time"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginStart="10dp"
                android:textColor="#FF9B9BA1"
                android:textSize="12.5sp"/>
        </LinearLayout>
    </FrameLayout>
</FrameLayout>
"""


def animator(prop, start, end, duration, delay=0):
    return HEADER + f"""<objectAnimator xmlns:android="http://schemas.android.com/apk/res/android"
    android:duration="{duration}"
    android:interpolator="@android:interpolator/fast_out_slow_in"
    android:propertyName="{prop}"
    android:startOffset="{delay}"
    android:valueFrom="{start}"
    android:valueTo="{end}"
    android:valueType="floatType"/>
"""


def write(folder, name, text):
    path = os.path.join(RES, folder)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, name), "w") as f:
        f.write(text)


def main():
    # The square fills first and the stroke follows it in (`_Tick`): the
    # fill over 180ms, the check from 70ms for 200ms. Taken back, it goes
    # quicker, as a correction should.
    scale = '<set xmlns:android="http://schemas.android.com/apk/res/android">\n{}\n</set>\n'

    def scale_set(start, end, duration):
        inner = []
        for axis in ("scaleX", "scaleY"):
            text = animator(axis, start, end, duration).replace(HEADER, "")
            inner.append(text.strip())
        return HEADER + scale.format("\n".join(inner))

    write("animator", "widget_tick_fill_in.xml", scale_set(0, 1, 180))
    write("animator", "widget_tick_fill_out.xml", scale_set(1, 0, 140))
    write("animator", "widget_tick_check_in.xml", animator("trimPathEnd", 0, 1, 200, 70))
    write("animator", "widget_tick_check_out.xml", animator("trimPathEnd", 1, 0, 100))

    for name, colour in SWATCHES.items():
        write("drawable", f"widget_tick_{name}_on.xml", vector(colour, 1, 1))
        write("drawable", f"widget_tick_{name}_off.xml", vector(colour, 0, 0))
        write("drawable", f"widget_tick_{name}_base.xml", vector(colour, 0, 0))
        write(
            "drawable",
            f"widget_tick_{name}_ticking.xml",
            animated(name, f"widget_tick_{name}_base", "widget_tick_fill_in", "widget_tick_check_in"),
        )
        write(
            "drawable",
            f"widget_tick_{name}_unticking.xml",
            animated(name, f"widget_tick_{name}_on", "widget_tick_fill_out", "widget_tick_check_out"),
        )
        write("drawable", f"widget_check_{name}.xml", selector(name))
        write("layout-v31", f"widget_task_{name}.xml", row(name))


if __name__ == "__main__":
    main()

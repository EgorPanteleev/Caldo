# Caldo — working notes

A calendar + to-do app for Android, Flutter, local-only storage. Private repo:
`github.com/EgorPanteleev/Caldo`. It is modelled on its sibling app **Dicty**
(`/home/igor/dev/src/Dicty`) — same stack, same theme. When a question about
style or structure comes up, look there first.

## Stack

Flutter 3.38.6 / Dart 3.10.7. `provider` (state), `sqflite` (storage),
`shared_preferences` (settings), `intl` (dates),
`flutter_local_notifications` + `timezone` + `flutter_timezone` (reminders).
The type is the platform's own font — see the decision below.
Dev-only: `sqflite_common_ffi`, so widget tests run against a real database.

## Layout

```
lib/
  data/holidays.dart     public-holiday rules, computed on device (no network)
  db/database.dart       schema v2: lists, tasks (+ migration)
  models/                task.dart (Repeat, Priority), task_list.dart
                         (ListStyle, colorOfTask)
  providers/             task_provider.dart, settings_provider.dart
  services/reminders.dart  the notification each dated task gets
  screens/               home (shell + menu), tasks (Schedule), calendar,
                         search,
                         lists, task_list, task_edit, list_edit, settings
  theme/app_theme.dart   AppPalette + AccentColors ThemeExtensions, AppColors
  utils/dates.dart       every date/time string the UI shows
  widgets/               month_grid, task_card (+ HolidayCard), task_row,
                         colour_selector,
                         date_time_pickers, day_sheet, menu_button,
                         quick_add_bar, screen_header, selection_bar,
                         theme_switcher, gradient_icon_button
```

Three destinations — **Schedule**, **Calendar**, **Settings** — in a drawer
behind the menu button at the top left of each, and nothing else in it.

`lists_screen.dart` and `list_edit_screen.dart` are **unreachable**: the folder
button that opened them went with the Schedule header, and Lists was taken back
out of the menu. The lists themselves are still real — every task carries a
`list_id`, and a list's colour is what tints its tasks — so the screens are left
in place rather than deleted. Delete them, or give them a way in again, but do
not leave it undecided for long.

## Decisions worth keeping

These were all asked for explicitly or fixed after being seen on a device.
Changing them back will be noticed.

- **The calendar has three states**, driven by one `AnimationController` with
  bounds `[-1, 1]`: `-1` the selected day's week alone, `0` the compact month,
  `+1` the month opened out with each day's tasks written out. Drag anywhere on
  the grid; the invisible strip under it and the day bar below take drags too.
- **A tap on the strip steps one state along and turns around at either end**
  — month, opened, month, week. It used to toggle between two of the three, so
  the week could only be reached by dragging.
- **A drag a fifth of the way towards the next state commits to it**, and the
  snap runs on a critically damped spring carrying the drag's own speed, not a
  fixed ease from a standstill. Pulling the whole way was never the point.
- **Day numbers sit at a fixed offset from the top of their cell.** This is
  why the first week never moves as the grid grows. An earlier version
  cross-faded a centred layout with a top-aligned one and the numbers visibly
  teleported mid-drag. Centring them in a compact cell and sliding them to the
  top as it opens does work — it was built, on a lerped offset — but it was
  asked for and then asked back, so they are at the top in both states.
- **A day's tasks are marked with a line each**, the width of the day, stacked
  under the number — not dots. Holidays come first, in green.
- **An opened day's task titles take the lines they need, up to two.** A day
  cell is about seven characters wide, so one line cut most names off — but a
  chip is measured (`TextPainter`, in the chip's own font and width) and a
  short title still gets a single-line chip. Take the height from the painter
  and round it up: a box worked out from the font size instead is a box the
  text can overflow by a fraction of a pixel, and an overflowing
  `TextOverflow.fade` fades away the bottom half of every letter.
- **An opened day's chips are inked, not painted** (`dayChipColour`). They
  were the task's colour at nine tenths — the only saturated blocks left in
  the app once the cards were inked — and six of them in a cell shouted over
  the day number they belonged to, so a month with anything on it read as a
  sheet of violet bricks. The colour is mixed into the calendar's ground
  instead, a little stronger than a card's since a chip is the size of a word,
  with the title in the ordinary text colour. The function is top-level so a
  test can say "this chip wears the task's own colour" without pinning how
  deep the ink is.
- **The chips stay tight.** A point of air per chip reads as calmer right up
  until it costs the day a whole task: at `_inset`/`_gap` of 2 a day with four
  tasks showed two and "+2 more", which hides more than the air was worth.
  What did change is the shape — corners at 3 rather than barely off square —
  and `+N more` is left-aligned under the titles it stands for; centred, it
  read as a caption on the day rather than the rest of its list.
- **Collapsing to the week slides the grid past a shrinking window**; every
  week keeps its full-month height and the selected one is where the window is
  left sitting. Shrinking the rows themselves made the numbers close in on each
  other and read as a glitch.
- **Picking a day in the opened month opens it as a card on top** (`day_sheet`)
  rather than collapsing the calendar to make room — the tap was made from that
  view, so it should still be there underneath. The card gives the keyboard its
  room out of its own height, margins first and then the list of the day's
  tasks: it is a dialog, so nothing lifts it the way a screen is lifted, and
  the keys came up over the field at the foot of it with the typing underneath.
  This is the opposite of what the calendar does with the same keyboard, and on
  purpose — there the month is the thing being looked at, here the field is.
- **The days below the grid are a pager, one page per day.** Picking a day
  slides it in from the edge it lies on and the days can be swiped through
  directly, carrying the month round with them. A day more than ten away is
  jumped to; watching a month of days fly past says nothing. The two pagers
  each ignore the change the other has already made, which is what keeps a
  swipe across a month boundary from bouncing.
- **Week rules only arrive at the end of the opening** (`weekRuleAlpha`, last
  quarter) and never while the month is shrinking.
- **The three screens live behind a menu button, not a bottom bar.** The
  hamburger sits at the top left of each of them and carries a dot when
  something is overdue — the one thing worth pulling the user back to a screen
  they are not on.
- **The menu moves the screen aside; it does not cover it.** Opening slides the
  whole screen `_menuWidth` to the right and the menu in from off the left
  edge, so what is on the screen stays legible instead of being hidden under a
  panel. The menu is drawn **over** the screen, rounded down its leading edge
  and shadowed, so it reads as a panel above the window rather than something
  uncovered behind it. It laps over the screen by `_menuOverlap`: the screen
  slides that much less than the menu is wide, so the menu's rounded corners
  cut into it and its shadow falls across it. Flush, with both of them
  rounded, nothing said which was in front — and the screen, being the rounded
  lit one, read as the panel on top, which is backwards. The screen is square
  now; its leading edge runs underneath.
  This is not a Material `Drawer` — the menu is always in the tree,
  behind the screen, which is why a test cannot tell open from closed by
  looking for its text and reads the screen's offset instead. Back closes it
  (`PopScope`), as does a tap or a leftward swipe on the screen.
- **Today is a badge, the selected day a thin neutral outline.** Accent on
  either was "too much"; the accent survives on the add buttons, the TODAY
  label and the menu's current entry. The badge takes the colour the day's own
  number would have had — red on a Sunday, light on every other day — since a
  light badge on a red date was the one place the red stopped halfway. The
  number on the red badge is black; on the light one it is the ground itself.
  The badge is near enough square and tight around the digits — measured off
  the screenshot this was matched to, theirs is a square a fifth wider than
  the number in it, where ours had been half again as wide as that, a slab
  with the date floating in the middle.
- **The app is set in the platform's own font.** It was Inter, fetched by
  `google_fonts` on first launch. Two things were wrong with that: this
  calendar sits beside other calendars on the same phone and did not look like
  them — every one of those uses the system font, which is what a date is
  expected to be set in — and an emulator with no network silently falls back
  to Roboto, so nothing judged by eye here was ever showing the font that
  actually shipped. Measured against the screenshot this was matched to, the
  numbers now come out within two percent on width at the same cap height, and
  a date stands the same fraction of the screen tall — 2.04% against 2.03%,
  which is what 12 points rather than 13.5 buys.
- **Every day number carries the same weight**, semibold. A grid of dates is
  read by glancing at it, not by reading along it, and today and the selected
  day being the only bold ones was a distinction the badge and the outline
  were already making. Bold for all of them was heavier than the dates on any
  other calendar on the phone, which is what this is read beside.
- **The day numbers are pulled together** (`letterSpacing`, on the day bar,
  the day card's header and the grid; `FontFeature.proportionalFigures` in the
  grid as well). Digits are laid out in boxes of one width so columns of them
  line up, and nothing here is in a column. Two things follow from that: the
  hole between the ones of an 11 reads as two numbers rather than one, and —
  since a 1 is a narrow glyph in a wide box — the ink of an 11 sits left of
  where the pair is centred, which is what had the date looking off-centre in
  its badge.
- **The date in the badge is centred on its digits, not on its line box**
  (`Alignment(0, 0.2)` with `height: 1`). A line box carries room for
  descenders under the baseline and no date has one, so a date centred by its
  box sits low — in a badge this tight, all but resting on the bottom edge.
- **Only Sundays are red.** A holiday does not recolour the number — its green
  mark says it already.
- **Holidays are not tasks.** They are computed read-only entries; nothing is
  written to the database, so they can't be ticked, edited or deleted. The
  country follows the device locale, overridable in Settings.
- **A task may carry its own colour** (`Task.styleId`, same swatches a list
  wears) and falls back to its list's colour. Always resolve through
  `colorOfTask`.
- **The date and time pickers are our own sheets** — a month grid and scroll
  wheels. Material's dialog and clock dial were rejected by name.
- **The clock's middle band is a window in a mask, not a panel.** Nothing is
  drawn behind the numbers — no fill, no outline, no band. Every number on a
  wheel is the same size, weight and colour, and a `ShaderMask` down the drum
  carries them at full strength inside one row's worth in the middle and at a
  third of it outside. Doing that to the pixels rather than to each number is
  the whole point: a number halfway across the edge comes out bright above the
  line and dim below it, and that split is what shows a wheel standing between
  two values. Per-number colouring cannot produce it — that was tried twice.
- **The wheel under a finger goes over to the accent**, all of it, and back to
  white the moment the finger lifts — tracked on pointer down/up, not on the
  scrolling, so a flung wheel coasts to rest in plain white. The colour is
  there to say what is being touched, so it leaves with the touch. Each wheel
  does this on its own, so turning the hour leaves the other two alone.
- The drum is flat (`diameterRatio: 100`): a curve pulls the numbers away from
  the eye, and the band is already saying which of them is the one.
- **The clock is 12-hour with its own AM/PM wheel**, and the shortcuts under it
  are written the same way (`Dates.clock`). Note that the rest of the app still
  shows times on a 24-hour clock (`Dates.time`); pick one if it starts to jar.
- **The task form hides its way back once anything is changed**, and puts
  Cancel and Save at the foot instead. An arrow beside unsaved edits is an
  invitation to lose them. Untouched, the arrow is there and there is nothing
  to save. Every field marks the form as touched, including the clears and the
  two text controllers.
- **A sheet's actions are two plain words**, Cancel and Save, drawn in towards
  the middle rather than pushed out to the corners — pinned to the edges they
  read as one control at each end rather than as a pair to choose between. A filled button beside an outlined one were the only heavy things in a
  sheet this plain, and they argued over which was the one to press.
- **The plus beside the quick-add field opens the full form**; the tick files
  what has been typed. A plus that did nothing at all on an empty field was
  the state it was left in when the Schedule header's add button was removed.
- **New tasks start in the colour Settings names** (`defaultTaskStyleId`, null
  meaning they take their list's). Every quick-add goes through `quickAddTask`
  so the three fields that have one cannot drift apart on this.
- **The quick-add button is a plus until the field is opened, then a tick**,
  and it is plain rather than the accent gradient the headers wear — it sits
  beside the field the eye is already on.
- **The day below the grid is a grey panel, the grid is black.** The month and
  the day it is showing are two surfaces, not one dark field; `panel` under the
  day, `calendar` under the grid. The day bar takes the panel's grey too — it
  had a shade of its own, which put a band across the screen and cut the day in
  two, when the date and the things on that date are one panel and the bar is
  only the top of it. The strip under the add field follows, so it is the
  panel's grey while the day is on screen and the calendar's black once the
  month is opened out over it.
- **The day bar names its day and nothing else.** The open-count and the
  full-form button beside it were noise on a bar whose whole job is to say
  which day is below it; the full form is still reached from the day card's
  header, or by tapping a task.
- **The calendar's header is two rows**: the controls across the top — the
  menu button on the left, Search and Today on the right — and the month name
  alone on the row beneath. Sharing one row meant the name had to be kept clear
  of whatever sat beside it. The month chevrons are gone; the grid is swiped.
- **Today is drawn as today's date on a page**, so the button names the day it
  will take you to.
- **The month header shows `Sep`, centred**, gaining the year only when it is
  not the current one.
- **The field and the button beside it are a filled grey** (`AppPalette.field`,
  a step above `panelHi`), with no outline on either and nothing marking the
  focus but the cursor. Outlined on true black the pair read as holes cut in
  the screen, and a neutral ring around half the width was a line nobody read.
- **The strip the add field sits on follows what is above it** — the calendar's
  own ground once the month is opened out, the app background while the day's
  tasks are still on screen — and whatever is above fades into it over the last
  22 points rather than being sliced off square by it.
- **The keyboard arrives over the calendar, it does not shorten it.** The
  screen's `Scaffold` does not resize for the inset; the quick-add bar is
  wrapped in `KeyboardLift`, which translates it up by the inset instead. A
  resizing `Scaffold` takes the room out of whatever is above the field, which
  on an opened month means squeezing the very grid being looked at. The shell's
  `Scaffold` does not resize either — it would shorten all three screens before
  any of them was asked — and Schedule still resizes, on its own `Scaffold`,
  because an agenda that keeps its height would just be hidden under the keys.
  The inset is read in `KeyboardLift` and nowhere else: it changes on every
  frame of the keyboard sliding in, and whoever reads it rebuilds that often.
- **The bar is never put anywhere, only ever sent there — both ways.** Android
  does not promise to report a keyboard's slide frame by frame; it reports it
  in however many lumps it feels like, so a bar moved straight to one of those
  has teleported whether or not the number it was handed was honest. Every
  change of inset goes through a critically damped spring, which carries
  whatever speed it already has — that is what stops a change of target
  mid-flight from putting a catch in the middle of the movement — and starts
  from a standstill when it was at rest. Following the inset exactly was tried
  on the way up, to stay glued to the keys; on a phone that reports the rise
  in two steps that is two jumps. Reported smoothly, the spring trails by
  about a frame, which is the price of never jumping. The carried speed is
  bounded by what the spring can shed over the distance left: critically
  damped only promises not to overshoot from a standstill, and thrown past its
  target the bar dips below the place it lives and climbs back into it.
- **The dark ground is true black.** The calendar's already was, so an app
  background a shade lighter put a seam down the screen — and on the OLED panels
  this is built for, black is black rather than a very dark grey. Everything
  above it is a raised grey instead.
- **The greys are neutral.** Every surface used to carry a few points of extra
  blue, which over a whole screen read as a violet wash instead of as grey. The
  accent and the list swatches came off the bright web palette they were taken
  from at the same time; the ids are unchanged, so a saved choice still lands
  on its own colour.
- **Both pagers ignore the pages an animation passes through** (`_driving`).
  A jump of a week reports six days nobody chose, and each was taken for a new
  pick and sent the other pager off after it. The month header reads its page
  off the controller, so `_onMonthPageChanged` owes it a `setState` even when
  the change was driven rather than swiped.
- **Schedule is a running order of days, not a list of tasks.** A day is a
  plain date written out — not an uppercase section label with a count and an
  add button beside it, which made a heading of something the eye should pass
  straight over. Under it, everything is the same filled card the calendar puts
  under its grid, and holidays fall in among them.
- **Timed tasks are not a separate form.** There was one: a bare row with the
  hour at the far end and a bar in the list's colour. Beside the filled cards
  it sat between, the lone bar read as a stray mark and the title and hour were
  stranded at opposite ends of a void. The card already writes the hour where
  an all-day task's says "All day", so the row was drawing a distinction that
  was already being made — quietly, and better.
- **A task card is inked with its colour — a quarter of it, over whatever the
  card is standing on.** Against true black that comes out as the deep
  near-navy the cards wear. The same colour at a sixth strength with an
  outline a third of the way up was a haze with a blurred edge; so was
  dropping the colour for a neutral panel, which was rejected by name. There
  is no border: the fill is the shape. The ink is left translucent rather than
  blended into one named colour, so a card is inked by the ground it is
  actually on — the calendar's day panel is grey, the agenda and the day card
  are black, and a card worked out against the wrong one of those is a card
  darker than the sheet under it. A done card keeps a twentieth of the colour,
  so it sinks most of the way back into the ground without leaving the run,
  and its tick square fills in instead of standing empty.
- **A day the reader has a word for wears it on a badge**, with the date
  written beside it — `Today` on a light pill, then `Sat, 4 Oct`. The word
  used to replace the date, which left the one day most likely to be looked up
  as the one day not written down. Overdue and No date are badges of the same
  shape, the first in red.
- **Pulling the day panel past either end drives the grid.** The panel is most
  of the screen; a swipe on it that had nowhere else to go used to do nothing.
  A short day's list cannot scroll at all, so every drag on it arrives as
  overscroll; a long one arrives only once it has run out of list.
- **Schedule's list is built lazily** (`_LazyList`, rows handed over as
  builders). `ListView(children: [...])` constructs every row on every build,
  and the screen rebuilds on each frame of the keyboard sliding in — so opening
  the keyboard rebuilt the whole agenda sixty times a second and juddered.
- **Schedule's header carries Search and Today**, the same pair the calendar
  has, and its quick-add field at the foot files on today. Today is a scroll
  home here, since today is the top of the run.

- **The calendar's drag is kept cheap rather than kept short.** It rebuilds on
  every frame, so anything expensive in that subtree shows up as judder:
  `Holidays.around` was running three full years of rules per frame per page
  and is cached; every task chip was being measured with a `TextPainter` per
  frame and those heights are cached; and the day pager is hoisted into
  `AnimatedBuilder`'s `child`, since nothing in it depends on how far the month
  is open. Look there first if it ever feels rough again.
- **A dated task gets a notification, and the alarms are rebuilt from the
  agenda rather than kept in step by hand** (`services/reminders.dart`). Every
  path that changes a task ends in `TaskProvider.loadTasks`, so that is where
  the whole set is cancelled and re-set: an edited date, a tick, a deletion
  cannot leave an alarm behind. A timed task is announced at its own time, an
  all-day one at the hour Settings names (nine by default, since midnight is
  the one hour nobody wants to hear about it) — including one due today, as
  long as that hour has not already gone by.
- **Changing a reminder setting re-sets the alarms already standing**
  (`Reminders.configure` keeps the task list its last sync was built from).
  Settings and the agenda load at the same time when the app starts and
  whichever lands first wins: with the tasks first, every alarm was worked out
  against the default hour, and an all-day task went on announcing itself at
  nine however many times the hour was changed in Settings.
- **Reminders are no-ops until `init` has been through.** The widget tests
  drive the real providers and nothing in a test can answer the plugin's
  channels, so the service checks a flag and does nothing rather than throwing
  on every save. `init` is called from `main` and nowhere else.
- **Permission is asked for on the first run**, from `SettingsProvider.load`,
  because reminders are on out of the box and nothing else would ever ask. A
  permission that was never requested looks exactly like a feature that does
  not work. Alarms are exact (`USE_EXACT_ALARM`, the calendar-app permission
  that is granted on install) and fall back to inexact if a device refuses —
  a reminder that arrives whenever the system next wakes up is worth having,
  but only as a fallback.
- **The window asks Android for the fastest display mode** (`MainActivity`).
  Flutter's stock activity never does, so a 120Hz phone renders the app at 60.
  The ask is for the fastest mode at the resolution already in use — the
  supported-mode list mixes resolutions, and the fastest of all of them can
  drop the screen to a coarser one.

## Tests

`flutter test` — 77 tests, all passing. Keep them that way; several real bugs
in this app were caught by them before the emulator ever saw the code.

Things that will bite you:

- **Each test file gets its own temp database dir** (`test/support/test_db.dart`,
  `initTestDatabase`). Files run in parallel and would otherwise fight over one
  `caldo.db`. `AppDatabase.close()` exists for the same reason.
- **Real database work cannot complete inside `testWidgets`' fake-async zone.**
  Seed inside `tester.runAsync`. For a write triggered by the UI, either use a
  capturing provider subclass (see `_CapturingProvider` in `screens_test.dart`)
  or poll inside `runAsync`.
- **Screens are pumped at phone sizes** so layout overflows fail the run. That
  is intentional — it has caught an overflowing task row, an empty state, and a
  day cell that laid out one title row too many.
- **The test font draws every glyph as an em square.** Never assert glyph
  widths; assert layout invariants instead (e.g. "the title is given all the
  width the controls leave").
- Widget keys are exported for tests: `monthTitleKey`, `calendarHandleKey`,
  `daySheetKey`, `menuButtonKey`, `searchFieldKey`, `screenTitleKey`, `checkKey`,
  `taskCardTickKey`.

## Building

Three things in `android/` exist only for the reminders, and all three are
load-bearing: **desugaring** in `app/build.gradle.kts` (the plugin schedules
through `java.time`, and the build fails without it), the **two receivers and
three permissions** in the manifest (a scheduled notification is held by the
system, which forgets them on a reboot and on an update), and
**`res/raw/keep.xml`** (R8 cannot see that a notification icon is used, and a
stripped icon fails silently at the moment the reminder was meant to appear).

`android/gradle.properties` is capped on purpose: **`-Xmx2G`, four workers, a
1G Kotlin daemon**. Flutter's template ships `-Xmx8G`, and on this 13GB machine
the daemon sat on 3.4GB between builds and starved the emulator into an ANR.
Do not raise it. Stop the daemon when you are done:

```sh
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
(cd android && ./gradlew --stop)
```

`release/` is gitignored and holds `Caldo-arm64.apk`, `Caldo-armv7.apk`,
`Caldo-universal.apk`, refreshed after each change. A GitHub release `v1.0.0`
carries the same three files.

## Running on the emulator

The shell has `ANDROID_SDK_ROOT=/opt/android-sdk`, which has **no emulator and
no system images** — the real SDK is `~/Android/Sdk`, and the AVD's image path
is relative, so it resolves against the wrong root and dies with "Broken AVD
system path". Launch it like this:

```sh
SD=~/Android/Sdk
ANDROID_SDK_ROOT=$SD ANDROID_HOME=$SD $SD/emulator/emulator -avd pixel_api34 &
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell monkey -p com.igor.caldo -c android.intent.category.LAUNCHER 1
adb exec-out screencap -p > shot.png     # then look at it
```

Changes here are judged by eye: take the screenshot and check it before saying
it works. `adb shell input tap/swipe/text` drives it; the screen is 1080x1920
at dpr 3 (360x640 logical).

One thing that looks like a bug and is not:

- An ANR under load is usually host starvation (a Gradle daemon plus the
  emulator on 13GB), not a hang in the app. Check whether unrelated processes
  ANR'd in the same second before hunting for a layout loop.

## Conventions

- Comments explain **why**, at roughly Dicty's density. No narrating what the
  line already says.
- Commit messages are prose: what changed and the reason it needed changing.
  End with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- `flutter analyze` must be clean before a commit.

## Known gaps

- In week view, swiping sideways still pages by **month**, not by week.
- Holiday names are in each country's own language where it was natural
  (DE/FR/ES/IT/PL/NL/TR) and English elsewhere; nothing is localised otherwise.
- Signing uses the debug keys (Flutter's default), so installs warn about an
  unknown developer.

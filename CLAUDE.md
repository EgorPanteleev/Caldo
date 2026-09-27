# Caldo — working notes

A calendar + to-do app for Android, Flutter, local-only storage. Private repo:
`github.com/EgorPanteleev/Caldo`. It is modelled on its sibling app **Dicty**
(`/home/igor/dev/src/Dicty`) — same stack, same theme. When a question about
style or structure comes up, look there first.

## Stack

Flutter 3.38.6 / Dart 3.10.7. `provider` (state), `sqflite` (storage),
`shared_preferences` (settings), `google_fonts` (Inter), `intl` (dates).
Dev-only: `sqflite_common_ffi`, so widget tests run against a real database.

## Layout

```
lib/
  data/holidays.dart     public-holiday rules, computed on device (no network)
  db/database.dart       schema v2: lists, tasks (+ migration)
  models/                task.dart (Repeat, Priority), task_list.dart
                         (ListStyle, colorOfTask)
  providers/             task_provider.dart, settings_provider.dart
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
  teleported mid-drag.
- **A day's tasks are marked with a line each**, the width of the day, stacked
  under the number — not dots. Holidays come first, in green.
- **An opened day's task titles take the lines they need, up to two.** A day
  cell is about seven characters wide, so one line cut most names off — but a
  chip is measured (`TextPainter`, in the chip's own font and width) and a
  short title still gets a single-line chip. Take the height from the painter
  and round it up: a box worked out from the font size instead is a box the
  text can overflow by a fraction of a pixel, and an overflowing
  `TextOverflow.fade` fades away the bottom half of every letter.
- **Collapsing to the week slides the grid past a shrinking window**; every
  week keeps its full-month height and the selected one is where the window is
  left sitting. Shrinking the rows themselves made the numbers close in on each
  other and read as a glitch.
- **Picking a day in the opened month opens it as a card on top** (`day_sheet`)
  rather than collapsing the calendar to make room — the tap was made from that
  view, so it should still be there underneath.
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
  whole screen `_menuWidth` to the right, rounding and shadowing its left edge
  as it goes, so what is on it stays legible instead of being hidden under a
  panel. This is not a Material `Drawer` — the menu is always in the tree,
  behind the screen, which is why a test cannot tell open from closed by
  looking for its text and reads the screen's offset instead. Back closes it
  (`PopScope`), as does a tap or a leftward swipe on the screen.
- **Today is a plain light badge; the selected day is a thin neutral outline.**
  Accent on either was "too much". The accent survives on the add buttons, the
  TODAY label and the menu's current entry.
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
  beside the field the eye is already on. The focused field's outline is
  neutral too; an accent ring around half the screen was the loudest thing on
  it.
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
- **The strip the add field sits on follows what is above it** — the calendar's
  own ground once the month is opened out, the app background while the day's
  tasks are still on screen — and whatever is above fades into it over the last
  22 points rather than being sliced off square by it.
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

## Tests

`flutter test` — 74 tests, all passing. Keep them that way; several real bugs
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

Two things that look like bugs and are not:

- `google_fonts` logs a failure to fetch Inter — the emulator has no network,
  so Flutter falls back to Roboto. On a real phone it downloads once and caches.
  Offer to bundle the font if it ever matters.
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

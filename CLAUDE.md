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
The home-screen widget is native (`TodayWidget.kt`, plain `RemoteViews`, no
Glance and no `home_widget` package).
The app is local-only except for one thing: asking GitHub whether a newer
release is out, and fetching it — see the decision below.

## Layout

```
lib/
  data/holidays.dart     public-holiday rules, computed on device (no network)
  l10n/strings.dart      every word the app says; words_*.dart, a table
                         per language
  db/database.dart       schema v7: lists, tasks, completions (+ migrations)
  models/                task.dart (Repeat, Priority), task_list.dart
                         (ListStyle, colorOfTask), completion.dart
  providers/             task_provider.dart, settings_provider.dart,
                         events_provider.dart
  services/reminders.dart  the notification each dated task gets
  services/background.dart a reminder's buttons and the widget's ticks,
                         run on isolates of their own
  services/today_widget.dart  the copy of the agenda the widget draws from
  services/device_calendars.dart  the phone's own calendars, read-only
  services/updates.dart  the newer-release check, download and install
  screens/               home (shell + menu), tasks (Schedule), calendar,
                         board, done, search, task_edit, settings
  theme/app_theme.dart   AppPalette + AccentColors ThemeExtensions, AppColors
  utils/dates.dart       every date/time string the UI shows
  widgets/               month_grid, task_card (+ HolidayCard), task_row,
                         colour_selector, groups,
                         date_time_pickers, day_sheet, menu_button,
                         quick_add_bar, screen_header, selection_bar,
                         theme_switcher, slide_into_place,
                         tick_off (+ AsShown), carry, selection
```

On the Android side, `MainActivity.kt` (refresh rate, keyboard, updates,
widget launches, the phone's calendars), `TodayWidget.kt` (the widget and the `Headless` engine its
ticks run on), `TodayWidgetRuns.kt` (its runs and cards) and `CaldoApplication.kt`
(redraws the widget when its copy changes).

The launcher icon is drawn in SVG under `assets/icon/src` and turned into
Android's sizes by `tool/make_icon.sh` (needs `rsvg-convert`); the PNGs it
writes are checked in.

Five destinations — **Schedule**, **Calendar**, **Board**, **Done**,
**Settings** — in a drawer behind the menu button at the top left of each,
and nothing else in it. Done was asked for as "a Done log or simple stats";
Board came after it. Any of the first four can be taken out of the menu in
Settings; Settings itself cannot.

**Lists are groups, and there are still no list screens.** The Lists, list
and list-edit screens were deleted once they had been unreachable for a
while. The lists underneath every task (`list_id`, `TaskList`, the default
"Personal") came back to the surface as **groups** — see the decision below
— through a row of chips and a sheet, not through screens of their own. The
provider's old "open list" (`openList`, `tasks`, `search`),
`GradientIconButton` and `SelectionBar` stay gone. Tests that need a task by
name read it from the database (`taskNamed` in `test/support/test_db.dart`).

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
  snap carries the drag's own speed, not a fixed ease from a standstill.
  Pulling the whole way was never the point. **One drag goes one state along
  and no further** (`_dragBy` clamps to either side of where it started): a
  long pull from the week used to run on through the month and open it out. **The snap is a glide, not a
  spring** (`_Glide`): a cubic that starts at the finger's speed and stops
  dead on the state at a set time — 460ms for a whole step, down to half
  that for a short remainder — and never overshoots. A flick sets its
  starting speed (up to three times the average, beyond which it is eased
  down from) but does not shorten it: letting it do so, at 420ms, was "too
  fast", since most snaps follow a flick and those took a quarter second.
  A tap sets off at the average speed rather than easing in, which read as
  a pause before anything moved. It
  was a critically damped spring, softened twice to be "a little bit
  slower" (stiffness 340, then 200, then 120), and the softest was "not
  smooth": it crept its last few points for most of a second (60 frames
  for one snap) and a flick carried it past the state and back, which at
  the open and week ends was cut off at the controller's bound. A slower
  spring is a longer tail and an easier overshoot; slow it here by
  lengthening `_snap`.
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
  text can overflow by a fraction of a pixel.
- **A title too long for the chip's width fades; one too long for its height
  is cut at the line** (`_measure` keeps the painter's `didExceedMaxLines`
  beside its height). A fade is right when it runs off the end of a line —
  no letter cut in half, no ellipsis eating two of the few characters there
  are. It is wrong when the paragraph has overrun its last line, because
  what Flutter fades then is the bottom half of that line: every letter on
  it is sliced through the middle and the chip reads as a rendering fault.
  It was reported as "in the bottom it's like more transparent, looks ugly",
  and the ghost under such a line is that line's own lower half.
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
  other and read as a glitch. **Each row is carried from its place in the
  month to its place in the week, and the week's row is a fifth taller than a
  month's** (`MonthLayout.weekScale`), so the rows below the selected one draw
  apart from it and stay behind as the day panel comes over them. All of it
  moving up as one block at a row's height looked, for a week mid-month, as
  if the grid trailed the panel — "laggy when the date is not in the first or
  last row" (frame times were the same for every row: it was the motion).
  Matched to a recording of another calendar the user supplied, measured
  frame by frame: its week row is 79–82 points to its month rows' 68, and its
  rows' positions there fit this interpolation. Holding the selected week
  still until the closing edge reached it, then letting the edge carry it,
  was tried before this and rejected.
- **Picking a day in the opened month opens it in a sheet from the foot of
  the screen** (`day_sheet`) rather than collapsing the calendar to make room
  — the tap was made from that view, so it should still be there above it.
  It was a card in the middle of the screen, a panel within a panel with two
  lines to every task, and a day of six filled the screen: "too big and
  inconvenient to use". Chosen from three mockups (a sheet, a popover at the
  day, folding back to the month). The sheet sizes to the day and stops at
  56% of the screen; its cards are one line each (`TaskCard.dense`, the time
  at the far end and the repeat rule as a mark), an empty day is a line of
  text rather than the screens' placeholder, and the list fades under the
  field only while there is more of it below. Dragged down, it goes. Its list
  is penned without an overlay of its own (`DragWithin.overlay`): an overlay
  takes all the height offered, which made every day's sheet as tall as the
  fullest. The keyboard lifts the whole sheet, measured as the screens
  measure it (`KeyboardGap`), so the field sits on the keys.
- **The days below the grid are a pager, one page per day.** Picking a day
  slides it in from the edge it lies on and the days can be swiped through
  directly, carrying the month round with them. A day more than ten away is
  jumped to; watching a month of days fly past says nothing. The two pagers
  each ignore the change the other has already made, which is what keeps a
  swipe across a month boundary from bouncing.
- **Week rules only arrive at the end of the opening** (`weekRuleAlpha`, last
  quarter) and never while the month is shrinking.
- **Which screen the app opens on is a setting** — any of Schedule,
  Calendar, Board and Done (`AppScreen`, read in `main` before the first
  frame). It cannot wait for
  `SettingsProvider.load`: that ends by asking Android about notifications,
  which on a first run is a dialog the user has to answer, and waiting for it
  would hold the app on a blank screen. So the start and the hidden screens
  are read on their own first, and the shell takes the start as it is built
  and never again — a screen that jumped out from under the setting being
  changed would be startling, and the setting is about the next launch.
- **Each of those four can be switched off, and leaves the menu**
  (`hiddenScreens`, asked for as "set in settings which to show or hide in
  left list"). Never all four — the last one's switch is disabled and the
  provider refuses it — and Settings is always there, being the way back.
  The start is always a screen in the menu: hide the one chosen and the app
  opens on the first one left, but the choice is kept, so putting the screen
  back puts it back as the start (`SettingsProvider.startScreen`). The
  overdue count moves from Schedule to Calendar while Schedule is out. A
  hidden screen is still built behind the others; it is only unreachable.
- **Settings is a list of six pages, not one long page** (`_Page`, and
  `_screens`, `_general`, `_appearance`, `_calendar`, `_tasks`, `_reminders`):
  Screens, General, Appearance, Calendar, Tasks, Reminders, each row saying
  under its name how that page stands ("English · 3:00 PM"), with About on
  the list itself. Every setting on one page ran to four screens of
  scrolling — "too long … split it up in subgroups". A page is pushed over
  the shell with a back arrow, and splits again into small panels: the
  holidays and the phone's calendars a panel each, clearing completed
  tasks on its own away from the switch above it.
- **Every page of Settings is a panel per section, the way the phone's own are drawn**
  (`_Group`, `_Row`, `_SwitchRow`, `_choose`): a row is an icon, what it is,
  and under that what it is set to; a tap flips its switch or opens a sheet
  of the choices, the one in force ticked. Asked for as "make settings better
  at all". It was a stack of separately outlined boxes with a segmented bar,
  a dropdown or a switch each — three ways of choosing on one screen, and a
  box round every line. The value goes under the title rather than at the
  far end because twelve languages have to fit beside a chevron. Clear
  completed is the one red row, with no chevron: it is a thing done, not a
  setting opened. About shows the installed version (`Updates.installed`).
- **Nothing on a screen moves when the keyboard does** (`SafeArea`'s
  `maintainBottomViewPadding` in the shell). Android stops counting the
  gesture bar as padding the moment the keys cover it, so a screen drawn edge
  to edge grows by that much as the keyboard arrives: it was reported as the
  month and the day's tasks shifting slightly every time the add field was
  tapped, on a phone and not on the emulator, whose window stops above the
  navigation bar and never had the padding to lose. The strip stays reserved
  instead, and `KeyboardGap` subtracts it from the lift, since the bar now
  starts that much above the window's edge.
- **Ticking a task off is drawn at once, crossed out a beat later, and only
  taken away if it is leaving** (`CheckMark`, `TaskProvider.settle`/`linger`/
  `leave`, `TaskCard.ticking`/`leaving`, `TaskProvider.isTicking`/`isLeaving`).
  The tick answers the tap: the square fills and the stroke runs through it
  (240ms). 250ms after that the card is crossed out and its ink sinks — the
  same moment a card that is leaving its run starts to go — and a card
  leaves only if its task will not be in that run once it is read back: a
  done task leaves the overdue backlog, since it is not overdue any more,
  and a repeating one rolls on to its next date and leaves every run. Those
  fade over the first half of 280ms while the gap they leave closes over the
  whole. Everything else is crossed out in place, holds there 150ms
  (`TaskProvider.hold`), and then **slides** to the end of its day as the
  run is read back (`SlideIntoPlace`, 260ms), with the cards below it rising
  into the gap — under a second from tap to rest, after "make it faster".
  Schedule and Calendar must play this the same way: Schedule's days were
  once re-sorted on every build (`upcomingByDay` as a getter), so a ticked
  task there jumped to the end the instant it was marked done, while the
  calendar waited. The grouping is now made once per load and marked in
  place like the rest. Three rounds got here: the card used
  to leave the instant the tick was drawn ("disappears too fast"), then every
  ticked card faded out — including ones the reload put straight back at the
  end of the day, which was a card disappearing and reappearing ("it's
  wrong") — and then it stayed put, which was asked back: "move it to the
  bottom". Taking a tick back goes at once, and a second tap while a card
  waits stops it.
- **A tick off offers Undo for four seconds** (`tickOff`, `_UndoBar`, in
  the quick-add row's place). Undo writes back the task as it was before
  the tap (`TaskProvider.restore`) rather than ticking it again, because a
  repeating task has already rolled on to its next date and a second tick
  would only roll it further. Every card's tick goes through `tickOff`;
  untick is already an undo and gets no bar.
  **It takes the add row's place, field and plus together, at their size**
  (`UndoScope`, `UndoSlot`): each screen with a field, and the day card, is
  a scope, and a tick on a card in it is offered in that scope's row, which
  cross-fades to the bar and back. Chosen from mockups of four ways of
  drawing it. Before this it floated above the field — first a snack bar,
  then an entry on the root overlay so it could be frosted glass — and
  however it was dressed it was a second grey pill the height of the field
  stacked on the first, which read as two fields, and it cut across the card
  under it ("still looks bad"). The cost is the field, for four seconds, so a
  tap on the bar anywhere but Undo puts it away and opens the field. The
  field stays in the tree under it, so what is typed and its hold on the
  keyboard survive. One offer at a time, across scopes.
  **The four seconds are drawn across the whole bar** (`_Countdown`, asked
  for as "the timer like gradient in all panel"): the field's grey with the
  accent mixed in a quarter covers it at first and draws back to the start,
  its leading edge a ramp four tenths of the bar wide. A finger holding the
  bar holds it still. Three earlier countdowns were taken out unasked for —
  a ring round the tick ("i dont like this rounded checkbox"), a line along
  the foot, and the tint draining out of an Undo chip alone, a smudge.
  **It keeps its own time and can be brushed off** (asked for as "make
  ability to brush off the undo"). A finger resting on it holds the offer,
  and letting go starts it running again. It follows the finger sideways or
  down (upwards it only gives a little), stays solid for the first sixth of
  the screen and fades after, and goes past a quarter of the width, 36
  points down, or on a throw; short of that it settles back. The add row
  comes back under it as it goes (`UndoSlot._away`), all of it by the point
  where letting go would throw it: pulled off a blank strip, the bar looked
  as if it was taking the field with it ("i dont see add task under it when
  im moving undo bar").
  On it: a plain grey tick, the task's name, and Undo as plain words
  (`_UndoButton`) in the accent lifted a third towards white, the arrow
  drawn (`_UndoArrow`) in the tick's round-ended stroke. Undo is the only
  thing on it in the accent: a filled accent tick and an accent countdown
  beside it made three purple things on one small bar — "too many accent
  colours" — and on a chip of the accent's tint it was a pill in a pill.
- **A card slides to its new place by task, not by card** (`SlideIntoPlace`).
  `TaskProvider.rearranging` fires just before a re-read; every card notes
  where it stands in its scrollable's content space (so a scroll is never
  taken for a move), and after the new layout each one that moved is drawn
  back at its old place and eased to the new one. Notes are keyed by
  (screen, task id): a reorderable list hands card state to a different task
  when it reorders, and Schedule and Calendar are both alive under the menu.
  **The move is found while the card is painted** (`_RenderSlide`), in the
  frame that lays out the new order. Found after the frame, as it first was,
  that frame had already gone out with every card at its destination, and
  the slide began by jumping back — a stutter at the start of every one.
  Painting is the earliest the new place is known, and a card that has only
  moved is not repainted on its own (the list's repaint boundary just shifts
  it), so a rebuild marks it for paint.
- **A tick does not rebuild the screens; only the read-back after it does**
  (`TaskProvider.ticked`, `shown`, `AsShown`). A notify from the provider
  rebuilds both screens, the calendar's month and pager among them, and the
  tick used to send one when it was drawn and another when it was crossed
  out: measured on the emulator with frame timings logged from a release
  build, those frames took 9–14ms to build, past the 8ms a 120Hz phone has,
  at the very frame each step started on — reported as "laggy". The cards
  listen to `ticked` instead and draw a task as `shown` says, and the lists
  are read back, with one notify for month and agenda together, once the
  tick is over. That read-back is the one heavy frame left (8–10ms on the
  emulator), and it lands before the slide moves anything. Settings and the
  menu `select` the one value each wants rather than watching the provider:
  Settings, hidden in the stack, was being rebuilt in whole on every change
  to any task.
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
  either was "too much". The badge takes the colour the day's own
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
- **Every time in the app is written on one clock, which Settings chooses**
  ("Times are written": 3:00 PM or 15:00; until it is chosen, the phone's
  own). It was a 12-hour picker over cards that wrote 24-hour times, so a
  task picked as 6:00 PM read 18:00 — "make it consistent for both".
  `Dates.time`/`Dates.clock` are the only places a time is formatted, and
  take `h24`; widgets pass `MediaQuery.alwaysUse24HourFormatOf(context)`,
  which `CaldoApp`'s builder sets from the setting, so a change redraws
  every time on screen at once. A notification has no screen to read, so it
  uses `Dates.use24Hour`, kept in step by `SettingsProvider`, and changing
  the clock re-sets the alarms already standing (`Reminders.refresh`) so
  their text follows. On a 24-hour clock the picker's hour wheel runs 00 to
  23 and the AM/PM wheel goes; the shortcuts under it follow suit.
- **The task form hides its way back once anything is changed**, and puts
  Cancel and Save at the foot instead. An arrow beside unsaved edits is an
  invitation to lose them. Untouched, the arrow is there and there is nothing
  to save. Every field marks the form as touched, including the clears and the
  two text controllers. The pair is pinned to the foot of the screen, with
  the form fading out under it (`GroundFade`) — written after the last
  field, it was a scroll away. It rides the keyboard as the quick-add bar
  does (`KeyboardLift`, no `Scaffold` resize, the gesture strip kept); a
  resized form made it misbehave the way that bar once did. Only the list's
  viewport is shortened (`KeyboardRoom` under it), so a field's own scroll
  into view clears the keys, and every field keeps the fade's height clear
  below it as well (`_reveal`), or it comes to rest dimmed inside it. Save
  and Cancel put the keyboard away; left up, it is handed to whatever field
  had it on the screen underneath.
- **A sheet's actions are two plain words**, Cancel and Save, drawn in towards
  the middle rather than pushed out to the corners — pinned to the edges they
  read as one control at each end rather than as a pair to choose between. A filled button beside an outlined one were the only heavy things in a
  sheet this plain, and they argued over which was the one to press.
- **The plus beside the quick-add field opens the full form**; the tick files
  what has been typed. A plus that did nothing at all on an empty field was
  the state it was left in when the Schedule header's add button was removed.
- **A task is in one group, and Schedule and the calendar can show one
  group at a time** (`GroupChips`, `TaskProvider.showGroup`, `groups.dart`).
  Asked for as "split tasks in groups, for ex university, friends", without
  setting anything up in Settings. A group is one of the lists every task
  already had. **Tags came first and were taken back out** — any number per
  task, `#uni` in the add field, a filter button in the header: "i dont
  like tags like this, it must be more group than tag". Chosen from three
  mockups: a row of chips under each screen's header — All, each group with
  its colour as a dot, and a plus — always there, even with only the default
  group, since it is where groups are found to exist. The two screens share
  one choice. A group is made from the plus there or beside the form's
  Group row, and a long press on any of its chips renames, recolours or
  deletes it; there is no list of groups anywhere else. Deleting moves its
  tasks into the default group (the oldest, "Personal", written in the app's
  language until renamed), which cannot itself be deleted.
  While a group is chosen: only its tasks are drawn, the phone's calendar
  events go (they are in no group), holidays stay (they are the calendar's,
  like the red Sundays), and a task added on either screen or from the form
  goes into it — anywhere else, it would vanish as it was filed. The choice
  is held for the run of the app and not stored. The provider keeps the full
  lists beside the narrowed ones; alarms, the home-screen widget and the
  menu's overdue dot read the full ones (`allOverdue`, `allUpcomingByDay`).
  **A group's colour is its tasks' colour.** New tasks have no colour of
  their own, and moving a task to another group in the form puts it back on
  the group's. The Settings colour that every new task used to start in
  ("New tasks start in the colour Settings names") would have hidden every
  group's colour, so it went: whatever it was set to became the default
  group's colour, once, on the first start after (`_taskColourToGroup`).
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
- **The strip the add field sits on, and the fade above it, follow what the
  field is actually standing over** (`_groundUnderField`, `_fadeStrength`,
  `_overGrid`). That is the calendar's own black once the month is opened
  out and the day panel's grey while the day's tasks are on screen — but
  the keyboard moves the field, and once it has carried the field up past
  the panel onto the grid, the grid is what is under it. Following only the
  calendar's state, the field rode up over the month as a grey slab in the
  compact view, and in the opened one it lost its fade and cut the week
  under it off square — reported as "no smooth transition between add task
  and calendar". The day panel's drawn height is kept from the layout so
  the field can tell where it is: past the top of the panel, the ground
  turns to the calendar's over one fade's height, and the fade is on
  whenever the keyboard has lifted the field at all.
- **Whatever is above the add field fades into the ground it sits on**
  (`GroundFade`, 48 points, on both the calendar and Schedule). Sliced off
  square by the field, the last card in a full day ended in a straight cut
  across the middle of a word. The ramp is a smoothstep, not a straight one: a
  straight ramp has a visible edge at each end, where it starts and where it
  finishes, and both read as lines. It is one widget rather than two copies
  because the two screens have to look the same doing it — which is how it
  came to be asked for on Schedule in the first place.
- **The fade goes as the month opens out — while the keyboard is down**
  (`GroundFade.strength`, driven by the calendar's expansion and the lift). It is for a list that runs under the field, and
  the calendar only has one while the day's tasks are on screen. Opened out,
  what sits above the field is the grid — a fixed layout that ends above the
  field with nothing to soften — so the fade only dimmed the last week of
  the month. Measured: the outline around a selected day in the bottom row
  fell from 155 to 112 over its last sixty pixels, and a day with enough
  tasks had the chips in that strip washed out with it. It was reported as
  "when I extend my calendar, in the bottom it's like more transparent".
- **The keyboard arrives over both screens, it does not shorten either.**
  Neither `Scaffold` resizes for the inset; the quick-add bar is wrapped in
  `KeyboardLift`, which translates it instead, and the fade above it goes up
  with it. A resizing `Scaffold` takes the room out of whatever is above the
  field, which on an opened month means squeezing the very grid being looked
  at. Schedule keeps the end of its run reachable by putting the keyboard's
  own height at the foot of it (`KeyboardRoom`) rather than by shrinking the
  viewport. The shell's `Scaffold` does not resize either — it would shorten
  all three screens before any of them was asked.
- **The quick-add bar is attached to the keyboard: its bottom edge is the
  keyboard's top edge, at every moment of the slide.** `KeyboardLift`
  translates the bar and that is the whole of it — no animation, no spring,
  no speed limit, no rule about which reports to believe. Android says where
  the keyboard is; the bar is there in the same frame. If the keyboard
  jumps, the bar jumps with it, because that is what attached means.
  Three cleverer answers were tried first and each was wrong the same way: a
  real keyboard covers 154 points in the first 50ms of its rise, better than
  3000 points a second, so any cap under that turns following into trailing,
  and no tuning turns a lag back into an attachment. **Do not put a curve
  back in here.**
- **Where the keyboard is comes from Android as well as from Flutter, and
  the two are reconciled by taking whichever reaches further**
  (`KeyboardGap`, `MainActivity`). `viewInsets.bottom` is not one
  measurement: on a window drawn edge to edge it leaves the system bar strip
  at the foot of the screen out of a slide's animated values and puts it
  back at the end. That is the ten points the bar used to ride low for the
  length of a slide, and the jump at the end of it, reported in the first
  message of this whole thread.
  Two cleverer answers failed before this one, and both failed the same way
  — they tried to correct a number whose meaning changes. Adding the strip
  while an animation was running put the bar a strip *above* the keys on any
  slide whose insets already counted it, which turns out to be some of them:
  opening the field, closing it and opening it again quickly produces one of
  each. Capping the correction at the keyboard's known height only helped
  once a slide had settled, so it did nothing at all for the fast case,
  which is the only case that shows it. The flag saying which meaning is in
  force arrives down one channel while the number arrives down another;
  that is a race, and no arithmetic on the far end of it can win.
  So the activity reports where the keyboard is — `Type.ime()` from the
  bottom of the display, less whatever lies below this window, which is the
  navigation bar below Android 15 and nothing at all edge to edge — and
  `KeyboardGap.of` takes the larger of that and `viewInsets`. One number
  cannot disagree with itself, and the larger of two cannot put the bar over
  the keyboard: the worst either can do is hold it where the keys were a
  frame ago.
  Measured off a phone recording of the bug: the field sat 17px from the
  keys on the first opening and 62px on the second, and waiting a couple of
  seconds between them made it go away — which is what pointed at two
  overlapping slides rather than at any one convention.
- **Whether the window reaches past the system bars is read from the
  insets the content view is handed, never from how tall it happens to be**
  (`MainActivity.contentNav`). A window that fits the bars has them taken
  out of the insets before they reach its content view; one drawn edge to
  edge does not. That reading does not move with `adjustResize`.
  Working it out from the content view's height against the display's is
  what four attempts at one bug came down to. `adjustResize` leaves that
  view between its two heights for a while after the keys have gone; a
  reading taken then says the window reaches the bottom of the display when
  it does not, and once believed it was never contradicted, because on a
  phone where the honest answer is "it does not" no measurement ever says
  so out loud — the honest answer is the default. From then on the keyboard
  was reported a navigation bar too tall and the field rode a bar above the
  keys for the length of every slide. The user had it right before the
  numbers did: it was never about doing it fast, it was about which button
  closed the keyboard, because that is what decided when a poisoned reading
  was taken.
  Measured from a recording with the numbers on screen, against the
  keyboard's painted position: on a good slide the app's figure was right
  to within a point at every moment; on a bad one it was a constant 29
  points — two of that phone's 14.9-point bars — too tall from the first
  frame to the last.
- **A tick on an empty field does what cancel does: the keyboard goes and
  the field keeps hold of it** (`QuickAddBar._submit`). On a phone, the
  opening after a tick on an empty field came up with the field a strip
  above the keys, every time, and the opening after a cancel never did. Six
  releases went at the keyboard arithmetic and at how the keyboard was
  hidden before the difference that remained was looked at: letting go of
  the field closes its connection to the keyboard, so the next tap brings
  the keyboard up from scratch, and that is the only opening that ever went
  wrong. Back leaves the connection open. With a title typed the tick still
  lets go, since a task has been filed and the field's job is done — if the
  same jump turns up after filing, that is where to look.
- **Long-pressing the Settings title puts the keyboard's numbers on screen**
  (`KeyboardGap.showNumbers`, drawn by `KeyboardNumbers` above the add
  field): the inset Flutter reports, what Android says, the strip the layout
  reserves, the lift the three of them come to, and on a second line the
  raw figures Android was asked — the IME inset, the navigation bar, and
  the offset below the window. Four rounds went into
  one keyboard bug on a phone that cannot be plugged into this machine,
  every one of them a guess at which number was lying. A recording of the
  fault with this on answers that in one go. Off by default, not stored.
- **The inset is read in `KeyboardLift` and `KeyboardRoom` and nowhere
  else.** It changes on every frame of a slide and whoever reads it rebuilds
  that often, so the two widgets that move with it are the two that read it,
  and the screens around them are left alone.
- **The dark ground is true black.** The calendar's already was, so an app
  background a shade lighter put a seam down the screen — and on the OLED panels
  this is built for, black is black rather than a very dark grey. Everything
  above it is a raised grey instead.
- **The controls are neutral; the accent is kept for what is rare**
  (`AppTheme._build`'s segmented, text-button, filled-button, input-focus
  and selection themes; the menu's current entry; the carry marks). The
  selected segment and the open screen in the menu are lifted in `field` grey, a
  focused field is outlined in `muted`, and a dialog's buttons are plain
  text beside a light filled one. Every one of those was the accent, and on
  a dark screen they added up to most of the colour there was — "too many
  accent colours … all app". What keeps the accent: the switches in
  Settings (made neutral with the rest, and asked back), Undo, the update
  banner,
  a clock wheel under the finger, and the accent and colour pickers in
  Settings, which are choosing a colour. Tasks wear their own colour, not
  the accent; that the default list is violet, the same hue as the default
  accent, is why the calendar still reads purple when nothing else does.
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
- **A day's tasks can be dragged into an order of their own** (`sort_order`,
  schema v3, null until a day is actually dragged). Null rather than zero on
  purpose: a column of zeros would claim every task had been placed by hand,
  and a day nobody has touched should keep the order it has always had. A task
  that arrives in a day somebody has already arranged goes after the arranged
  ones. **Done tasks go after open ones** (`TaskProvider._compare`, the
  database's `_order`), and the hand order sits under that. It was taken out
  once, because a ticked task jumped to the end of its day the moment the
  list was read back and looked like a card vanishing and turning up
  somewhere else; it came back once the move could be shown as a slide,
  since a day's done tasks at the top of it were in the way of what is left.
  Done tasks are in the order they were ticked, the latest last, ahead of
  any hand placement (`completed_at`, in both orderings), so the card just
  ticked slides to the very end of its day. They used to be ordered by
  creation like any others, which put a newly ticked task below every open
  one but somewhere among the done ones. The cost: a done task dragged
  among other done ones goes back to its place by tick when the day is read
  back.
- **A task can carry a checklist** (`Subtask`, `Task.subtasks`, schema v4).
  It is stored as JSON in a column of the task's own row, not in a table of
  its own, because a task is written back whole — by Undo
  (`TaskProvider.restore`) and by a repeating task rolling on — and the
  checklist has to go with it every time; a repeating task comes round
  again with every step unticked. The form has a Subtasks panel under the
  notes: each step is ticked, edited or removed where it stands, and the
  line at its foot adds one on Enter and keeps the keyboard for the next
  (Enter on an empty line closes it); a line left typed without Enter is
  saved as a step too. A card shows how far through it is ("☑ 2/5") beside
  its time, and tapping that opens the steps **under the title row**, where
  each can be ticked without opening the task — in the row, the card's own
  tick sank to the middle of the taller card. The steps are ticked in the
  task's colour, as the card's tick is; in the form they are neutral, like
  its other controls. The count is a pill with a chevron, lifted out of
  the card in the text's colour: written in muted grey like the time beside
  it, it read as one more fact about the task and nobody found that it
  opened. Search matches a step's words, but the JSON is
  filtered in Dart afterwards: a search for "done" or "title" would
  otherwise find every task with a checklist.
- **A long press picks a card up; it used to open the editor**, which a tap
  already does, so nothing was lost. There are no drag handles: the card is
  the handle, and a grip beside every row would be a column of furniture down
  a list whose whole job is to be read.
- **Several tasks can be picked out and dealt with at once** (`Selection`,
  `SelectionScope`, `SelectionSlot`, `TaskProvider.moveAllToDay`/
  `moveAllToGroup`/`setAllDone`/`removeAll`). Asked for as "select several
  tasks to move it to another day or delete or smth". The long press
  stays the drag's: a card held and moved is carried, and one held and let
  go within 18 points of where it was pressed is picked out — the scope's
  `Listener` sees the release before the list's drag does, and the lists
  report what they lifted (`Selection.lifted`). Once anything is picked
  out, a tap anywhere on a card, its tick included, picks it out or puts
  it back, so nothing is ticked off or opened by mistake halfway through.
  A picked-out card is lit in its own colour: a 1.5pt rim of the task's
  colour lifted two fifths towards white, in front of its ink
  (`foregroundDecoration`, so the title does not shift), a soft glow of
  that colour outside it only (`BlurStyle.outer`; under the translucent ink
  a shadow clouds the card), and a little more ink. The first rim was
  white at 1.8pt — a frame put round the card rather than the card lit up,
  and asked to look nicer. The leaving animation's `ClipRect` clips only
  while a card is leaving; at rest it cut the glow off flat along the top. The quick-add row gives its place to a bar the field's
  size, as it does to Undo: a cross, "3 selected", and Move to a day (the
  date sheet; each task keeps its time), Move to a group (back on the
  group's colour, as on the form), Mark done (each tick logged, a
  repeating task rolling on; Mark not done when every one is done
  already) and Delete, the one action that asks first. A picked-out card
  carried to another day takes the rest with it (`Selection.carried`).
  Schedule, the calendar and the day sheet are each a scope; one
  selection at a time across them, put down by Back, by choosing another
  group, and by opening the menu, since the screens stay alive behind it
  and one left holding a selection would have Back answer to it from out
  of sight. Not on the board, whose cards are moved between lanes.
- **A card carried to another day moves to that day** (`Carry`,
  `CarryArea`, `CarryMark`, `TaskProvider.moveToDay`). This was ruled out
  once — "a change of date wearing the clothes of a change of order" — and
  then asked for. On Schedule a card can be let go in any other run, at the
  place a rule marks between its cards, and moves to that run's day (No
  date clears the date); the Overdue run takes nothing, since it has no one
  date to give. On the calendar a card can be carried up out of the day's
  list onto the month, where the day under the finger is outlined, and goes
  to the end of that day. Either way it keeps its time of day. Let go
  inside its own run, it is the same reorder as ever.
  **Over the month the card turns into a tile the size of a day**
  (`_ShrinkingCard`, `Carry.shrinkTo`): the card fades while a tile draws
  in from its outline to the finger and then moves freely with it, with
  the day it would land on marked by the outline as before — asked for as
  "transform into smaller rect like day of calendar". The tile is a rounded
  square (corners 14) in a clear fill of the task's colour, with a 1.5pt
  light rim — asked for "more rounded" and "more outlined" — a shadow
  under it, and the title centred on two lines ending in an ellipsis; its
  first form, a chip's dim ink with three lines of small type cut off at
  the bottom, was "ugly". It is kept on the grid at the sides. Off the month it grows back into the card. On Schedule, which
  has no days to shrink into, the card instead thins out over another run
  so the rule under it shows. Two details cost a round each: a reorderable
  list moves its carried card along its own axis only, so a tile placed
  relative to the card stayed behind when the finger went sideways — it is
  placed on the screen, in paint (`_AtFinger`); and a `LayoutBuilder`
  inside the proxy is handed an unbounded height, which made the tile's
  rectangle NaN and pinned it to the left edge, so the card's outline is
  read from the render box's own laid-out size instead. The tile was once
  snapped into the cell under the finger, inside the outline; that was
  asked back — "it should not stick to date … must move freely" — so the
  tile follows the finger and the outline alone says which day.
  **Held at either side of the grid, the month turns** (`_watchEdges`,
  `_turn`): after 600ms within 24 points of the side, then every 900ms
  while it stays there. Held rather than touched, because the outer
  columns are days too. **The sides say so** (`_EdgeHints`): while a task
  is over the month, a small rounded tab with a chevron shows at the
  middle of each side, in the tile's own terms (the field's grey, a light
  rim), and the side being held widens and fills from the bottom over the
  hold, its chevron nudging outwards — without them, "user mb cant realize
  that he can move to another month". Neutral, not accent. The first try
  was a gradient down the whole height of each side, which read as a
  shadow across the days: "very bad". While a card is carried the turning month does not
  pick a new day below the grid — that would page the day's list, and the
  card with it, out from under the finger — and `loadMonth(keep:)` holds on
  to the day it came from even when the new month's range does not reach
  it. Put down in another month, the day it went to becomes the day shown;
  let go without a drop, the month on show picks its day as a swipe would.
  The lists' own drag is not touched. A `Listener` around each screen
  watches where the finger goes, and the pointer's release reaches it
  before the list's drag hears of it, so a release over another day calls
  `cancelReorder` — taking the card off the list without the drop it would
  otherwise animate back into its old place — and hands the task over. A
  move without a place lets go of the hand placement the task had (its
  `sort_order` is cleared), so it arrives after whatever the new day has
  arranged, as a new task would. The grid and the calendar's carry find
  days through one `MonthLayout`, so the cell outlined and the cell the
  grid draws cannot come apart. Every run can be dragged, the overdue backlog included — it was left out at
  first on the grounds that the order a backlog wants is how late each thing
  is, which ignored that on most days it is the larger part of what is on the
  screen, so Schedule read as a list that could not be dragged at all.
  Holidays sit in the list but cannot be picked up or displaced: nobody placed
  them there.
- **A hand placement is read before the date, not after it** (the database's
  `_order`). A run that has been arranged is made of tasks from different
  days, and sorting on the date first would quietly undo the arranging. The
  cost is that a day arranged by hand keeps that arrangement when its tasks
  later turn up in the backlog, ahead of ones nobody has touched — which
  settles the moment the backlog itself is dragged, since that writes a
  placement for all of it.
- **A card being carried is held inside the screen it can be dropped on**
  (`DragWithin`, `_KeepInside`). A reorderable list puts the card into an
  `Overlay`, and the nearest one is the app's — the whole screen — so it could
  be carried above Schedule's header or over the calendar's month bar,
  somewhere it could never be dropped. A `DragWithin` gives it a box:
  Schedule's whole run of days, and on the calendar the grid and the day
  together (the day's list is `penned: false` so it uses the calendar's).
  Clipping it to that box was worse than letting it wander, because it
  vanished a sliver at a time into the top of the screen; it is held against
  the edge instead. Before cards could change day it was penned inside its
  own run, between the headings on either side; the day sheet's list, which
  has nowhere else to go, still is.
  Three details, each of which cost a round: an overlay reads `initialEntries`
  once, so the entry is told to rebuild whenever the list changes; the keys
  belong to the state, not the class, because the day pager has several of
  these lists alive at once and a key may only be in the tree in one place;
  and the pen is anchored to rows that **cannot** be dragged — a heading, a
  holiday — because a row that can be dragged is lifted clean out of the list
  while it is carried and takes its key with it. Anchoring to the run's own
  first and last row meant that dragging the first card of a run, or the only
  card of a day, left nothing to measure against and it was clipped in half
  under the day bar.
- **A card being carried is the card and nothing else** (`liftedCard`). A
  reorderable list left to itself wraps it in a `Material` of the theme's
  canvas colour, which here is true black, so a card lifted off the calendar's
  grey day panel dragged a black slab around with it; painting the ground
  instead fixed the colour and kept the slab. What is painted is the card's
  own rectangle, in its own corners (`TaskCard.margin`, `TaskCard.radius`), in
  the colour it is standing on — nothing you can see. It cannot simply be
  transparent: the ink in a task card is translucent and has to land on
  something, or it goes muddy over whatever it is passing across. The lift is
  said with a little scale rather than with a box.
- **A day the reader has a word for wears it on a badge**, with the date
  written beside it — `Today` on a light pill, then `Sat, 4 Oct`. The word
  used to replace the date, which left the one day most likely to be looked up
  as the one day not written down. Overdue and No date are badges of the same
  shape, the first in red.
- **Pulling the day panel past either end drives the grid.** The panel is most
  of the screen; a swipe on it that had nowhere else to go used to do nothing.
  **The day's list only scrolls once the grid is down to its week**
  (`_HeldScrollPhysics`, `_listHeld`). Above that, every drag on it is a
  drag on the grid: the physics hands the whole of it on as overscroll and
  throws no fling. It used to scroll until it ran out and only then move
  the grid, so one gesture did either depending on where the list stood,
  and could leave the grid stopped halfway beside a scrolled list —
  reported as behaving "like UB". In the week a pull down scrolls the list
  back to its top, and **a drag that has scrolled the list never opens the
  month** (`_listScrolled`) — not by running on past the top, and not by a
  flick as it gets there, which ended the drag with a speed that
  `_onDragEnd` took for a pull. Opening the month mid-read was "while I'm
  scrolling I mustn't". A fresh drag from the top opens it; a list left scrolled when
  the grid opens some other way is run back to its top, since it could not
  be scrolled there.
  A day with nothing on it has no list at all, so the whole panel takes the
  drag directly, as the day bar does, and its placeholder is shrunk to fit
  rather than scrolled (`EmptyState.scrolls`). It used to be the
  placeholder's own small scroll view that answered: everywhere around the
  words did nothing, and a drag on the words moved the grid a few points
  and left it stuck between states.
- **Schedule is a heading and a reorderable list per run, not one list with
  headings scattered through it** (`_RunOfDays`, `_Run`). One list cannot tell
  a heading from a task, so the gap it opens for the card being carried could
  land at the very top — above the Overdue badge — and the screen appeared to
  jump down by a card's height. A list per run can only open a gap inside its
  own run, and the drop then needs no clamping at all: a run holds nothing but
  its own tasks, so there is nowhere else to land. The calendar's day panel is
  split the same way, holidays in one sliver and tasks in a reorderable one.
  They are **slivers** rather than nested lists so the whole thing is still
  one scroll, still lazy, and still auto-scrolls while a card is near the edge
  — `ListView(children: [...])` constructs every row on every build, and this
  screen rebuilds on each frame of the keyboard sliding in.
- **Schedule's header carries Search and Today**, the same pair the calendar
  has, and its quick-add field at the foot files on today. Today is a scroll
  home here, since today is the top of the run.

- **The month is laid out once and only moved while the calendar changes
  state** (`MonthGrid.animation`, `_RenderRows`). Every week row is laid out
  at its opened height and clipped to the height it has now, each behind a
  repaint boundary, so a frame of opening or closing places and clips six
  pictures and draws no day. It used to be rebuilt and laid out from scratch
  on every frame — forty-two cells, their numbers, marks and titles —
  because a cell was as tall as its row; on the emulator that was 3ms of
  every frame's UI work (now 1.3ms), and a 120Hz phone has 8ms for all of
  it: "laggy", once the snap was slowed enough to show it. What did depend
  on the row's height is drawn by the rows' render object: the selected
  day's outline (with its 160ms fade from the day before) and the week
  rules. The marks are still sized to the compact cell (`markerRoom`), and
  the cells keep the outline's 1.4 points of inset, which a `Container`
  border used to give them — without it the whole month sat that much
  higher. The fades follow the animation (`FadeTransition`), and the grid
  is rebuilt only when the marks or titles come or go. The month pager is
  built outside the calendar's `AnimatedBuilder` for the same reason.
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
  the alarms are brought back in line: an edited date, a tick, a deletion
  cannot leave an alarm behind. The first sync of a run cancels everything
  and sets the lot; after that only alarms whose time, title or text changed
  are cancelled or set (`Reminders._standing`), and the sync runs after the
  lists have been put on screen. Re-setting all of them on every tick ran on
  Android's main thread — where frames come from — while the ticked card was
  sliding, and the plugin rewrites its whole stored list per alarm; it was
  reported as the slide being "a little bit laggy". A timed task is announced at its own time, an
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
- **A newer release is offered in a banner, fetched in the app, and handed
  to Android's installer** (`services/updates.dart`, `_UpdateBanner`, the
  `caldo/updates` channel in `MainActivity`). On opening, the app asks the
  GitHub API for the latest release; if its tag is newer than the installed
  version, a banner sits above whichever screen is open. Tapping it downloads
  the APK built for the phone's processor into the app's cache, with
  progress, and opens the system installer on it through a `FileProvider`.
  The first time, Android wants Caldo allowed to install apps; the settings
  page for that is opened instead and the banner says to tap again. Closing
  the banner hides it until the next opening and no longer — an update put
  off is not one refused, and nothing else anywhere says one is waiting.
  **The repository is public so that this needs no account**: reading a
  private repo's releases takes a token, and a token inside an APK is one
  anyone holding the APK can take out. Versions are compared as dotted
  numbers, since as text 1.3.10 sorts before 1.3.9. Nothing checks until
  `main` calls `Updates.enable`, so the widget tests never go online.
  **An update leaves one Caldo in the recent apps.** The activity has no
  `taskAffinity=""`, though Flutter's template sets one: an empty affinity
  matches no task, so the installer's "Open" started a second Caldo beside
  the one the update was tapped in — "after update i have 2 same apps
  opened". The installer is started in a task of its own marked
  `FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS`, which otherwise outlived the install
  as a blank card. Started inside Caldo's task instead, it lost that task to
  the update and "Open" landed on the home screen. Checked end to end with
  two builds served from the host (the URL pointed at `10.0.2.2` and
  cleartext allowed, in the test builds only): one task after "Open".
  The version doing the updating decides this, so the first update away
  from a build without the fix still shows the old behaviour once.
  Measured end to end on the emulator: a build labelled 1.3.12 offered
  1.3.13, downloaded the universal APK with progress, asked once to be
  allowed to install, and came back as 1.3.13. It only offers what a GitHub
  release carries — `gh release create` with the three APKs is what makes an
  update appear on the phone.
- **A reminder's notification has Done, Snooze 15 min and Dismiss**
  (`Reminders.done`, `Reminders.snoozes`, `Reminders.dismissed`,
  `onReminderAction`). Dismiss was asked for by name ("smth like snooze
  dismiss"): it takes the reminder away and leaves the task as it was.
  Android draws three buttons at most, so the hour's snooze went from the
  notification to the full-screen page, which has all four.
- **A reminder takes the whole screen while the phone is locked**
  (`fullScreenIntent`, `ReminderScreen`, `Reminders.opened`,
  `MainActivity.overLock`), as an alarm does — asked for as "make the
  notification to full screen". On by default, a switch on Settings'
  Reminders page. Android decides when: with the phone in use it shows
  across the top as before, and a tap on it opens the same page. The page
  answers through `Background` exactly as the buttons do. The app is let
  over the lock screen only by a reminder's own intent (the plugin's
  `SELECT_NOTIFICATION`) and gives that back as the page goes, and in
  `onStop`; an attribute in the manifest would have had the whole app
  show on a locked phone. `USE_FULL_SCREEN_INTENT` is granted on install
  to an app not from the Play Store; the switch asks again where it has
  been taken away.
- **The buttons are answered off the app's screens** (`Background`). They are answered on the
  notification plugin's own isolate whether or not the app is open, so that
  isolate does the whole of a change itself (`Background._change`): writes
  the task, puts that one task's alarm right (`Reminders.reset`, never a full
  sync — a first sync cancels everything, which would take down every other
  notification on show), redraws the widget, and tells the app if it is
  running (an `IsolateNameServer` port, `Background.listen`), which reads its
  lists back. Done is the same tick the cards make (`Task.completed`), so a
  repeating task rolls on and its next alarm is set from the notification.
  A snooze is stored on the task (`snoozed_until`, schema v5) rather than
  only scheduled: the app's next sync would otherwise see an alarm for a
  time already past and cancel it. While set it is the one time the task is
  announced; a tick, a move to another day, or a new date or lead on the
  form ends it. The alarms are synced over the overdue run as well as the
  days to come, because a task snoozed late at night comes back after
  midnight, by which time it is overdue.
  **The plugin's `ActionBroadcastReceiver` is declared in the manifest by
  hand.** Without it the buttons are drawn and every tap on them is dropped
  without a word — that was the first build.
- **A task can be announced ahead of its time** (`Task.remindBefore`,
  `SettingsProvider.reminderLead`, `_ReminderField`, `Dates.lead`). Null
  follows Settings ("Timed tasks at the time" by default, which is what it
  always was); `Task.silent` is never. An all-day task takes only whole days
  of a lead — on its day or the day before, at the all-day hour — and none
  of the default, since "fifteen minutes before nine" on a day with no time
  in it means nothing. The form offers minutes for a timed task and "the day
  before" for an all-day one.
- **The home-screen widget is Schedule in small** (`TodayWidget.kt`,
  `TodayWidgetRuns.kt`): Overdue, Today, Tomorrow and each later day with
  something on it, the cards inked as the app inks them, a tick that works
  without opening the app, a row that opens its task's form, and a plus that
  opens a new one on today. It is always dark, like the app out of the box.
  It reads a copy of the agenda the app leaves in its own preferences
  (`TodayWidget.publish`, at the end of every read of the lists, beside the
  alarms) and sorts it into runs against today as it is when drawn — so a
  copy left overnight is right in the morning, and an alarm at midnight
  redraws it. **Nobody tells the widget to redraw**: `CaldoApplication`
  listens to the preferences, because three different engines write the
  copy (the app's, the plugin's for a reminder's buttons, and the widget's
  own) and only the app's has a channel of ours on it. Writing an unchanged
  copy redraws nothing, since Android only reports a value that differs.
  A tick is drawn at once in the copy, then done by Dart on one engine kept
  for the process (`Headless`, `widgetMain`) and fed one tap at a time: two
  engines would each redraw from their own read and the slower would win.
  A done task in the overdue run leaves the widget, as it leaves the app's
  backlog; the widget has no Undo, so that tick can only be taken back in
  the app.
  **It looks like Schedule, not like a calendar's widget**: the app's true
  black under the launcher's corners, "Schedule" and the quick-add plus
  across the top, each run headed as Schedule heads it (a Today/Tomorrow
  badge with the date beside it, Overdue a red badge), and cards as the app
  draws them — a quarter of the colour, the title over its time or "All
  day", an overdue time in red. Today is said even when it is empty
  ("Nothing left for today"), and the list fades out at its foot. A face of
  its own came first — a graphite panel, the day's number large, lighter
  single-line cards — and was "bad … make it like in app".
  **The tick animates** (asked for): from Android 12 each row's tick is a
  real `CheckBox`, which the launcher toggles and animates itself the
  moment it is tapped, from an `animated-selector` of ours, on the app
  card's own timings — the square's colour comes up over 240ms and the
  check is drawn through it from 60ms; off in 110ms. A widget cannot tint a
  drawable without tinting the white check
  too, so each of `ListStyle`'s eight swatches has its own drawable and its
  own row layout (`layout-v31/widget_task_<swatch>.xml`), written by
  `tool/make_widget_ticks.py`; the row takes the swatch nearest the task's
  colour. Change a swatch, run the script. The box never saves its state
  (`saveEnabled="false"`): every card's box has the one id, and once the
  cards stopped being a list, a launcher rebuilding itself — a night-mode
  switch is enough — restored one box's state into all of them, which
  fired every box's tick and ticked every open task (2.3.3 shipped with
  that). **A ticked card is seen going to the end of its day**, not
  teleported there: "it not moves to the bottom of list but teleports". So
  the widget is not a list. A collection rebinds a card where it now
  stands, and making each row a whole run did no better — the launcher
  swapped the run out whole behind a "Loading…" frame — and inside a row
  Android refuses a fill-in intent on a nested view ("available only from
  RemoteViewsFactory"), so every tap did nothing. Every heading and card
  is drawn into one frame instead (`layout/widget_page.xml`), each under
  its own key (`addStableView`), so the launcher redraws the frame it
  already has and keeps the views whose keys it knows. **It scrolls**
  ("make ability to scroll"): a widget can only scroll a list, so that
  frame is the one row of a `ListView` (`layout-v31/widget_runs.xml`),
  handed over inline (`RemoteCollectionItems`, one item, a stable id, one
  view type). The launcher draws the new row over the view it has rather
  than making another, and keeps the scroll where it was; the "Loading…"
  frame and the dead taps of the earlier attempt came with a
  `RemoteViewsService`, whose rows are applied off the main thread. Inside
  a list a card cannot carry an intent of its own, so each fills in which
  task and which tap (`setOnClickFillInIntent`, `fromFillInIntent` for the
  box) on the list's template. At most 60 cards are drawn
  (`TodayWidgetRuns.MOST`), every one sent to the launcher whole each time,
  and their measured heights are cached by text, width and text size.
  Before Android 12 there is no inline list and no stable keys: the runs
  are drawn afresh, stacked, and neither scroll nor move.
  Stacked, it still teleported: the launcher keeps only the keys that come
  in the order it already has and takes out the ones in between, so the
  ticked card was taken out and a new one faded in at the end. So nothing
  is stacked. The frame holds its views in the order of their keys, which
  a move never changes, each placed by a top margin from the heights of
  everything above it, and a move is only a margin changed. The heights are
  measured in the app's process by applying the view at the widget's width
  (`fit`), and a title is then held to the lines it took there, so a
  pixel's difference in the launcher's width cannot make a card taller
  than its room. The frame's height is set outright: left to wrap, it was
  held to the room above the widget's foot and measured a card sent past
  it to nothing. A resize redraws (`onAppWidgetOptionsChanged`), since the
  heights depend on the width.
  **And it plays a tick one to one with the app** ("animation in widget
  must be the same as in app"): the same steps (`TodayWidget.tick`, after
  `TaskProvider.toggleDone`), timings and curves (`SlideIntoPlace`,
  `TaskCard`). A launcher's layout animation could not be told either —
  it slid in 300ms on its own curve — so the widget does what
  `SlideIntoPlace` does: a view that has moved is drawn back where it was
  (`translationY`) and eased home by an animator of its own, in XML, which
  is started by flipping the view's enabled state, the one thing a widget
  may change on a view that an animator answers to (`stateListAnimator`,
  `animator/widget_*.xml`, `interpolator/widget_*.xml`). The tick: 490ms
  after the tap (`SETTLE`) the card is crossed out — the ink sinking from a
  quarter to a fourteenth (the ink's view alpha) and the title fading to
  the faint grey over 240ms on
  easeOut, with the strike coming in 70ms along, where the app's text style
  switches it (two titles, open and crossed out). A card that stays holds
  150ms (`HOLD`), then slides to the end of its day, 260ms on
  easeInOutCubic, the cards it passes rising into its place and showing
  through it, as the app's translucent card lets them. It had a black base
  under its ink, so it would not show what it slid over, and it blotted
  out each card it passed: "moves to the bottom badly". One that
  leaves — done out of the backlog, a repeating task rolling on, or any
  done task with done tasks hidden (`TodayWidgetRuns.leaving`) — fades over
  the first 138ms of the app's 280 (`interpolator/widget_leave.xml` is the
  first half of easeInOutCubic, split off) while what is after it closes
  up over the whole 280. Views are painted in the order of the run
  (`translationZ`), as Flutter paints a list. Taken back, a tick is
  un-crossed at once and the run read back 240ms later (`UNSETTLE`). The
  moves are worked out in the copy (`TodayWidget.last`) rather than waited
  for: Dart is asked to write the task only once the card has gone, and
  its copy, landing after, says what is already shown; a view whose place
  has not changed is not touched, so a slide under way is left to finish.
  Dart used to be called at the tap, and a warm engine's copy rebuilt the
  row before its square had filled — "too fast". The box's own state is
  what Dart writes (`Background.toggle(done:)`), so two quick taps end
  where the box ended. Measured off a recording: the square fills over
  the first 240ms, the ink starts sinking ~530ms after the tap (the
  broadcast's latency on top of 490) and is down 190ms later, and the
  slide starts 150ms after that.
  Before Android 12 the tick is the old image, changed on the next redraw.

- **Done is a log of ticks, not a list of done tasks** (`completions`,
  schema v6, `Completion`, `DoneScreen`). Every tick writes a row with the
  task's title and colour as they were (`AppDatabase.complete`), and taking
  a tick back or undoing it removes the latest row for that task
  (`AppDatabase.untick`) — every tick path goes through those two, the
  notification's and the widget's included. Read from the tasks instead, a
  repeating task would count once however often it was done (it rolls on
  and is never "done"), and clearing completed tasks would empty the log.
  The v6 migration starts the log from each task's `completed_at`, which is
  as much history as there was. The screen is three figures — today, this
  week (from the day Settings starts it on), days in a row (counted up to
  yesterday while today has nothing yet) — and the last seven days as
  bars, all neutral, over the ticks day by day, latest first. Its rows are
  not crossed out: everything there is done. It reads the log only while it
  is the screen on show (`shown`), since the shell builds all four at once.

- **The board is a screen of its own, three columns: Not started, In
  progress, Done** (`BoardScreen`, `Stage`, `Task.startedAt`, schema v7,
  `TaskProvider.moveToStage`). Asked for as "work in progress, done and not
  started … separate mode (not schedule and calendar) … like 3 cols". Only
  In progress is new and stored: `started_at`, the moment the task was put
  there, which orders that column latest first; the other two are whether
  the task is done. A card is carried across by a long press, as cards are
  everywhere else, and the column under it lightens; it is drawn in its new
  column at once and written after (`Task.toStage`, shared with the
  provider), since waiting for the write put it back in the column it came
  from for the length of the read. Into Done is a tick like any other —
  logged, and a repeating task rolls on, which lands it in Not started,
  since its next round has not been begun. Out of Done is the tick taken
  back. Any tick, from anywhere, ends In progress. Not started is by due
  date, undated last; Done latest first, every done task there is (Settings
  clears them). It follows the group chips as the other two screens do,
  reads the tasks only while on show, as Done does, and has a plus in its
  header for the full form rather than a field, since a board's new task
  has no day to be filed on. Each column scrolls on its own and fades at
  its foot.
  **It is drawn as a Jira board** ("its must looks like more like jira"):
  grey lanes on the black, each headed in small capitals with its count
  ("IN PROGRESS 1"); flat neutral cards a step lighter than the lane, 6pt
  corners, the title across the top and along the foot a square in the
  task's colour where Jira puts the issue type (ticked once done), the
  date, and the marks — repeat, checklist count, priority as Jira's
  chevrons. A carried card is lifted and shadowed but held square — it tilted,
  as Jira's do, and was "crooked"; the lane under it is ringed.
  An empty lane is just empty. Two looks came before it: grey panels with
  inked cards and done ones crossed out ("it looks bad"), then bare
  columns on the black with inked cards — simpler, but not Jira. The cards
  are not inked here, unlike everywhere else: tinted cards in grey lanes
  were a wash of colour, and the square says the colour.
  **A lane is a page, most of the screen wide, with its neighbours
  showing at the sides** (`_Board.laneFraction`), matched to a Jira
  board's screenshot the user supplied: "make the tasks bigger". Three
  lanes at once left each a third of a phone and a title a word a line.
  **The lanes snap to three places** (`_LaneSnap`, a row in a
  `SingleChildScrollView`): Not started against the left edge, Done
  against the right, In progress centred with a strip of each neighbour.
  A `PageView` pages a lane's width at a time, so In progress sat against
  the left edge too and Not started was nowhere on screen — "when im on
  WIP i see the part of DONE but dont see not started".
  A card is laid out as Jira's is: the title; then the group as a lozenge
  in its colour (Jira's epic label) and the due date on a grey one, red
  once gone by; then the type square and the marks at the far end. Jira's
  issue key beside the square — the group's first letters and the task's
  id, "PER-12", struck through once done — is hidden for now
  (`BoardCard.showKey`): nothing else knows a task by it, and it was asked
  what it meant. The lane's name
  stands in line with the titles.
  A card comes up to be carried after 300ms held (`_Board.pickUp`) rather
  than the platform's 500. A move button on each card, opening the lanes
  in a menu, was tried for "make easier to move task to another col" and
  taken back out: what was wanted was the next lane on show sooner.
  **A card is moved by carrying it onto a lane**, the one on show or the
  strip of a neighbour. **Taken towards either side, the card turns the
  board at once** (`_watchEdges`), and on every 900ms while it stays. It
  used to wait 500ms first, and holding still at the edge to reach the
  next lane was disliked by name; and the side was the last 28 points of
  the screen, where it is now the outer 18% (`_Board.edge`), about as far
  in as the strip of the next lane — "make it easier by earlier show the
  second col". Every lane stays built (the row, not a list): a lane
  turned off the screen was thrown away with the card being carried out
  of it, and its drag's callbacks with it, so the board could not turn
  back and never heard the card let go. **The carried card stays where it
  was taken hold of, at its size** (`_Lifted`). Two things came and went
  around it, each asked back out: a bar of the three lanes rising along
  the foot to drop on ("remove the bottom not started in progress and
  done when im moving the task"), with the card see-through over it; and
  the card riding above the finger, shrunk to a tile and then at its size
  ("now task is taking above my finger").
  **A task in progress says so everywhere a card is drawn**
  (`InProgressBadge`, in `TaskCard`): Jira's status lozenge, in Jira's
  blue for it, ahead of the time on a two-line card and before the time on
  a one-line one. Asked for as seeing "that the task WIP in schedule and
  calendar"; without it, starting a task changed nothing off the board.

- **Events from the phone's own calendars sit beside the tasks the way
  holidays do** (`EventsProvider`, `DeviceCalendars`, `EventCard`, the
  `caldo/calendars` channel). Off until Settings is asked ("Show events from
  your calendars"), which asks Android for `READ_CALENDAR`; nothing is ever
  written. Each of the phone's calendars can be left out, stored as the ones
  left out so a calendar added later shows up unasked — a holidays calendar
  is the one most worth leaving out, since Caldo marks those itself. An
  event is marked on the grid after the holidays and before the tasks,
  written out in an opened day, and carded in the day panel, the day card
  and Schedule, where a day with only an event on it gets a run of its own.
  It cannot be ticked or dragged; a tap opens it in the calendar app. What
  is read is the agenda's days plus the month on show (`cover`), again on
  every return to the app, since the events live in another one. All-day
  events are stored at midnight UTC, so their dates are read in UTC and set
  at local midnight — read in the local zone, west of Greenwich, they land
  a day early (`events_test.dart` passes under `TZ=America/Los_Angeles`).
  Screens read the provider as nullable, so a test that pumps a screen
  without it still draws. The home-screen widget does not show events.

- **Caldo speaks the language of every country it keeps holidays for**
  (`S`, `l10n/strings.dart`, `l10n/words_*.dart`): English, Russian,
  Ukrainian, Belarusian, Kazakh, German, French, Spanish, Italian, Dutch,
  Polish and Turkish — the phone's by default, any of them by choice in
  Settings, each named in itself in the list. The words are a table per
  language, not generated ARB files and not a class each: twelve tables of
  a couple of hundred strings are data. A key missing from a table falls
  back to English, and `l10n_test.dart` fails if any table lacks a key or
  has different `{blanks}` in it than English does. Counted words are lists
  of forms picked by a rule per family — one/other (English, German,
  Spanish, Italian, Dutch), French (0 counts as 1), East Slavic (1 день,
  2 дня, 5 дней), Polish (only 1 itself is singular) and none at all
  (Turkish, Kazakh: "3 gün"). Read with `S.of(context)` on a screen and
  `S.current` where there is none — a notification, the widget's copy, the
  background isolates (`SettingsProvider.prime` sets it there).
  Dates follow `intl`'s locale, which `S.use` keeps in step. English keeps
  the patterns it was drawn with ("Sat, 4 Oct", "Oct"); every other
  language takes `intl`'s skeletons, which know its order and dots ("Mo.,
  2. Nov."), writes the month header in full (short forms mostly end in a
  full stop), and gets a capital at the start of a line, since many write
  weekdays and months in lower case. The widget is the same in Kotlin
  (`getBestDateTimePattern`, `values-xx/strings.xml`). Changing the language
  re-sets the alarms, whose text and buttons are in it, and rewrites the
  widget's copy, which carries the language because the launcher draws the
  widget in the phone's. `l10n_screens_test.dart` draws Schedule, the
  calendar, Settings and the form in every language on a small phone;
  it found Schedule's day heading overflowing, and the date there now
  fades rather than pushing. The translations were written without a native
  speaker's review.

- **The icon is Dicty's sibling**: the same graphite rounded square and the
  same two overlapping tiles, here a white calendar page with its rings and
  a grid of days, and over its corner the violet tile with a white tick — a
  done task's filled square. One accent tile and nothing else in colour. It
  is adaptive with the same 16% inset as Dicty's, so the two stand at one
  size on a home screen, and it carries a monochrome layer for Android 13's
  themed icons, with the tick and the seam cut out. On the emulator's dock
  it wears a lavender ring: that is the launcher marking a suggested app in
  that slot, not part of the icon — the app drawer shows it without.
- **The window asks Android for the fastest display mode** (`MainActivity`).
  Flutter's stock activity never does, so a 120Hz phone renders the app at 60.
  The ask is for the fastest mode at the resolution already in use — the
  supported-mode list mixes resolutions, and the fastest of all of them can
  drop the screen to a coarser one.

## Tests

`flutter test` — 181 tests, all passing. Keep them that way; several real bugs
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

Four things in `android/` exist only for the reminders, and all four are
load-bearing: **desugaring** in `app/build.gradle.kts` (the plugin schedules
through `java.time`, and the build fails without it), the **action
receiver** in the manifest (a reminder's buttons do nothing without it),
the **two scheduled receivers and three permissions** in the manifest (a
scheduled notification is held by the system, which forgets them on a
reboot and on an update), and
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

**Releases are made when the user asks for one, and not otherwise.** Commit
each change as it is made, but do not bump the version, build, or publish
unprompted — since 1.3.14 the in-app updater offers whatever the latest GitHub
release is, so publishing one puts it on the user's phone, and that is theirs to
decide. When a release is asked for, it means both: the three APKs staged in
`release/` (gitignored; `Caldo-arm64.apk`, `Caldo-armv7.apk`,
`Caldo-universal.apk`) and a GitHub release carrying the same three,
`gh release create vX.Y.Z release/*.apk`, built from the latest commit.

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

**The emulator always runs the latest commit.** After every change, build a
release APK (`flutter build apk --release` — no version bump, no GitHub
release) and `adb install -r` it, starting the emulator first if it is down.
Releases only go out when asked for, so the emulator is where a change can be
tried in between, and a stale one means judging a fix that is not there.

Changes here are judged by eye: take the screenshot and check it before saying
it works. `adb shell input tap/swipe/text` drives it; the screen is 1080x1920
at **dpr 2.625** (411x731 logical) — `adb shell wm density` says 420, and the
note here said dpr 3 for months, which is what kept the keyboard arithmetic
from reconciling for a whole morning. `input text` cannot send Cyrillic, so
seed Russian titles some other way or use Latin ones of the same length.

**A long press cannot be done with `input swipe`.** It interpolates from the
first millisecond, so the press has moved past the touch slop long before the
half-second a long press needs and the gesture is cancelled. Nothing that
starts with a long press — picking a card up to drag it — can be driven that
way. Use the event stream instead, where the latency between `adb` calls is
itself the hold:

```sh
adb shell input motionevent DOWN 540 880
sleep 1
for y in 840 760 680 600; do adb shell input motionevent MOVE 540 $y; done
adb shell input motionevent UP 540 600
```

Screenshot between the MOVEs to catch a gesture in flight — that is how the
carried card was measured against the run it was supposed to stay inside.

Three things that look like bugs and are not:

- An ANR under load is usually host starvation (a Gradle daemon plus the
  emulator on 13GB), not a hang in the app. Check whether unrelated processes
  ANR'd in the same second before hunting for a layout loop.
- **A loaded host makes the emulator drop app frames, and a dropped frame
  looks exactly like a bar that is not attached.** Judge anything that rides
  the keyboard on a release build, and run the committed build as a control
  before concluding that a change caused a lag: measured on a quiet machine
  the bar held within 1-2px of the keys on every frame, and after a morning
  of Gradle builds the *same commit* trailed them by up to 67px. What
  distinguishes a real fault from this one is that frame lag scales with how
  fast the keyboard is moving and vanishes when it stops, while a number
  that means the wrong thing is off by the same distance at every speed.
- **The emulator's keyboard does slide, and finely enough to follow** —
  contrary to what was written here before, which was taken from a single
  lump the inset once arrived in. Measured off `screenrecord` on
  `pixel_api34`: the keys rise over sixteen frames, about 270ms, in steps the
  quick-add bar matches one for one, and it is reported in small enough
  pieces that the bar is glued to them rather than gliding after them. The
  bar is behind the keys for the first half of that, so it only becomes
  measurable once it clears the keyboard's top edge. The way down is a single
  lump here, as it is on real devices.
- **A debug build draws at about half the rate on this emulator, which
  makes anything glued to the keyboard look broken.** Measured with the
  quick-add bar's box painted red, so its edge could be read against the
  keys: in a debug build the bar holds each position for two display frames
  while the IME moves on every one, so half the frames of a slide show a gap
  of up to 68px under the bar or a 20px overlap. The same code in a release
  build is within 1-2px of the keyboard's top edge on **every** frame of the
  slide, first to last. Judge anything that rides the keyboard on a release
  build, and if a mismatch is reported, measure that before touching the
  code — three rounds went into the lift when the lift was not what was
  wrong. The emulator's window on the host can resample again on top of
  that; a phone is the only place to settle how it feels.
- **The first opening of the month after a cold start draws slowly on the
  emulator** — about 16ms of raster a frame, where every later opening takes
  2ms — in most launches but not all, and not because of anything the grid
  draws. Measured with frame timings from a release build: the slow frames
  begin a few frames into the opening, before any task title is on the
  screen, and four fixes each looked right on one run and failed on the
  next few — rows placed on whole pixels, a startup warm-up drawing faded
  text, titles faded through their colours instead of a layer, and the
  titles not faded at all. It is the emulator's GL translation warming up
  (this AVD runs Impeller on OpenGL ES; phones run it on Vulkan). Nothing
  was kept. If it is ever seen on a phone, measure there first; take
  several cold starts per build, since one run proves nothing either way.
- **`screenrecord` drops frames**, and more of them the more the host is
  doing. Frame-by-frame measurements off a recording show the *shape* of a
  movement — whether it builds and decays, or jumps and catches — which is
  enough to tell a spring from a teleport. They do not show whether it is
  smooth. Say which of the two was checked.

## Conventions

- Comments explain **why**, at roughly Dicty's density. No narrating what the
  line already says.
- Commit messages are prose: what changed and the reason it needed changing.
  End with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- `flutter analyze` must be clean before a commit.

## Known gaps

- In week view, swiping sideways still pages by **month**, not by week.
- Holiday names are in each country's own language, except the English-
  speaking ones and Canada, which is English only.
- The debug keyboard numbers (long press on the Settings title) are English
  in either language.
- Signing uses the debug keys (Flutter's default), so installs warn about an
  unknown developer.

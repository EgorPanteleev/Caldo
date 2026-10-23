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
The app is local-only except for one thing: asking GitHub whether a newer
release is out, and fetching it — see the decision below.

## Layout

```
lib/
  data/holidays.dart     public-holiday rules, computed on device (no network)
  db/database.dart       schema v3: lists, tasks (+ migrations)
  models/                task.dart (Repeat, Priority), task_list.dart
                         (ListStyle, colorOfTask)
  providers/             task_provider.dart, settings_provider.dart
  services/reminders.dart  the notification each dated task gets
  services/updates.dart  the newer-release check, download and install
  screens/               home (shell + menu), tasks (Schedule), calendar,
                         search,
                         lists, task_list, task_edit, list_edit, settings
  theme/app_theme.dart   AppPalette + AccentColors ThemeExtensions, AppColors
  utils/dates.dart       every date/time string the UI shows
  widgets/               month_grid, task_card (+ HolidayCard), task_row,
                         colour_selector,
                         date_time_pickers, day_sheet, menu_button,
                         quick_add_bar, screen_header, selection_bar,
                         theme_switcher, gradient_icon_button,
                         slide_into_place, tick_off (+ AsShown), carry
```

The launcher icon is drawn in SVG under `assets/icon/src` and turned into
Android's sizes by `tool/make_icon.sh` (needs `rsvg-convert`); the PNGs it
writes are checked in.

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
  The spring's stiffness is 200, settling in about 0.35s; it was 340 (about
  0.27s) until asked to be "a little bit slower".
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
- **Which of Schedule and Calendar the app opens on is a setting**
  (`StartScreen`, read in `main` before the first frame). It cannot wait for
  `SettingsProvider.load`: that ends by asking Android about notifications,
  which on a first run is a dialog the user has to answer, and waiting for it
  would hold the app on a blank screen. So the one key is read on its own
  first, and the shell takes it as it is built and never again — a screen
  that jumped out from under the setting being changed would be startling,
  and the setting is about the next launch.
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
- **A tick off offers Undo for four seconds** (`tickOff`, a SnackBar above
  the add field). Undo writes back the task as it was before the tap
  (`TaskProvider.restore`) rather than ticking it again, because a repeating
  task has already rolled on to its next date and a second tick would only
  roll it further. The bar needs `persist: false`: a SnackBar with an action
  otherwise stays until it is dismissed, which on the emulator meant it never
  went. Every card's tick goes through `tickOff`; untick is already an undo
  and gets no bar.
  The bar draws itself (`_UndoBar`): the add field's grey, lifted off the
  cards with a shadow, a plain grey tick beside the task's name, "↶ Undo"
  (the arrow drawn, `_UndoArrow`, in the tick's round-ended stroke — the
  stock icon was a filled hook of another weight), and a faint line along
  its foot that runs down over the four seconds. Undo is the only thing on
  it in the accent: a filled accent tick and an accent countdown beside it
  made three purple things on one small bar — "too many accent colours".
  The stock snack bar before that was a flat slab that read as one more
  card on the list — "make undo look better".
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
  Done tasks are ordered among themselves like any others — by creation, not
  by when they were ticked — so a newly ticked task is below every open one
  but not necessarily the very last.
- **A long press picks a card up; it used to open the editor**, which a tap
  already does, so nothing was lost. There are no drag handles: the card is
  the handle, and a grip beside every row would be a column of furniture down
  a list whose whole job is to be read.
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
  A short day's list cannot scroll at all, so every drag on it arrives as
  overscroll; a long one arrives only once it has run out of list.
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
  Measured end to end on the emulator: a build labelled 1.3.12 offered
  1.3.13, downloaded the universal APK with progress, asked once to be
  allowed to install, and came back as 1.3.13. It only offers what a GitHub
  release carries — `gh release create` with the three APKs is what makes an
  update appear on the phone.
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

`flutter test` — 122 tests, all passing. Keep them that way; several real bugs
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
- Holiday names are in each country's own language where it was natural
  (DE/FR/ES/IT/PL/NL/TR) and English elsewhere; nothing is localised otherwise.
- Signing uses the debug keys (Flutter's default), so installs warn about an
  unknown developer.

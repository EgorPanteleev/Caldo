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
  db/database.dart       schema v3: lists, tasks (+ migrations)
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
- **Ticking a task off is drawn, and the run waits for it** (`CheckMark`,
  `TaskProvider.settle`). The mark used to appear whole between two frames
  while the card left for the done end of the run in the same instant, so
  the gesture had no moment at all — "too fast", and nothing to see. Now the
  square fills, the stroke runs through it a quarter of the way in, and the
  card's ink sinks to its done shade, all over 240ms; the provider writes the
  database at once but holds the re-read for the same stretch, so the card
  under the finger stands still while its tick is being drawn and the run
  rearranges itself afterwards. Coming off, the mark goes in half the time
  and without the drawing: undoing is a correction, not a flourish. A task
  that rolls forward on a repeat skips all of this — it is leaving the run
  whatever happens.
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
  own ground once the month is opened out, the day panel's grey while the
  day's tasks are still on screen.
- **Whatever is above the add field fades into the ground it sits on**
  (`GroundFade`, 48 points, on both the calendar and Schedule). Sliced off
  square by the field, the last card in a full day ended in a straight cut
  across the middle of a word. The ramp is a smoothstep, not a straight one: a
  straight ramp has a visible edge at each end, where it starts and where it
  finishes, and both read as lines. It is one widget rather than two copies
  because the two screens have to look the same doing it — which is how it
  came to be asked for on Schedule in the first place.
- **The fade goes as the month opens out** (`GroundFade.strength`, driven by
  the calendar's expansion). It is for a list that runs under the field, and
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
- **`viewInsets.bottom` leaves the bar ten points low for the length of a
  slide on an edge-to-edge window, and `MainActivity` is what puts it back**
  (`KeyboardGap`). Flutter's number is how far the keys reach past the
  system bars. Below Android 15 the window stops above the navigation bar,
  the strip is not ours, and the number is the whole story — which is why
  the emulator was always right and why this correction is zero there.
  Drawn edge to edge the strip *is* inside the window, and the moment the
  keys cover it Android drops it from `padding.bottom` while the animated
  inset still leaves it out: for the length of the slide the app is told
  about ten points less than the keyboard covers, and the final inset puts
  it back in one step at the end. That step is the jump at the end of the
  slide, reported from the first message of this whole thread.
  Measured off a phone recording: through the slide the field sat 2-3px off
  the keys instead of its own 18px of padding, and then rose 17px *after*
  the keyboard had stopped — the deficit was a constant 15-16px while the
  keyboard's speed varied by a factor of 260 between frames, which is what
  rules out frame lag and points at the number changing meaning. So the
  activity reports what is missing and when: the system bar strip that lies
  inside the window (`navigationBars()` less whatever lies below the content
  view, measured while the keyboard is down and the view is at full height),
  while `WindowInsetsAnimation` says a slide is running, and nothing at all
  once it has settled.
- **The inset is read in `KeyboardLift` and `KeyboardRoom` and nowhere
  else.** It changes on every frame of a slide and whoever reads it rebuilds
  that often, so the two widgets that move with it are the two that read it,
  and the screens around them are left alone.
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
- **A day's tasks can be dragged into an order of their own** (`sort_order`,
  schema v3, null until a day is actually dragged). Null rather than zero on
  purpose: a column of zeros would claim every task had been placed by hand,
  and a day nobody has touched should keep the order it has always had. A task
  that arrives in a day somebody has already arranged goes after the arranged
  ones. The hand order sits under "open before done" rather than over it —
  ticking a task off is about whether it is still to be done, not about where
  in the day it sits.
- **A long press picks a card up; it used to open the editor**, which a tap
  already does, so nothing was lost. There are no drag handles: the card is
  the handle, and a grip beside every row would be a column of furniture down
  a list whose whole job is to be read.
- **A task only ever moves within the run it is in.** Let go over another run
  it lands at the near end of its own, because dragging it from one day to
  another would be a change of date wearing the clothes of a change of order.
  Every run can be dragged, the overdue backlog included — it was left out at
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
- **A card being carried is held between the ends of its own run**
  (`DragWithin`, `_KeepInside`). A reorderable list puts the card into an
  `Overlay`, and the nearest one is the app's — the whole screen — so it could
  be carried up over the calendar's grid or above Schedule's header, somewhere
  it could never be dropped. Each list gets an overlay of its own, which gives
  the card a box; clipping it to that box was worse than letting it wander,
  because it vanished a sliver at a time into the top of the screen. It is
  penned between the rows on either side of its run instead, which is where it
  would land anyway — so it stops under the Overdue badge rather than over it.
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

`flutter test` — 91 tests, all passing. Keep them that way; several real bugs
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
`Caldo-universal.apk`, refreshed after each change. **A release means both**:
the three files staged there and a GitHub release carrying the same three,
`gh release create vX.Y.Z release/*.apk`. There was a stretch of local-only
builds in the middle of this; that is over.

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

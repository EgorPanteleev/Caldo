# Caldo — working notes

A calendar + to-do app for Android, and for Linux (a wide window gets a
desktop layout; a narrow one is the phone's app). Flutter, local-first
storage. Private repo `github.com/EgorPanteleev/Caldo`. Modelled on its
sibling **Dicty** (`/home/igor/dev/src/Dicty`) — same stack and theme; look
there first for style and structure questions.

The full history behind each decision below (what was tried, measured and
rejected) is in the git history of this file, before the commit that
shortened it. Look there before reopening one.

## Stack

Flutter 3.38.6 / Dart 3.10.7. `provider`, `sqflite` (`sqflite_common_ffi` on
Linux and in tests), `shared_preferences`, `intl`,
`flutter_local_notifications` + `timezone` + `flutter_timezone`. Platform
font. `path_provider_linux`, `file_selector_linux` on the desktop. The
home-screen widget is native (`TodayWidget.kt`, plain `RemoteViews`). The
network is used only for the GitHub release check/download and Supabase sync
(Supabase Cloud for now).

## Layout

```
lib/
  data/holidays.dart       public holidays, computed on device
  l10n/                    strings.dart (S) + words_*.dart, a table per language
  db/database.dart         schema v13 (+ migrations); db/sync_store.dart
  models/                  task (Repeat, Priority), task_list (ListStyle,
                           colorOfTask), completion, secret, special_day
  providers/               task, settings, events, vault
  services/                reminders, background (isolates), today_widget,
                           device_calendars, updates, backup, sync, account,
                           attachments, file_sync, desktop, sealing,
                           vault_device, recording
  screens/                 home (shell), tasks (Schedule), calendar, board,
                           done, search, task_edit, settings, desk_shell,
                           vault
  theme/app_theme.dart     AppPalette + AccentColors, AppColors
  utils/                   dates.dart (every date/time string), platform.dart
  widgets/                 month_grid, task_card, day_sheet, day_hours,
                           quick_add_bar, keys_carry, tick_off, selection,
                           put_off, carry, desk, … (see the directory)
  mcp/                     the MCP server's: book, remote, tools, protocol
bin/caldo_mcp.dart         the MCP server (plain Dart); tool/mcp/install.sh
```

Android: `MainActivity.kt` (refresh rate, keyboard, updates, widget
launches, calendars, backups), `PhoneEvents.kt`, `Attachments.kt`,
`TodayWidget.kt` + `TodayWidgetRuns.kt`, `CaldoApplication.kt`,
`LauncherIcon.kt`, `SelfUpdate.kt`, `ReminderCover.kt`, `DailySync.kt`,
`Vault.kt`, `ScreenRecord.kt`, `KeysCarry.kt`.
Linux: `linux/` is Flutter's GTK runner plus the window
(`runner/my_application.cc`), `sqlite_shim.cc`, icon + desktop entry,
`install.sh`. No channels on Linux.
Icon: SVG in `assets/icon/src`, rendered by `tool/make_icon.sh`
(`rsvg-convert`); PNGs checked in.

Six destinations: **Schedule, Calendar, Board, Done, Vault, Settings**, in
four tabs: **Tasks** (Schedule, Board, Done), Calendar, Vault, Settings. Any
of the first five can be hidden; Settings can't.

**Lists are "groups"; there are no list screens.** Groups surface through a
chip row and a sheet only. `openList`, `GradientIconButton`, `SelectionBar`
stay deleted. Tests find a task by name with `taskNamed`
(`test/support/test_db.dart`).

## Decisions worth keeping

All asked for explicitly or fixed after being seen on a device. Reverting
them will be noticed.

### Calendar grid

- **Three states on one `AnimationController` in `[-1, 1]`**: -1 week, 0
  compact month, +1 opened month with titles. Drag anywhere on the grid, the
  strip under it, or the day bar. A tap on the strip steps one state and
  turns around at either end.
- **A drag a fifth of the way commits; one drag moves one state at most**
  (`_dragBy` clamps). **The snap is a glide, not a spring** (`_Glide`): a
  cubic starting at the finger's speed, 460ms for a full step (half for a
  short remainder), no overshoot. A flick sets the start speed (capped at 3×
  average) but not the duration. Springs were tried and crept/overshot; to
  slow it, lengthen `_snap`.
- **Day numbers sit at a fixed offset from the cell top** in every state
  (so the first week never moves). Centred-then-sliding was built and asked
  back.
- **Tasks are lines under the number, not dots**; holidays first, in green.
- **Opened day chips**: title takes up to two lines, measured with
  `TextPainter` (round the height up). Overflowing the width fades; overflowing
  the height is cut at the line (`didExceedMaxLines`) — a fade there slices the
  last line in half. Chips are inked, not painted (`dayChipColour`, colour
  mixed into the ground, ordinary text colour). Keep them tight
  (`_inset`/`_gap`); corners 3; `+N more` left-aligned.
- **Collapsing to the week slides rows past a shrinking window**; rows keep
  their month height, each is carried from its month place to its week
  place, and the week row is a fifth taller (`MonthLayout.weekScale`).
  Shrinking rows, and holding the week still, were both rejected.
- **Week rules fade in only in the last quarter of opening** (`weekRuleAlpha`).
- **The month is laid out once and only moved while changing state**
  (`MonthGrid.animation`, `_RenderRows`): rows laid out at opened height,
  clipped, each a repaint boundary; outline and week rules drawn by the
  render object. Cells keep 1.4pt inset. The month pager is outside the
  `AnimatedBuilder`.
- **Keep the drag cheap**: `Holidays.around` and chip heights are cached; the
  day pager is the `AnimatedBuilder`'s `child`. Look there first if it feels
  rough.
- **Today is a tight, near-square badge** in the colour the number would
  have (red Sunday, light otherwise; black/ground text). Selected day is a
  thin neutral outline. No accent on either. Badge text is centred on digits
  (`Alignment(0, 0.2)`, `height: 1`).
- **All day numbers semibold**, tightened (`letterSpacing`,
  `proportionalFigures`). **Only Sundays are red**; holidays don't recolour.
- **Header**: controls row on top (Search, Today), month name alone
  below, `Sep` centred, year only if not current. No chevrons on the phone.
  Today's button shows today's date on a page.
- **Grid on the ground, day panel a raised grey** (`calendar` vs `panel`); the day bar takes the
  panel's grey.

### Calendar pagers and day panel

- **Days below the grid are a pager, one page per day.** Within a grid's span
  (`_passThrough`, 42) a pick slides through the days between; further away it
  is brought in as the next page (`_dayAnchor`, `_heldPage`). Pagers ignore
  pages an animation passes through (`_driving`); `_onMonthPageChanged` still
  owes the header a `setState`.
- **In the week, a sideways swipe turns a week** (`_weekController`,
  `_weekShown`): a second pager over the month's, keeps the weekday, cuts
  (doesn't slide) the day panel. The month pager takes over off the week and
  during a carry.
- **Picking a day in the opened month opens a bottom sheet** (`day_sheet`),
  sized to the day up to 56%, dense one-line cards (`TaskCard.dense`), no own
  overlay (`DragWithin.overlay`), lifted by `KeyboardGap`. Drag down to close.
- **Hours view** (`DayHours`, `SettingsProvider.dayAsHours`, `_ViewSwitch` in
  the day bar): untimed items across the top, then a midnight-to-midnight
  timeline, blocks side by side when overlapping, red now-line. Re-placed when
  contents change until the user scrolls. Day sheet stays a list.
- **Day bar names its day and holds the list/hours switch only.**
- **The day's list scrolls only in the week state** (`_HeldScrollPhysics`,
  `_listHeld`); otherwise every drag drives the grid. A drag that scrolled the
  list never opens the month (`_listScrolled`). An empty day has no list; the
  whole panel takes the drag (`EmptyState.scrolls`).

### Tasks and cards

- **Timed tasks may have an end** (`Task.duration`, minutes, schema v8),
  same day only, written "15:00 – 16:30".
- **Cards are frosted glass** (asked for from mock-ups, 2026-11-19): 30%
  of the task's colour (`TaskCard.ink`), translucent over the ground they
  stand on, a 1.5pt rim of the colour at 56% (the tick's square outlined the same), and a frost of fine grain,
  one sharp pixel per screen pixel, about 3.4% white varying 1.5%
  (`CardPane`, `assets/grain.png` from `tool/make_grain.py`,
  unfiltered). The pane is its own `Decoration`: the grain is an
  `ImageShader` filling the card's shape, one draw — as a `BoxDecoration`
  image it clipped and tiled every card each frame, and lerping it
  (tick, pick) blended through a `saveLayer` per card. 22% under an even 8% veil (the mock-up's "soft grain" as
  Chrome drew it) read as greyish; ink, grain and frost were picked from
  pictures. A coarser grain
  (2.11.37), a blurred one and a soft, bleeding rim (2.11.38) read as
  noise. Deeper ink alone read as a muddy slab. Done keeps 9.45% ink
  and a faint rim (18%), no frost. Holidays and phone events wear the same pane
  (`TaskCard.paneOf`). Ink, rim and frost have Debug sliders. Timed tasks
  use the same card (no separate row form).
- **A task may carry its own colour** (`Task.styleId`), else its group's.
  Always resolve through `colorOfTask`. Moving group on the form resets to the
  group colour.
- **Palette: sixteen presets plus made colours** (`ListStyle.presets`,
  `ColourSelector`, `showCustomColourSheet`; hue strip + five tones, stored as
  `#RRGGBB` in `style_id`; six recent in `customColours`). The first eight ids
  are the old ones; `ListStyle.freeFor` offers those first.
- **Ticking off** (`CheckMark`, `TaskProvider.settle/linger/leave/hold`,
  `TaskCard.ticking/leaving`): tick drawn at once (240ms), crossed out 250ms
  later, then a card that leaves its run (done overdue, rolling repeat, hidden
  completed) fades over 280ms; otherwise it holds 150ms and slides to the end
  of its day (`SlideIntoPlace`, 260ms). Schedule and Calendar must behave
  identically (grouping is made once per load, not in a getter).
- **A tick doesn't rebuild screens; only the read-back does**
  (`TaskProvider.ticked`, `shown`, `AsShown`). Settings and the tab bar
  `select` single values.
- **`SlideIntoPlace` slides by (screen, task id)**, noting positions in
  content space on `TaskProvider.rearranging`, and finds the move in paint
  (`_RenderSlide`) so the first frame doesn't jump.
- **Undo for four seconds** (`tickOff`, `_UndoBar`, `UndoScope`, `UndoSlot`,
  `TaskProvider.restore` — writes the old task back, never re-ticks). Takes the
  add row's place at its size; the field stays in the tree beneath. Countdown
  is a gradient across the whole bar (`_Countdown`); holding pauses it. Can be
  brushed off sideways/down (`UndoSlot._away` reveals the row). Only Undo is
  in the accent (`_UndoButton`, `_UndoArrow`); no rings, lines or chips.
- **Done tasks sort after open ones, in tick order** (`completed_at`), hand
  order beneath that. **High priority leads an unarranged day.** **Hand
  placement (`sort_order`, null until dragged) is read before the date** in
  the database's `_order`.
- **A repeating task ticked late rolls on to today or later** (`Task._nextRound`).
- **Repeat is a rule** (`Repeat`, `RepeatUnit`, `showRepeatSheet`): every N
  units, weekdays, month day or last day, end by date or count (`left`,
  `rolled`; `rollsOn` false on the last round). Old five rules keep their
  stored names; richer ones are an RRULE-like string. Pieces joined by " · ".
- **Checklist** (`Subtask`, JSON in the task row, schema v4) so Undo and
  roll-on carry it. Card shows a "☑ 2/5" pill that opens steps under the
  title. **Open steps hold back the card's first tick** (`_WithChecklist._tick`
  shakes and opens them); other tick paths don't. Search filters the JSON in
  Dart.
- **Attachments** (`Attachment`, JSON column, schema v10, `Attachments`,
  `Attachments.kt`, `AttachmentsField`): Photo (photo picker, images only),
  Camera, File; copied into `files/attachments/<uuid>/<name>`; >100MB refused;
  opened through a `FileProvider` for that directory only. Nothing deletes a
  copy when a task drops it; `Attachments.sweep` on start removes unreferenced
  copies older than an hour. No camera permission declared, on purpose.
- **Holidays are not tasks**: computed, read-only, country from locale or
  Settings.
- **Special days** (asked for: birthdays and other yearly days;
  `SpecialDay`, schema v13 `special_days`, synced and backed up like the
  rest; a backup from before leaves them be): a month, a day, a year only
  if known (then "turns 30" / "5 years", `S.specialLine`), a kind
  (birthday, anniversary, other — icon and starting colour), a colour,
  remind on the day. They ride the holidays' path as a `Holiday` with
  `special` set (`TaskProvider.daysAround` merges them into
  `Holidays.around`, cached): after the public ones, in their own
  colour, on the grid, day panel, day sheet, hours view and Schedule —
  where a day with only a special day on it still shows
  (`specialDaysBetween`). A tap on the card opens `showSpecialDaySheet`
  (day/month/year wheels, `DayWheels`, "—" past this year for no year).
  Listed and added in Settings › Calendar › Special days. Feb 29 falls on
  the 28th. Read at start (`TaskProvider.start`), after a sync or restore,
  and on their own changes — not on every agenda read (a tick), which
  also kept `screens_test`'s 80ms drains in time. Alarms: id
  `Reminders.specialBase` + id, all-day hour, no buttons, not full
  screen. Not on the home-screen widget.
- **"Show completed" applies everywhere a run is drawn**
  (`TaskProvider.setShowCompleted` via `ChangeNotifierProxyProvider`); the
  full lists (`allUpcomingByDay`) keep them.
- **In-progress tasks show `InProgressBadge` on every card.**

### Moving, selecting, putting off

- **Long press picks a card up** (no drag handles). Held and released within
  18pt, it is picked out instead (`Selection.lifted`).
- **Selection** (`Selection`, `SelectionScope`, `SelectionSlot`,
  `moveAllToDay/moveAllToGroup/setAllDone/removeAll`): taps toggle while
  anything is picked; picked cards get a lifted colour rim
  (`foregroundDecoration`) and an outer glow. The add row becomes a bar: Move
  to day, Move to group, Mark done, Delete (asks). One selection across
  scopes; Back, group change and screen change put it down. Not on the board.
  `ClipRect` only while leaving, or it clips the glow.
- **Swipe left on Schedule puts off** (`PutOff`, `offerUndo`,
  `TaskProvider.putBack`): part way shows Next day / Pick day; past 55% or a
  fling does Next day (tomorrow, or the day after its own if later). Undo via
  `putBack`. Not for done cards or during selection. Schedule only.
- **Carrying a card to another day moves it** (`Carry`, `CarryArea`,
  `CarryMark`, `moveToDay`), keeping its time, clearing `sort_order`. On
  Schedule drop in any run except Overdue. On the calendar, over the month
  the card becomes a free-moving day-sized tile (`_ShrinkingCard`,
  `Carry.shrinkTo`, `_AtFinger`, rounded 14, light rim) — it doesn't snap to
  cells; the outline says which day. Holding at a side turns the month
  (`_watchEdges`, `_turn`, 600ms then 900ms) with side tabs (`_EdgeHints`,
  neutral). The drop is done by a `Listener` that calls `cancelReorder`. Grid
  and carry share one `MonthLayout`. Holidays can't be moved or displaced.
- **A carried card is penned in the screen it can drop on** (`DragWithin`,
  `_KeepInside`), held against the edge, not clipped; pens anchor to
  undraggable rows; keys belong to the state. **It's the card alone**
  (`liftedCard`): painted in the ground colour in its own corners, a little
  scale, no `Material` slab.
- **Schedule is a heading + reorderable sliver per run** (`_RunOfDays`, `_Run`),
  as is the calendar's day panel; slivers so it stays one lazy scroll.

### Schedule, Search, Done, Board

- **Schedule is a running order of days**: plain dates, same filled cards,
  holidays among them. Badges for words (`Today` pill + date; Overdue red; No
  date). Header has Search and Today (scrolls home).
- **Search** lays results out like Schedule (Overdue, upcoming, No date, then
  past latest first); ticks work as anywhere.
- **Lists are re-read when the date changes** (`TaskProvider.catchUp`, on
  resume and at midnight).
- **Done is a log of ticks** (`completions`, schema v6, `AppDatabase.complete`
  / `untick` — every tick path goes through these). Three figures and seven
  bars, neutral; reads only while shown.
- **Board**: Not started / In progress (`started_at`, schema v7) / Done
  (`BoardScreen`, `Stage`, `moveToStage`, `Task.toStage`). Drawn like Jira:
  grey lanes, small-caps headers with counts, flat neutral cards (not
  inked), colour square, group lozenge, date lozenge (red when past),
  chevrons for priority; key hidden (`BoardCard.showKey`). A lane is most of
  the screen (`laneFraction`), snapping to three places (`_LaneSnap`), all
  lanes kept built. Pick-up after 300ms; carried card stays at its size
  (`_Lifted`), square, not tilted; outer 18% (`_Board.edge`) turns at once,
  then every 900ms. No move button, no bottom drop bar. Plus in header.

### Groups

- **One group per task; Schedule and Calendar can show one group**
  (`GroupChips`, `TaskProvider.showGroup`). Tags were built and removed. Chip
  row (All, groups, plus) always shown; long press carries a chip to reorder
  (`lists.sort_order`, schema v9), released in place opens it to edit. A
  carried chip stands on `GroupChips.ground`. On Schedule the row is part
  of the glass head (`GroupChipsOnGlass`, `GlassTop`) and stands on the
  full blur, as the title does, and the glass ends square at its foot
  (`GlassTop.fade` 0): a strip fading out below it, over the room above
  the first day's heading, was asked off (2026-11-19). **The chips are solid**, the chosen one the field's
  grey, the rest the ground with a hairline (`onGlass`): see-through
  chips and chips each a blur of their own were both asked back. A
  frosted strip behind the row alone was asked off; the whole top on
  glass was asked for after.
- **Default group is the oldest** (`TaskList.oldest`), never deletable;
  deleting another moves its tasks there.
- With a group chosen: only its tasks, no phone events, holidays stay, new
  tasks go into it; not stored. Alarms, widget and overdue dot use full lists
  (`allOverdue`, `allUpcomingByDay`). **A group's colour is its tasks' colour**
  (`_taskColourToGroup` migrated the old setting).
- **The open add field offers groups**: one chip on its
  second row opening a list above it (`_GroupButton`, `_Popup` — an
  `OverlayPortal`, not a route, inside a `TextFieldTapRegion`, so the
  keyboard stays), reset each opening to the group on show (`groupForNew`),
  else the default. Shown with a group chosen too (asked for; it was All
  only).

### Shell, navigation

- **Start screen is a setting** (`AppScreen`), read in `main` before the first
  frame, never waiting for `SettingsProvider.load` (it may show a permission
  dialog). The shell takes it once.
- **Hidden screens** (`hiddenScreens`): never all five; start falls back to the
  first visible but the choice is kept (`startScreen`). Overdue dot is on
  Tasks, or Calendar if Schedule is hidden. Hidden screens still build.
- **Four tabs, no menu.** Six read as "overwhelmed"; four was asked for.
  Schedule, Board and Done are views under one **Tasks** tab (`taskViews`,
  `TaskViews`, `_tasksTab`), which reopens the view last shown (`_lastView`).
  Their headers write all three names, the current one lit, the others
  dimmed and tappable (`ViewTitles`, `ScreenHeader.view`) — no extra row.
  One view left: a plain title. The side menu (hamburger, blurred screen)
  and the Settings switch for it were removed; their history is in git.
- **The bar** (`_TabBar`, `_Tab`, `BarRoom`): floating pill, 1.4pt light rim,
  23pt in from the sides (`BarRoom.tabsSide`), icon over name, neutral grey
  pill slides to the current tab (240ms), names shrink not cut. Floats over
  the screens, a little frosted (blur 17, fill at 60%), on `_BarGround`:
  the add field's strip in the bar's own grey (`p.panelHi`, asked for;
  from clear at the bar room's top to 80% at the foot), run on under the gesture bar (`below`, the shell's Stack
  unclipped) so it doesn't stop on a line — on Android 14 the system's
  own bar is opaque below the app, so the emulator still shows one. It
  was a blur from nothing to 1.5 (asked off for the tint);
  `FadingBlur` (`shaders/fading_blur.frag`, still under `GlassTop`: one pass blurring each row by its own amount,
  up and down only; given screen coordinates, and on GLES a flipped
  texture). On Impeller a second backdrop pass reads the screen as it was,
  not the first pass's output (side by side, nested or composed), so a
  pass across never showed; at 1.5 one direction can't be told from two,
  but large it smears type into streaks. Masking a blur with a
  `ShaderMask` draws nothing. **Every backdrop filter costs a read of the
  screen and passes of its own**: 2.11.14 (sixteen bands here, seventeen
  in the head, a blur per chip) dropped frames; measure with
  `showPerformanceOverlay` on a profile build before adding one. The head's bands
  and its `FadingBlur` share one `BackdropGroup` (`_Glass`), as do the bar
  and the plus (`_TabBar`). To see what the GPU pays, run the emulator
  with `-gpu swiftshader_indirect`: scrolling Schedule took 127ms a
  frame there with the glass, 68 without the head's, 21 without any
  blur; grouping made it ~110. Two bands instead of four didn't measure
  faster; none left an edge across the title. **Every screen runs on
  under it** (the shell no longer pads pages): scrolls end with
  `BarRoom.of(context)` of room; Schedule and the calendar rest their
  field over their foot with one widget (`FieldInBarRoom`), standing on a
  light strip of the ground while the keys are up. The calendar sizes its grid to
  what the bar leaves; its day panel is taller by the room, opening, the
  month's black runs on under the bar and pushes the day off the screen
  (a grey band under the opened month, and a black cover fading over the
  day's foot, were both asked off). **Screens not on show are under
  `TickerMode` off** (`_behind`): the `IndexedStack` kept them ticking,
  and the unvisited Vault's spinner held the app at 60fps, 27% of a core,
  from start. Back goes to the start screen before leaving
  (`Selection.anyActive` first). Tasks' icon is drawn (`_TasksGlyph`): a
  short checklist, a purple tick over a ring, each with a line — chosen
  from mock-ups. The tick is the bar's one colour, asked for, dimmer
  unlit; lit, the rest only brightens (a filled ring would read as
  ticked). Two rows of boxes and dashes came first and looked cramped; a
  purple outline looked bad; a clipboard and a box with a breakout tick
  were redone.
- **Every screen's top is glass over what scrolls under it** (`GlassTop`,
  `HeadRoom`, `widgets/glass.dart`): Schedule, Done, Vault and Settings run
  up under the status bar and their head (Settings' title is pinned now);
  the head stands on blur 17 under the ground at 65%, the blur thinning to
  none over the head's foot third (`GlassTop.leadOf`, 16–44pt — 24 showed
  a line across the cards, 44 left Settings' title over sharp rows): four
  bands of plain blur from 2 to 17 (`GradedBlur`, one `BackdropGroup`),
  then a `FadingBlur` from 2 to none, since bands show their edges where
  type is still readable. Scrolling Schedule on the emulator, raster time
  was 16.4ms a frame before the glass, 19.0 (max 30) in 2.11.14, 3.2 now. Taps
  on the head stay on it. Scrolls start with `HeadRoom.of(context)`, as
  they end with `BarRoom`'s. The shell's `SafeArea` leaves the top to the
  screens; Board and the calendar take it back themselves (nothing scrolls
  under their heads); a banner takes the status bar's room in their place
  at once. The wide layout keeps the head above the body.
- **While the keys are up the bar is drawn at alpha 1/255, not left out**
  (`_WhileKeyboardDown._faint`): left out, the frame that brought its
  blurs back took 23–30ms to draw on the Galaxy at the end of every
  closing (2.11.22–2.11.30).
- **With the bar, a 56pt round plus floats above its right end** (`_AddButton`,
  `BarFoot`, `_WhileWriting`, `_WhileKeyboardDown`), only on Schedule and
  Calendar. Tap opens the field (which lives in the bar's room while the
  keyboard is up, the bar hidden); hold opens the full form. Undo and
  selection take the bar's place; `withdrawUndo` on screen change.
- **Settings is six pages** (`_Page`; Screens, General, Appearance, Calendar,
  Tasks, Reminders, plus Sync and Backup; About on the list), each a panel of
  rows like the phone's settings (`_Group`, `_Row`, `_SwitchRow`, `choose`):
  icon, name, value underneath; tap flips or opens a choice sheet. Clear
  completed is the one red row.

### Keyboard and the add field (read before touching)

- **Nothing moves when the keyboard does**: no `Scaffold` resizes;
  `SafeArea(maintainBottomViewPadding, top: false)` in the shell; `KeyboardGap` subtracts
  the kept strip.
- **The quick-add bar is attached to the keyboard** (`KeyboardLift` translates
  it, same frame, nothing else). **Do not put a curve, spring or cap back.**
- **In the bar's room, Android carries the field on the keys itself**
  (`KeysCarry`, `KeysCarry.kt`, `CarriedField`, `FieldCarry`): Flutter's
  surface and the keyboard's window reach the screen a frame apart as
  often as together, so no timing in Dart glued it (2.11.22–2.11.31, the
  clock below, had the numbers within 2pt and the field still visibly off).
  Dart sends a picture of the field (`toImageSync` of a repaint boundary,
  raw RGBA) whenever it changes while up on the keys, with where it rests;
  a view over Flutter's draws it at the top of the
  keys from `onProgress`, which Android applies with the keys' own move.
  `onPrepare` puts it up and tells Dart (`carry`); Dart leaves its copy
  undrawn (`KeyboardGap.carried`), draws it again at rest and says `drawn`,
  and the picture goes three frames later (same place, so no seam). Closing,
  it is put by three frames after the field reaches the foot (`park`) —
  the keys take ~120ms more through the strip, and the bar is back by then.
  The plus first draws the field open at rest and pictures it
  (`FieldCarry.raise`, `KeyboardGap.raising`, ~37ms on the emulator), then
  asks for the keys; so in the bar's room the tools row does not grow in.
  A filing tick `drop`s the picture (the field goes at once). Recordings
  take the display's strip over the picture while it shows (`covers`).
  Everything else on the keys (day sheet, form, a slide with no picture)
  still rides the clock below.
- **Keyboard height is the larger of Flutter's `viewInsets` and Android's
  own report** (`KeyboardGap.of`, `MainActivity`): `Type.ime()` from the
  display bottom minus what lies below the window. Don't try to correct
  `viewInsets` arithmetically — its meaning changes mid-slide.
- **In a slide the field is read off the slide's own clock at the vsync
  each frame starts at** (`MainActivity.clockOf`, `_Slide`,
  `KeyboardGap.take`): Android sends where the slide was at which vsync,
  the frame period, its length and its curve (once); Dart reads it at
  `currentSystemFrameTimeStamp` less a period — that stamp is the vsync
  the frame is *shown* at, and read there (2.11.29) the field went up a
  frame ahead, a card showing under it. Reports only correct the clock: a
  report lands 0.2–1.1ms after Flutter's frame for its vsync has begun, so
  following reports as they land (2.11.28 and before 2.11.23) put the
  field a frame behind. A report at fraction 0 is taken to start a
  frame later (2.11.29 took it as the start: 57pt up with the keys at 20;
  2.11.30 held: 15–20pt under them for a frame). A slide with no curve (the
  swipe back) is carried on from its last two reports (`_Trail`), at most
  1.5 frames. Lead per direction, 0 as shipped, in Settings › Debug ›
  Keyboard (`Tweaks.keysLeadOpen/Close`). On the emulator the field trails
  by about a frame (its pipeline is deeper); judge on the phone. Line a
  recording's `reach` up against `insets` (`viewInsets` + the 15pt strip,
  which is Android's report for the frame it is logged in) rather than
  measuring the video; judge by eye on a day with tasks.
- **Edge-to-edge is read from the content view's insets, never its height**
  (`MainActivity.contentNav`).
- **A tick on an empty field behaves like cancel** (`QuickAddBar._submit`):
  keyboard goes, focus stays, so the next opening doesn't start the IME
  connection from scratch (that opening was the one that misplaced the bar).
- **Only `KeyboardLift`, `KeyboardRoom`, `QuickAddBar`'s frame and `FieldInBarRoom` read the inset** (and `CarriedField`, after the frame, for where the field rests).
- **Long-press the Settings title for keyboard numbers**
  (`KeyboardGap.showNumbers`, `KeyboardNumbers`). Debug, English only.
- **In the bar's room the field stands on a light strip**: up on the keys
  it had a band of the ground under it (4pt above, 12pt at the sides, 8pt
  below) and a 48pt fade above; that strip was asked off (2026-11-18),
  then asked blurred 0→1.5 (the bar's `FadingBlur`), then asked not blurry
  but "transparent from 100 to 80", then "to 40", in the field's grey
  (`p.field`, asked for; it was `p.bg`), across the field's own room
  only: clear at the field's top edge, 80% at the keys (60% let the dates
  under it read clearly; 75% came between), showing beside
  and under the field. It reached up over the screen above the field
  (24pt, then 64pt) until a marked screenshot showed that was never
  meant. A plain tint, so it is in the
  picture Android carries (`CarriedField.above`) and rides the keys with
  the field. Without the bar (`foot == 0`, Schedule's `!overBar`) the field
  still has its ground and fade, following what is under it
  (`_groundUnderField`, `_fadeStrength`, `_overGrid`; `GroundFade`, 48pt,
  smoothstep). Schedule pads its end with `KeyboardRoom`.
- **Field and its button are filled `AppPalette.field` with the bar's rim**
  (`BarRoom.rim`); focus shows only the caret. **Quick-add button: plus →
  tick when open**, plain, not gradient. Plus opens the full form.
- **Open with the keys up, the field is two rows** (asked for): title on
  top; under it a plus that attaches (Photo/Camera/File, `_AttachButton`,
  a paperclip once something is), the group chip, and the tick at the right
  end in place of the button beside it. Keys down (Back), it folds back to
  one row with its button. After a picker the keyboard is asked back once
  Caldo is resumed (`_whenInFront`); asked at once, Android drops it.

### Forms and pickers

- **Date/time pickers are our own sheets** (month grid, wheels); no Material
  dialog or dial.
- **Clock wheels**: no band behind the middle — a `ShaderMask` carries full
  strength in one row's height, a third outside (applied to pixels, not per
  number). The touched wheel turns accent on pointer down, white on up.
  `diameterRatio: 100`.
- **One clock everywhere, chosen in Settings** (`Dates.time`/`Dates.clock`
  with `h24`; `MediaQuery.alwaysUse24HourFormatOf`; `Dates.use24Hour` for
  notifications; `Reminders.refresh` on change).
- **Task form**: back arrow hides once anything is touched; Cancel/Save pinned
  at the foot over `GroundFade`, riding `KeyboardLift`; `KeyboardRoom` below
  the list, `_reveal` keeps fields clear of the fade. Save/Cancel dismiss the
  keyboard.
- **Sheet actions are two plain words, Cancel and Save, drawn towards the
  middle.**
- **Reminder lead** (`Task.remindBefore`, `reminderLead`, `_ReminderField`,
  `Dates.lead`, `dayLeads`): null follows Settings, `Task.silent` never;
  all-day tasks take whole days only. A row opening a choice sheet, not a
  dropdown.

### Look

- **Platform font**, not Inter/google_fonts.
- **Near-black ground (`#111112`), not true black** (asked off as too stark),
  shared by the calendar, widget, reminder cover and system bars
  (`_barsOn`); neutral greys (no blue tint); raised greys lifted with it.
- **Controls are neutral; accent is rare**: switches, Undo, update banner, a
  touched clock wheel, colour pickers. Tasks wear their own colour.
- **Settings › Debug, an admin's only** (`Tweaks`, `theme/tweaks.dart`,
  `settings_debug.dart`, a `part` of the settings screen; English only):
  every `AppPalette` colour per theme, the accent's three, the four signals
  (`AppColors.danger/overdue/weekend/holiday` are getters for it) and card,
  done-card and day-chip ink as multipliers. Shown live while a colour is
  picked, kept on Save; in force only while its switch is on; device-only
  (prefs `debug_tweaks`, not in backups); signing out turns it off. Copy
  changes hands them over as JSON to be built in. Keyboard numbers have a
  switch there too. Native surfaces (widget, reminder cover) don't follow.
- **Performance numbers** (`PerfHud`, `widgets/perf_hud.dart`, over
  everything in `MaterialApp.builder`; switches on the Debug page, not
  stored): fps against the display's rate, frames over budget, running
  tickers, build/raster avg/max (engine timings, batched ~1s, so over the
  last 2s), CPU of the process and of the UI and raster threads from
  `/proc` (UI is the main thread where Flutter merged them), RSS, free
  memory, GPU and temperature only where sysfs lets an app read them (not
  the emulator). Draggable; starts above the bar, since Flutter's own
  graphs (`showPerformanceOverlay`, the second switch) take the top. While
  Debug mode is off both rows are greyed and do nothing, but keep their place
  (`PerfHud.graphsDrawn`). Idle
  should read 1 fps and 0 tickers. On the emulator raster time includes
  waiting on the swap (~16.6ms while drawing every frame, ~5 idle).
- **Recording to send on, of Caldo and its keyboard only** (Debug ›
  Recording; `Recording`, `RecordingOverlay`, `ScreenRecord.kt` +
  `RecordService`; Android only, greyed with Debug mode off). Asked to
  record this app and nothing else, then for the keyboard in it. The app
  is `PixelCopy` of Flutter's `SurfaceView`; the keyboard, a system
  window, comes only from MediaProjection (whole display:
  `createConfigForDefaultDisplay`; consent each time; a
  `mediaProjection` foreground service with a Stop notification), mirrored
  at video size into an `ImageReader`, and only the IME inset's strip of
  it is laid over the app's copy (during a slide the keyboard's full
  height, `MainActivity.keysSliding`: the insets are the slide's end, so a
  closing's keys vanished from the video at once), only while Caldo has
  window focus — so
  status bar, notifications, the shade and other apps never reach the
  video. Composed on a `lockHardwareCanvas` of a MediaCodec input
  surface, muxed to MP4, ≤1280 long side, ≤30fps, no sound, at most 5
  min, one kept in `cache/recordings`. Frames only after Dart pings
  `drew` (a persistent frame callback), or a screen change with the
  keys up, and for 80ms after, so idle costs nothing. Whole-screen
  capture (the first build) and app-only without keys (the second) were
  both asked off. Back out of the app ends the recording and keeps it.
  Beside it a `.log.jsonl` on the video's clock (`t` ms;
  `System.nanoTime` at start = Dart's `Timeline.now` = pointer and frame
  timestamps; pts rebased to the start), buffered and written each
  second and on leaving view: touches, every frame's build/raster, the
  HUD's numbers each second, insets, routes, lifecycle, errors,
  `debugPrint`, marks. While recording: a ring under each finger and a
  draggable badge (time, flag = mark, stop). **Button on every screen**
  (a Debug switch, prefs `record_button`, not in backups; shown only with
  Debug mode on): the badge stays as a red dot while idle and starts a
  recording from anywhere; right edge at 42% height, grows leftwards,
  dragged place kept for the run; no timer while idle. Stop opens the
  share sheet (`FileProvider` serves `recordings/` too). Read one with
  `tool/recording.py <log> [--frames s…] [--slow N] [--between a b]`; on
  the emulator a tap's first video frame came 10ms after its logged
  time, ~20–25 copies a second; the keys' strip can run a frame ahead of
  the field while they slide.

### Reminders

- **Alarms are rebuilt from the agenda in `TaskProvider.loadTasks`**
  (`services/reminders.dart`): first sync of a run resets all, later ones
  diff (`Reminders._standing`), after the lists are on screen. All-day at the
  Settings hour (default 9), timed at their time.
- **Changing a reminder setting re-sets standing alarms** (`Reminders.configure`).
- **Reminders no-op until `init`** (called only from `main`) — keeps tests quiet.
- **Permission asked on first run** from `SettingsProvider.load`. Exact alarms
  (`USE_EXACT_ALARM`), inexact fallback.
- **Buttons: Done, Snooze 15 min, Dismiss** (`Reminders.done/snoozes/dismissed`,
  `onReminderAction`); the hour's snooze is on the full-screen page only.
- **Full-screen only when locked** (`fullScreenIntent`, `ReminderCover.kt`,
  `MainActivity.wakeFor`): native, opaque, glow in the task's colour,
  `RenderEffect` blur. Must stay opaque; don't hide Flutter's view under it.
  Switch on the Reminders page; `_FullScreenBanner` if not allowed. Try it
  with `am start -n com.igor.caldo/.MainActivity -a SELECT_NOTIFICATION --ei
  notificationId 999 --es payload '{"title":…}'` on a locked emulator.
- **Buttons are handled on the plugin's isolate** (`Background._change`):
  write, `Reminders.reset` for that task only (never a full sync), redraw
  widget, ping the app via `IsolateNameServer` (`Background.listen`). Snooze
  is stored (`snoozed_until`, schema v5). Alarms cover the overdue run too.
  **`ActionBroadcastReceiver` is declared in the manifest by hand.**

### Home-screen widget

- **It is Schedule in small** (`TodayWidget.kt`, `TodayWidgetRuns.kt`): runs,
  inked cards, working tick, tap opens the form, plus opens a new task;
  always dark; looks like the app (not a calendar widget).
- Reads a copy of the agenda (`TodayWidget.publish`) and sorts against today
  at draw time. **Nobody tells it to redraw**: `CaldoApplication` listens to
  the preferences. Ticks run Dart on one process-wide engine (`Headless`,
  `widgetMain`).
- **Android 12+**: each tick is a real `CheckBox` with an `animated-selector`
  per swatch (`layout-v31/widget_task_<swatch>.xml`, generated by
  `tool/make_widget_ticks.py` — rerun after changing a swatch);
  `saveEnabled="false"` (2.3.3 ticked every task without it). The page is one
  frame (`layout/widget_page.xml`) of stable-keyed views placed by top margins
  — never stacked — inside a one-row inline `ListView` for scrolling
  (`RemoteCollectionItems`; no `RemoteViewsService`). Heights measured in
  process (`fit`), cached; at most 60 cards (`MOST`).
- **A tick plays as in the app** (`TodayWidget.tick`): `SETTLE` 490ms, `HOLD`
  150ms, slide 260ms via `stateListAnimator`/`translationY`
  (`animator/widget_*.xml`), leaving cards fade (`widget_leave.xml`). Moves
  are computed from `TodayWidget.last`; Dart writes only after the card has
  gone; `Background.toggle(done:)` writes the box's state.
- **Phone events show too** (`PhoneEvents.kt`, `layout/widget_event.xml`),
  read by the widget itself; whether shown rides on the copy
  (`SettingsProvider.storedEvents`). Event keys start at 1e9.

### Phone calendars, language, updates, backup, sync

- **Phone events sit beside tasks like holidays** (`EventsProvider`,
  `DeviceCalendars`, `EventCard`, `caldo/calendars`): opt-in, read-only,
  calendars stored as excluded ones. All-day events read in UTC
  (`events_test.dart` passes under `TZ=America/Los_Angeles`). Screens read the
  provider as nullable.
- **Twelve languages** (`S`, `l10n/strings.dart`, `words_*.dart` tables;
  missing keys fall back to English; `l10n_test.dart` checks keys and
  `{blanks}`). Plural rule per family. `S.of(context)` on screens,
  `S.current` elsewhere (`SettingsProvider.prime` on isolates). English keeps
  its fixed patterns; others use `intl` skeletons, full month headers,
  capitalised. Kotlin side uses `getBestDateTimePattern` and
  `values-xx/strings.xml`. `l10n_screens_test.dart` draws key screens in every
  language. Unreviewed translations.
- **Updates** (`services/updates.dart`, `widgets/update_banner.dart`,
  `caldo/updates`, `SelfUpdate.kt`): GitHub's recent releases vs installed
  (dotted-number compare, `Updates.pick`); the newest is offered with every
  skipped release's notes. Banner: version, a line, Later + filled Update;
  a tap opens What's new (`showUpdateSheet`, notes drawn from their
  `New:`/`- ` lines). Looked for on start and on every resume, at most
  once a minute (`Updates.look`). **Later** hides it and stops looking
  until the app restarts; Settings › About keeps an "is out" row meanwhile.
  **A release whose notes hold `<!-- priority: high -->` is urgent**: it
  takes the navigator's place in `MaterialApp.builder` (`UpdateWall`: notes,
  Update, no Later; Back leaves the app) until installed, even after Later
  on another. Kept in prefs (`updateUrgent`) so it bars from the next start
  offline too; dropped when GitHub answers with nothing newer.
  Banner downloads the ABI's APK and installs through Caldo's own
  `PackageInstaller` session (keeps full-screen permission, no prompt on
  12+); ends on the home screen with an `UpdateDone` notification since
  Android won't relaunch it. The repo is public so no token is needed. No
  `taskAffinity=""` (it caused two Caldos). Nothing checks until
  `Updates.enable`. To test: `adb root`, install a lower-labelled build, drop
  the target as `cache/updates/Caldo-<latest>.apk` (chowned).
- **Backup** (`Backup`, `AppDatabase.dump/replaceAll`,
  `SettingsProvider.exported/restore`, `caldo/backup`): JSON of raw rows +
  schema version (newer refused), one transaction, settings included except
  phone calendars, ≤64MB, restore previews what the file holds. **Auto backup**
  (`Backup.autoIfDue`) to a persisted folder (`ACTION_OPEN_DOCUMENT_TREE`) on
  open/resume when due, keeps the last seven `caldo-auto-*` files only.
- **Sync groundwork** (schema v11, `AppDatabase._addSync`): every row has
  `uuid`, `updated_at`, `dirty`; deletions go to `tombstones`. **Integer ids
  stay** (alarms, widget, screens use them). **Triggers stamp, not writes**;
  suppressed while `sync_state.applying`. One `defaultListUuid` everywhere.
- **A round pushes then pulls** (`Sync`, `SyncStore`); a pulled row loses to a
  newer local change; rows are marked sent only as sent; cursor written with
  the rows. A different account marks everything dirty. Tested with
  `FakeServer` and `AppDatabase.named` (`sync_test.dart`).
- **The server is Supabase Cloud's free tier for now** (project
  `eqgczddzmvmczwcgbenr`, URL and publishable key built into `Account`); the
  user's VPS has 2GB, too little for the stack. A device can still be
  pointed at a local Supabase in Settings (it then uses the local demo key);
  cleartext is allowed only to local addresses
  (`res/xml/network_security.xml`). Plain `supabase` package, not
  `supabase_flutter`. Session in preferences, renewed without holding up
  the first frame. Rounds on open, resume, `Sync.soon` (2s after any
  read-back), realtime, every 5 min.
- **A round twice a day with the app closed** (`DailySync.kt`, WorkManager,
  booked while signed in via `caldo/sync`). Run by whichever engine holds
  the session: the app's if it lives (asked over `caldo/sync`), else the
  widget's `Headless` (`Background.sync`, `Account.syncOnce`: reloads
  preferences, holds the session for the one round only) — two engines
  renewing one session spend its refresh token twice, and Supabase ends it.
  Pulled tasks get their alarms one by one (`SyncStore.touchedTasks`,
  `Reminders.reset`), never a full re-set. Not on Linux. To try it, move
  the emulator's clock 13h on (`adb root`) and `cmd jobscheduler run -f -n
  androidx.work.systemjobscheduler com.igor.caldo <id>`: WorkManager won't
  run a periodic job early even when forced.
- **Sign-in is a username and a password; accounts are made only by
  invite** (`Account.signIn`/`join`, `showSignInSheet`/`showJoinSheet`,
  `supabase/migrations/…_invites.sql`). Codes by email were first, but the
  free tier will not send our template through its own mail, and the user
  set no mail server up. A name is kept as `name@caldo.invalid`
  (`Account.loginOf`/`nameIn`) — `.invalid` can never receive mail. Auth's
  `before_user_created` hook refuses any new account without an unused
  invite; a trigger on `auth.users` spends it (and rolls back a second
  account in a race). Only rows in `public.admins` may `make_invite()`;
  they get **Invite someone** in Settings (`Account.admin`, asked at
  sign-in and before every round until yes, so a grant shows without a
  restart). An invite is
  one account, no expiry, sent as `caldo://invite/<code>` (claimed in the
  manifest, handed over on the widget's launch channel; Flutter's deep
  linking is off) — on Linux the code is pasted into Join. No password
  reset: an admin does it from the dashboard.
- **All-day tasks travel as a day** (`SyncStore._toDay`/`_fromDay`); timed
  tasks as instants.
- **Attachment files travel after the rows** (`FileSync.carry`, `FileStore`,
  `Account._Files`, bucket `attachments`, `…_attachments.sql`): a pass after
  each round, apart from it (`Sync._carry`, `Sync.carried`), compares the
  server's list with the files named here — up what is missing there, down
  what is missing here (`.part`, then renamed). No local record of what was
  sent. Key is the copy's folder uuid under `<user id>/`; a file named any
  other way is ignored (`FileSync.keyOf`, guards paths from other devices).
  Over 50MB stays on its device. A file no task names leaves the server a
  day after it was put there. Deleting the account removes the files first
  (Storage won't let SQL delete them).

### Vault

Asked for as "secrets storage, ciphered, opened by fingerprint or PIN";
chosen: inside Caldo, synced end-to-end encrypted, fingerprint with a
master password behind it.

- **Two layers of key** (`VaultProvider`, `Sealing`): a random 32-byte vault
  key seals every secret (AES-256-GCM, fresh nonce, the row's uuid bound in
  as associated data); the master password (Argon2id, `Kdf.strong` 64 MiB
  ×3, ~1s on the emulator, on an isolate) seals the vault key. The setting
  is stored per key, so it can be raised later. A new password re-wraps
  the same key; nothing else changes on any device. pointycastle, pure
  Dart, so phone and desktop seal alike.
- **Tables `vault_keys` and `secrets`** (schema v12, `_addVault`, stamped by
  the same triggers via `_stamp`). Everything typed, the name included, is
  inside one box (`Secret.seal`). Synced and backed up as they are; a
  backup from before v12 leaves the vault alone (`_vaultTables`).
- **Two vaults made apart become one**: unlocking opens every key the
  password opens and moves secrets to the oldest (`_merge`); a key under a
  different password waits (`sealedElsewhere`, a row that opens
  `showOtherPassword`) and is merged into the key already open. Signed in
  with no vault, the screen syncs first (`looking`) so a second isn't made.
- **Fingerprint** (`Vault.kt`, `caldo/vault`): Android's own
  `BiometricPrompt` (not AndroidX — Flutter's activity isn't a
  FragmentActivity), API 28+. A Keystore AES key, auth per use, fingerprint
  or (11+) the phone's PIN, invalidated by a new enrolment ("gone" → back to
  the password). It seals a copy of the vault key kept in preferences
  (`vault_finger`, never exported or synced); `proof` checks it is still
  this vault's. Asked for by itself when the screen comes on show locked.
- **Locks after the app is away `lockAfter` minutes** (default 1; 0 = at
  once); the prompt's own pause (`asking`) doesn't count. `FLAG_SECURE`
  only while the vault is open *and* on show — screenshots of the open
  vault on the emulator are black on purpose; look at it on Linux.
- **Copy** marks the clip sensitive and takes it back after 30s if still
  ours (`VaultDevice.copy/clearCopied`, re-asked on resume since Android
  hides the clipboard from the background).
- Forgot the password: Delete vault on the locked page (tombstones reach
  every device). No recovery, by design.

### Android platform bits

- **Launcher icon** (`LauncherIcon.kt`, two `activity-alias`es): on Samsung the
  free-standing page on transparent; elsewhere the filled page. Switched in
  `MainActivity.onStop` (`leftForGood`) — not `onCreate` or
  `onUserLeaveHint`, which close the task. The application's own icon is the
  free page (Samsung draws that).
- **Ask for the fastest display mode at the current resolution** (`MainActivity`).

## The MCP server

Asked for so an assistant can read and change the tasks (2026-11-21); the
next steps talked over were a watcher on the PC that hands a task marked
for Claude to `claude -p`, then a "Hand to Claude" action in the app.

- **It is one more device on the sync server**, not a reader of a local
  database: it signs in as the user and goes through `sync_push`/`sync_pull`
  (`Remote`, `SupabaseRemote`), so the phone hears within seconds and sets
  its own alarms. Each tool pulls first (`Caldo.refresh`); the account is
  held in memory (`Book`), never written ahead of the server.
- **It ticks with the app's model**: `models/task.dart` is Flutter-free
  (`package:meta`, no `setEquals`) so `Task.completed`, `toStage` and
  `Repeat` run there as in the app. Keep it so; `task_list.dart` and
  `special_day.dart` still import Material and are not used there. Server
  address and login naming are in `services/caldo_server.dart` for the same
  reason.
- **An edit sends only the fields it changed** (`Caldo._diff`; the server
  lays them over the row), stamped past the row's own, and is read back: a
  loss to another device's edit is reported, not claimed done.
- **The session, not the password, is kept** (`caldo-mcp login`,
  `~/.config/caldo/mcp/session.json`, 600), renewed by hand only under a
  file lock, the file read first (`SessionFile`, `ready`): every Claude
  session runs its own server, and a refresh token spent twice ends the
  session. Five servers starting on an expired token made one refresh.
  `recoverSession` won't renew with `autoRefreshToken` off; it signs out.
- **The vault is out of reach on purpose**, and so are groups' creation and
  attachments' files.
- Ids are the first 8 characters of the uuid. Times are this computer's.
- **Install**: `tool/mcp/install.sh` → a kernel snapshot run by Flutter's
  Dart (`dart compile exe` refuses packages with build hooks; sqlite3 has
  one), `~/.local/bin/caldo-mcp`. Rerun after changing `lib/mcp` or the
  models. `caldo-mcp call <tool> '<json>'` runs one from a shell;
  `XDG_CONFIG_HOME` points it at another session (tried on the local stack
  with an account made by the admin API).

## Linux

Two layouts on a desktop: **≥900pt wide is a desktop program**, narrower is
the phone app in a window. **Neither has been seen by the user on their own
desk** — their first word outranks this section.

- **`onDesktop` asks Flutter, not `dart:io`** (`utils/platform.dart`); tests
  run as Android. Desktop tests use
  `TargetPlatformVariant.only(TargetPlatform.linux)`.
- **Services do desktop work in Dart** (`Desktop`, `if (onDesktop)` in
  `Attachments`, `Backup`, `Updates`, `Reminders`); GTK dialogs, `xdg-open`.
  Tested in `desktop_test.dart`.
- Data under `~/.local/share/com.igor.caldo`; downloads in
  `~/.cache/com.igor.caldo`.
- **Name the Linux plugin halves directly** in `pubspec.yaml` (keeps Android
  halves and `jni` out of the APK).
- **System SQLite** (`hooks: user_defines: sqlite3: source: system`); after
  changing it, delete `build/native_assets/android`. `linux/sqlite_shim.cc`
  provides `libsqlite3.so` beside the program, linking `libsqlite3.so.0` —
  never a bundled copy.
- **Reminders fire only while the app is open** (`Reminders._alarms`, `_arm`,
  `_announce`; a timer re-checks every ≤30s). Buttons: Done and snoozes.
  **`Background._prepare` does nothing on desktop** — re-registering plugins
  broke every reminder after the first.
- **"Keys up" means an add field has focus** (`KeyboardGap.writing`). Enter on
  empty or Escape lets go.
- **Escape is Back** (`_EscapeGoesBack`).
- **Narrow layout**: mouse drags scroll like a finger, no scrollbars
  (`DesktopScrolling`); wheel over the grid turns a month/week a notch at a
  time (`_onWheel`); group chips use long press (`buildDefaultDragHandles:
  false`); theme states phone density. 640–900 wide keeps the phone column in
  the middle (`PhoneWide`, left in the tree switched off when wide).
- **Window** (`my_application.cc`): reopens at the closed size (first time
  1240×780, min 340×560), saved in `window` on `delete-event`; single
  instance; dark title bar.
- **Not on desktop**: home widget, phone calendars, full-screen reminder,
  camera, keyboard numbers, the vault's fingerprint. Five phrases have `…Desktop` variants.
- **Install**: `linux/install.sh` → `~/.local/opt/caldo`, `~/.local/bin/caldo`,
  entry `com.igor.caldo.desktop`.
- **Self-update** (`Desktop.replaceWith`) from `Caldo-linux-x64.tar.gz` when a
  release carries it; unpack beside, swap by name, relaunch after a second. If
  unwritable, open the release page. Version comes from `pubspec.yaml`
  (`--build-name` doesn't reach `version.json`).

### The wide layout

Sidebar, each screen drawn for its width, task form as a right panel.

- **`Desk.wideOf(context)` is the one question** (`widgets/desk.dart`,
  `DeskScope` in `MaterialApp.builder`; `Desk.isWide` without subscribing).
  Wide-layout tests pump `CaldoApp` (`desk_test.dart`, `pumpApp`).
- **Layout only switches with nothing open** (`DeskScope.observer`); screens
  sit under `GlobalKey`s (`_pages`) so state moves across.
- **Sidebar** (`DeskSidebar`): New task, Search, four screens with overdue
  count, groups as a list (click shows, drag reorders, right-click/pencil
  edits), Settings at the foot. No chip rows.
- **Form panel** (`TaskPanel`, `DeskFormPanel`, `openTaskForm`,
  `TaskEditScreen.inPanel`): screens padded by its width unless that leaves
  <420. With changes it doesn't give way, it nudges (`_Nudged`); "changes"
  means differing words (`_typed`, `_wordsDiffer`). Escape closes it, in two
  presses if a field holds the caret with something typed (`_escapeForm`).
- **Calendar**: one state (`_buildWide`), month opened full height, day panel
  384 wide on the right (the form's width), arrows + Today over the month.
  `MonthSizes.desk` at ≥72pt per day. Titles click to open and drag to move
  (`_TaskTitle`, `_DropDay`, `MouseDraggable`); carry tile capped 150×64.
- **Schedule/Done**: 760 column, lists span the window (`DeskColumn`,
  `DeskGutter`). Titles at one height (`ScreenHeader`, 48).
- **Board**: three lanes at once down to 200 each (`_Board.wideFraction`).
- **Settings**: list beside page (`_entries`, `_page`); no "Switch screens with".
- **Sheets become centred dialogs** (`showAppSheet`; `PickerSheet` on phone);
  **Search is a panel from the top** (`openSearch`).
- **Mouse**: drag picks up at once after 6pt (`pickUpListener`,
  `MouseDragRecognizer`), no drag-scroll (`WideScrolling`); Ctrl+click
  selects; right-click opens `showTaskMenu` (put-off lives there,
  `PutOff.move`).
- **Keys** (`DeskKeys`, a `Focus` above the navigator, `DeskActions`): Ctrl+N,
  Ctrl+F/K, Ctrl+1–6; calendar arrows, PgUp/PgDn, Home/T. Only Escape while a
  dialog is open; arrows pass through to fields.
- **Typed times** (`parseClock`): "9", "930", "9:30 pm".
- **Never first-use a `late final` `AnimationController` in `dispose`**; make
  it in `initState` (form panel, `UndoSlot`, `SelectionSlot`).

## Tests

`flutter test` — 358 tests, all passing; keep it so. `supabase test db` — 33.

- Each test file has its own temp DB dir (`initTestDatabase`);
  `AppDatabase.close()` for the same reason.
- Real DB work can't finish in `testWidgets`' fake async: seed in
  `tester.runAsync`; for UI-triggered writes use a capturing provider
  (`_CapturingProvider` in `screens_test.dart`) or poll inside `runAsync`.
- Screens are pumped at phone sizes so overflows fail — intentional.
- The test font draws em squares: assert layout invariants, not glyph widths.
- Exported keys: `monthTitleKey`, `calendarHandleKey`, `daySheetKey`,
  `searchFieldKey`, `screenTitleKey`, `taskCardTickKey`,
  `deskSidebarKey`, `deskFormKey`, `deskNewTaskKey`.
- "A Timer is still pending" after a test usually means the `dispose`
  animation fault above.
- `TaskPanel` is app-wide: wide-layout tests close it in `tearDown`.

## Building

Load-bearing for reminders: **desugaring** in `app/build.gradle.kts`, the
**action receiver**, the **two scheduled receivers and three permissions** in
the manifest, and **`res/raw/keep.xml`** (keeps the notification icon from
R8).

`android/gradle.properties` is capped on purpose (`-Xmx2G`, four workers, 1G
Kotlin daemon) — 13GB machine; do not raise. Stop the daemon afterwards:

```sh
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
(cd android && ./gradlew --stop)
```

**Signing**: `~/keys/caldo-release.jks` via `android/key.properties` (both
outside git; the original debug key). Lose them and no update installs over
Caldo again — keep copies off this machine. A release build without
`key.properties` fails on purpose.

**Release only when asked.** Commit each change, but don't bump, build or
publish unprompted (the in-app updater ships whatever is latest). A release
means both `release/` (`Caldo-arm64.apk`, `Caldo-armv7.apk`,
`Caldo-universal.apk`) and `gh release create vX.Y.Z release/*.apk` from the
latest commit. An update users must not put off carries
`<!-- priority: high -->` in its notes (`--notes`); add it only when asked.
`tool/package_linux.sh` adds `Caldo-linux-x64.tar.gz`; whether a
release carries it is the user's call.

Linux: `flutter build linux --release` → `build/linux/x64/release/bundle`.
Needs SQLite headers (`pkg-config sqlite3`).

## Running on the emulator

`ANDROID_SDK_ROOT` in the shell points at `/opt/android-sdk`, which has no
emulator; use `~/Android/Sdk`:

```sh
SD=~/Android/Sdk
ANDROID_SDK_ROOT=$SD ANDROID_HOME=$SD $SD/emulator/emulator -avd pixel_api34 &
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell monkey -p com.igor.caldo -c android.intent.category.LAUNCHER 1
# (monkey may send Home, which switches LauncherIcon; use
#  am start -a android.intent.action.MAIN -n com.igor.caldo/.LauncherFree to avoid)
adb exec-out screencap -p > shot.png
```

**The emulator always runs the latest commit**: after every change, build a
release APK (no version bump) and `adb install -r` it. Judge changes by eye
from a screenshot before saying they work. Screen is 1080×1920 at **dpr
2.625** (411×731). `input text` can't send Cyrillic.

**Long press can't be done with `input swipe`**; use motion events:

```sh
adb shell input motionevent DOWN 540 880
sleep 1
for y in 840 760 680 600; do adb shell input motionevent MOVE 540 $y; done
adb shell input motionevent UP 540 600
```

Not bugs:

- ANRs under load are usually host starvation (Gradle + emulator).
- A loaded host drops frames, which looks like a detached keyboard bar. Judge
  keyboard-riding UI on a **release** build, on a quiet machine, against the
  committed build as a control. Frame lag scales with speed; a wrong number is
  off by the same amount at every speed.
- Debug builds draw at half rate here; never judge motion on them.
- The emulator's keyboard does slide (~270ms, sixteen steps); down is one lump.
- First month opening after a cold start is slow on the emulator (GL warm-up);
  nothing in the grid causes it. Measure on a phone, over several cold starts.
- `screenrecord` drops frames: it shows a movement's shape, not smoothness.

## Running the sync server

Supabase in Docker (`supabase/`, CLI `~/.local/bin/supabase` v3.1.0):

```sh
supabase start -x imgproxy
supabase test db
supabase stop          # holds 2-3GB
```

API `http://127.0.0.1:54321` (emulator: `10.0.2.2:54321`), dashboard :54323,
Mailpit :54324. If docker access fails, `newgrp docker`.

**The cloud project** is linked (`supabase/.temp`): `supabase db push
--remote` applies migrations. **Never `config push` the repo's
`config.toml`**: it is the local stack's (site URL, a 1s mail interval,
pool sizes). Push a file declaring only what is meant, with `--workdir` on
a scratch directory; undeclared settings are left alone. `supabase db query
--remote` writes to the live database, so ask the user first; `--read-only`
needs no asking. An admin is made with `insert into public.admins select id
from auth.users where email = '<name>@caldo.invalid'`.

## Running on Linux

`tool/desktop/try.sh` runs the build on its own Xvfb display (`:99`) with its
own home and session bus; `--stop` ends it.

```sh
flutter build linux --release
tool/desktop/try.sh
import -display :99 -window root -crop 1240x780+0+0 shot.png
python tool/desktop/x.py click 80 230      # needs python-xlib (use a venv)
python tool/desktop/x.py key n ctrl
python tool/desktop/x.py type "Buy milk"; python tool/desktop/x.py key Return
python tool/desktop/x.py resize 480 780
```

`notifd.py` stands in for the notification server (`notifd.log`; write a
button key to `press` to press it). To try a reminder: stop the app, insert a
task a minute ahead with `sqlite3` (`due_at` ms, `has_time` 1), restart. Close
the window with `WM_DELETE_WINDOW` to test size saving.

Not bugs: a drag that pauses >40ms before release isn't a fling; GTK's file
dialog may drop the second typed character (type "/" and wait); the save
dialog selects the name without ".json"; clicking a file row opens it (kill
that program by pid after checking its `DISPLAY`). **Never `pkill -f` a
pattern the killing command itself contains.**

## Conventions

- Comments explain **why**, at about Dicty's density.
- Commit messages are prose: what changed and why. End with the
  `Co-Authored-By` line.
- `flutter analyze` clean before every commit.

## Known gaps

- Linux: reminders need Caldo open; a clicked notification can't raise the
  window; no scrollbars in the wide layout; x64 only. Undo's brush-off is
  measured against the window. `caldo://` links open nothing on Linux.
- No password reset for a forgotten password but by hand, and a free
  Supabase project pauses after about a week with no requests.
- Backups carry attachment records, not files; on a new phone they come
  down only if a synced device sent them. Files over 50MB never sync.
- Holiday names are in each country's language (English-speaking countries
  and Canada in English).

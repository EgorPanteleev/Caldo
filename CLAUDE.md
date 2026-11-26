# Caldo — working notes

A calendar + to-do app for Android, and for Linux (a wide window gets a
desktop layout; a narrow one is the phone's app). Flutter, local-first
storage. Repo `github.com/EgorPanteleev/Caldo`. Modelled on its sibling
**Dicty** (`/home/igor/dev/src/Dicty`) — same stack and theme; look there
first for style and structure questions.

These notes are kept short: what was tried, measured and rejected behind
each decision is in this file's git history (`git log -p CLAUDE.md`; the
long version is the parent of "Shorten the working notes"). Look there
before reopening a decision. Every decision below was asked for or fixed
after being seen on a device; reverting one will be noticed.

## Stack

Flutter 3.38.6 / Dart 3.10.7. `provider`, `sqflite` (`sqflite_common_ffi` on
Linux and in tests), `shared_preferences`, `intl`,
`flutter_local_notifications` + `timezone` + `flutter_timezone`. Platform
font. `path_provider_linux`, `file_selector_linux` on the desktop. Native
home-screen widget (`TodayWidget.kt`, plain `RemoteViews`). Network only for
the GitHub release check/download, Supabase (Cloud for now) and Firebase
pushes (`firebase-messaging`, Kotlin only).

## Layout

```
lib/
  data/holidays.dart       public holidays, computed on device
  l10n/                    strings.dart (S) + words_*.dart, a table per language
  db/database.dart         schema v17 (+ migrations); db/sync_store.dart
  models/                  task (Repeat, Priority), task_list (ListStyle,
                           colorOfTask), completion, secret, special_day
  providers/               task, settings, events, vault
  services/                reminders, background (isolates), today_widget,
                           device_calendars, updates, backup, sync, account,
                           attachments, file_sync, desktop, sealing,
                           vault_device, recording, agents
  screens/                 home (shell), tasks (Schedule), calendar, board,
                           done, search, task_edit, settings, desk_shell,
                           vault, agents
  theme/app_theme.dart     AppPalette + AccentColors, AppColors
  utils/                   dates.dart (every date/time string), platform.dart
  widgets/                 month_grid, task_card, day_sheet, day_hours,
                           quick_add_bar, keys_carry, tick_off, selection,
                           put_off, carry, desk, …
  mcp/                     MCP server: book, remote, tools, protocol, watch;
                           worker: worker, agents, talk, kept, usage, terminal,
                           accounts, subscriptions
bin/caldo_mcp.dart         the MCP server and watcher (plain Dart);
                           tool/mcp/install.sh, tool/mcp/watch.sh
```

Android: `MainActivity.kt` (refresh rate, keyboard, updates, widget
launches, calendars, backups), `PhoneEvents.kt`, `Attachments.kt`,
`TodayWidget.kt` + `TodayWidgetRuns.kt`, `CaldoApplication.kt`,
`LauncherIcon.kt`, `SelfUpdate.kt`, `ReminderCover.kt`, `DailySync.kt`,
`Vault.kt`, `ScreenRecord.kt`, `KeysCarry.kt`. Linux: Flutter's GTK runner
plus the window (`runner/my_application.cc`), `sqlite_shim.cc`, icon,
desktop entry, `install.sh`; no channels. Icon: SVG in `assets/icon/src`,
rendered by `tool/make_icon.sh`; PNGs checked in.

Seven destinations — **Schedule, Calendar, Board, Done, Vault, Agents,
Settings** — in five tabs: **Tasks** (Schedule, Board, Done), Calendar,
Vault, Agents, Settings. Any of the first six can be hidden; Settings can't.

**Lists are "groups"; there are no list screens** — only a chip row and a
sheet. `openList`, `GradientIconButton`, `SelectionBar` stay deleted. Tests
find a task by name with `taskNamed` (`test/support/test_db.dart`).

## Decisions worth keeping

### Calendar grid

- **Three states on one `AnimationController` in `[-1, 1]`**: week, compact
  month, opened month with titles. Drag on the grid, the strip under it or
  the day bar; a tap on the strip steps one state, turning at either end.
- **A fifth of the way commits; one drag moves one state at most**
  (`_dragBy`). **The snap is a glide, not a spring** (`_Glide`: cubic from
  the finger's speed, 460ms a full step, no overshoot; a flick sets start
  speed, capped 3×, not duration). Springs crept and overshot.
- **Day numbers at a fixed offset from the cell top** in every state.
- **Tasks are lines under the number, not dots**; holidays first, green.
- **Opened day chips**: title up to two lines measured with `TextPainter`
  (height rounded up); width overflow fades, height overflow is cut at the
  line (`didExceedMaxLines`). Inked, not painted (`dayChipColour`), ordinary
  text colour, tight (`_inset`/`_gap`), corners 3, `+N more` left.
- **Collapsing to the week slides rows past a shrinking window**: rows keep
  month height, each carried to its week place; the week row is a fifth
  taller (`MonthLayout.weekScale`). Week rules fade in only in the last
  quarter of opening (`weekRuleAlpha`).
- **The month is laid out once and only moved** (`MonthGrid.animation`,
  `_RenderRows`): rows at opened height, clipped, each a repaint boundary;
  outline and rules drawn by the render object; cells 1.4pt inset; the
  month pager outside the `AnimatedBuilder`.
- **Keep the drag cheap**: `Holidays.around` and chip heights cached; the
  day pager is the `AnimatedBuilder`'s `child`.
- **Today: tight near-square badge** in the number's colour (red Sunday,
  else light; ground text), text centred on digits (`Alignment(0, 0.2)`,
  `height: 1`). Selected day: thin neutral outline. No accent on either.
- **All day numbers semibold**, tightened (`letterSpacing`,
  `proportionalFigures`). **Only Sundays are red.**
- **Header**: controls (Search, Today) on top, month name alone below,
  centred, year only if not current, no chevrons on the phone. Today's
  button shows today's date.
- **Grid on the ground, day panel raised grey** (`calendar` vs `panel`);
  the day bar takes the panel's grey.

### Calendar pagers and day panel

- **Days below the grid are a pager, a page a day.** Within 42 days
  (`_passThrough`) a pick slides through; further, it comes in as the next
  page (`_dayAnchor`, `_heldPage`). Pagers ignore pages an animation passes
  (`_driving`); `_onMonthPageChanged` still owes the header a `setState`.
- **In the week, a sideways swipe turns a week** (`_weekController`,
  `_weekShown`), keeps the weekday, cuts the day panel. The month pager
  takes over off the week and during a carry.
- **A pick in the opened month opens a bottom sheet** (`day_sheet`): sized
  to the day up to 56%, dense cards (`TaskCard.dense`), no own overlay
  (`DragWithin.overlay`), lifted by `KeyboardGap`, drag down to close.
- **Hours view** (`DayHours`, `SettingsProvider.dayAsHours`, `_ViewSwitch`):
  untimed items on top, midnight-to-midnight timeline, overlaps side by
  side, red now-line, re-placed on change until the user scrolls. The day
  sheet stays a list. The day bar holds only the day's name and the switch.
- **The day's list scrolls only in the week state** (`_HeldScrollPhysics`,
  `_listHeld`); otherwise drags drive the grid. A drag that scrolled the
  list never opens the month (`_listScrolled`). An empty day has no list
  (`EmptyState.scrolls`).

### Tasks and cards

- **Timed tasks may have an end** (`Task.duration`, minutes), same day
  only, "15:00 – 16:30".
- **Cards are frosted glass** (`CardPane`, its own `Decoration`): 30% of
  the task's colour (`TaskCard.ink`), a 1.5pt rim at 56% (tick square
  outlined alike), a frost of one-pixel grain ~3.4% white ±1.5%
  (`assets/grain.png` from `tool/make_grain.py`, unfiltered, one
  `ImageShader` draw — a `BoxDecoration` image tiled every frame and lerped
  through a `saveLayer`). Coarser, blurred or bleeding grain read as noise;
  deeper ink as mud. Done: 9.45% ink, rim 18%, no frost. Holidays and
  phone events wear the same pane (`TaskCard.paneOf`); timed tasks use the
  same card. Debug sliders for ink, rim, frost.
- **A task may carry its own colour** (`Task.styleId`), else its group's;
  always resolve through `colorOfTask`. Moving group on the form resets it.
- **Palette: sixteen presets plus made colours** (`ListStyle.presets`,
  `ColourSelector`, `showCustomColourSheet`; `#RRGGBB` in `style_id`; six
  recent in `customColours`). First eight ids are the old ones
  (`ListStyle.freeFor`).
- **Ticking off** (`CheckMark`, `TaskProvider.settle/linger/leave/hold`,
  `TaskCard.ticking/leaving`): tick at once (240ms), crossed out 250ms
  later; a card that leaves its run fades 280ms, else holds 150ms and
  slides to the end of its day (`SlideIntoPlace`, 260ms). Schedule and
  Calendar behave identically (grouping made once per load, not in a
  getter).
- **A tick doesn't rebuild screens; only the read-back does**
  (`TaskProvider.ticked`, `shown`, `AsShown`). Settings and the tab bar
  `select` single values.
- **`SlideIntoPlace` slides by (screen, task id)**, noting positions in
  content space (`TaskProvider.rearranging`), finding the move in paint
  (`_RenderSlide`).
- **Undo for four seconds** (`tickOff`, `_UndoBar`, `UndoScope`,
  `UndoSlot`, `TaskProvider.restore` writes the old task back, never
  re-ticks): takes the add row's place at its size, field kept beneath;
  countdown a gradient across the bar (`_Countdown`), paused by holding;
  brushed off sideways/down (`UndoSlot._away`). Only Undo in the accent;
  no rings, lines or chips.
- **Order**: done after open, in tick order (`completed_at`); high priority
  leads an unarranged day; **hand placement (`sort_order`, null until
  dragged) is read before the date** (`_order`).
- **A "Done N" line parts a day's open tasks from its done ones**
  (`DoneDivider`; asked 2026-11-25: hard to tell done from open), only
  where both are there; Schedule, the day panel, the day sheet, Search.
  Open and done are two reorderable slivers, so the line is never carried
  with a card; placed by the list as read, so a ticking card crosses it
  only when it slides.
- **A repeating task ticked late rolls on to today or later**
  (`Task._nextRound`). **Repeat is a rule** (`Repeat`, `RepeatUnit`,
  `showRepeatSheet`): every N units, weekdays, month day or last day, end
  by date or count (`left`, `rolled`; `rollsOn` false on the last). Old
  five rules keep their names; richer ones are an RRULE-like string.
- **Checklist** (`Subtask`, JSON in the task row) so Undo and roll-on carry
  it; "☑ 2/5" pill opens steps. **Open steps hold back the card's first
  tick** (`_WithChecklist._tick` shakes and opens them); other tick paths
  don't. Search filters the JSON in Dart. The form calls it Checklist
  ("Add a step"), apart from subtasks.
- **Subtasks are tasks under a task** (asked for 2026-11-25 in place of
  subprojects: "every task can have subtasks … each subtask has context of
  parent task"): `Task.parentId`, schema v17, any depth; its own day,
  colour, tick and agent. Synced as `parent_uuid` (`SyncStore._links`),
  linked after the whole pull, since a parent edited later comes down
  after its subtask. Deleting a task deletes its subtasks (`deleteAll`, a
  recursive CTE; the MCP's `delete_task` too); a parent deleted elsewhere
  leaves the subtask standing alone. `TaskProvider` keeps every task with
  a parent or a child (`getFamilies`, read with the agenda) for the card's
  "↳ parent" and the form's "Part of" line and SUBTASKS panel (existing
  tasks only; Add opens a new form with `parent`, in the parent's group).
  **An agent sent a subtask is told its parents first** (`taskMessage`'s
  `parents`, outermost first: title, due, notes, checklist), from the app
  and from the worker (`Book.parentsOf`). The MCP's `add_task` takes
  `parent`; `task` names both ways.
- **Attachments** (`Attachment` JSON, `Attachments`, `Attachments.kt`,
  `AttachmentsField`): Photo (picker, images only), Camera, File; copied to
  `files/attachments/<uuid>/<name>`; >100MB refused; opened through a
  `FileProvider` for that directory only. `Attachments.sweep` on start
  removes unreferenced copies older than an hour. No camera permission, on
  purpose.
- **Holidays are not tasks**: computed, read-only, country from locale or
  Settings.
- **Special days** (`SpecialDay`, `special_days`, synced and backed up):
  month, day, optional year ("turns 30", `S.specialLine`), kind (birthday,
  anniversary, other), colour, remind on the day. They ride the holidays'
  path as a `Holiday` with `special` set (`TaskProvider.daysAround`, cached)
  after the public ones, everywhere holidays show; Schedule shows a day
  holding only one (`specialDaysBetween`). Card tap opens
  `showSpecialDaySheet` (`DayWheels`, "—" for no year). Listed in Settings ›
  Calendar › Special days. Feb 29 falls on the 28th. Read at start, after a
  sync or restore, and on their own changes — not on every agenda read.
  Alarms: id `Reminders.specialBase` + id, all-day hour, no buttons, not
  full screen. Not on the widget.
- **"Show completed" applies wherever a run is drawn**
  (`TaskProvider.setShowCompleted`); `allUpcomingByDay` keeps them.
- **In-progress tasks show `InProgressBadge` on every card.**

### Moving, selecting, putting off

- **Long press picks a card up** (no handles); released within 18pt it is
  selected instead (`Selection.lifted`).
- **Selection** (`Selection`, `SelectionScope`, `SelectionSlot`,
  `moveAllToDay/moveAllToGroup/setAllDone/removeAll`): taps toggle while
  any is picked; lifted colour rim (`foregroundDecoration`) and glow. The
  add row becomes Move to day / Move to group / Mark done / Send to agents
  (signed in only; see Agents) / Delete (asks).
  One selection across scopes; Back, group change, screen change put it
  down. Not on the board. `ClipRect` only while leaving.
- **Swipe left on Schedule or under the calendar puts off** (`PutOff`,
  `offerUndo`, `TaskProvider.putBack`): part way shows Next day / Pick day
  and, signed in, Agent (asked for, 2026-11-25: "wanna with swipe in
  calendar and schedule"); past 55% or a fling does Next day. Not done
  cards, not during selection. Under the calendar only a swipe that sets
  off leftwards is the card's (`leftOnly`, `_Leftwards`): one rightwards
  still turns back a day over a card. Not in the day sheet.
- **Carrying a card to another day moves it** (`Carry`, `CarryArea`,
  `CarryMark`, `moveToDay`), keeping its time, clearing `sort_order`.
  Schedule: drop in any run but Overdue. Calendar: over the month it is a
  free day-sized tile (`_ShrinkingCard`, `Carry.shrinkTo`, `_AtFinger`,
  rounded 14, light rim), not snapped; the outline names the day; holding
  at a side turns the month (`_watchEdges`, `_turn`, 600ms then 900ms) with
  neutral tabs (`_EdgeHints`). Dropped by a `Listener` calling
  `cancelReorder`. Grid and carry share one `MonthLayout`. Holidays can't
  be moved.
- **A carried card is penned in its screen** (`DragWithin`, `_KeepInside`),
  held at the edge, not clipped; pens anchor to undraggable rows; keys
  belong to the state. **It's the card alone** (`liftedCard`): ground
  colour in its own corners, slight scale, no `Material` slab.
- **Schedule is a heading + reorderable sliver per run** (`_RunOfDays`,
  `_Run`), as is the day panel — one lazy scroll.

### Schedule, Search, Done, Board

- **Schedule is a running order of days**: plain dates, same cards,
  holidays among them; `Today` pill, Overdue red, No date. Header: Search,
  Today.
- **Search** lays results out like Schedule (Overdue, upcoming, No date,
  past latest first).
- **Lists are re-read when the date changes** (`TaskProvider.catchUp`, on
  resume and at midnight).
- **Done is a log of ticks** (`completions`; every tick path goes through
  `AppDatabase.complete`/`untick`). Three figures, seven bars, neutral;
  reads only while shown.
- **Board**: Not started / In progress (`started_at`) / Done (`BoardScreen`,
  `Stage`, `moveToStage`, `Task.toStage`), drawn like Jira: grey lanes,
  small-caps headers with counts, flat neutral cards, colour square, group
  and date lozenges (red when past), priority chevrons, no key
  (`BoardCard.showKey`). A lane is most of the screen (`laneFraction`),
  snapping to three places (`_LaneSnap`), all built. Pick-up after 300ms,
  carried at size (`_Lifted`), not tilted; outer 18% (`_Board.edge`) turns
  at once, then every 900ms. No move button, no drop bar. Plus in header.

### Groups

- **One group per task; Schedule and Calendar can show one group**
  (`GroupChips`, `TaskProvider.showGroup`). Tags were removed. Chip row
  (All, groups, plus) always shown; long press carries a chip to reorder
  (`lists.sort_order`), released in place opens it to edit; carried on
  `GroupChips.ground`. On Schedule the row is part of the glass head
  (`GroupChipsOnGlass`, `GlassTop`, `GlassTop.fade` 0, glass ends square).
  **Chips are solid**: chosen one the field's grey, the rest the ground
  with a hairline (`onGlass`).
- **Default group is the oldest** (`TaskList.oldest`), never deletable;
  deleting another moves its tasks there.
- With a group chosen: its tasks only, no phone events, holidays stay, new
  tasks go into it; not stored. Alarms, widget and overdue dot use full
  lists (`allOverdue`, `allUpcomingByDay`). **A group's colour is its
  tasks' colour.**
- **The open add field offers groups**: a chip on its second row opening a
  list above it (`_GroupButton`, `_Popup` — an `OverlayPortal` inside a
  `TextFieldTapRegion`, so the keyboard stays), reset each opening to the
  shown group (`groupForNew`), else the default.

### Shell, navigation

- **Start screen is a setting** (`AppScreen`), read in `main` before the
  first frame, never waiting for `SettingsProvider.load`.
- **Hidden screens** (`hiddenScreens`): never all; start falls back to the
  first visible, the choice kept. Overdue dot on Tasks, or Calendar if
  Schedule is hidden. Hidden screens still build.
- **Five tabs, no menu.** Schedule, Board, Done are views under **Tasks**
  (`taskViews`, `TaskViews`, `_tasksTab`, reopens `_lastView`); headers
  write all three names, the current lit, others dimmed and tappable
  (`ViewTitles`, `ScreenHeader.view`). One view left: a plain title. The
  side menu was removed.
- **The bar** (`_TabBar`, `_Tab`, `BarRoom`): floating pill, 1.4pt light
  rim, 23pt from the sides (`BarRoom.tabsSide`), icon over name, neutral
  grey pill slides to the current tab (240ms), names shrink not cut.
  Frosted (blur 17, fill 60%) on `_BarGround`: the bar's grey (`p.panelHi`)
  from clear to 80% at the foot, run on under the gesture bar (`below`).
- **Backdrop filters are expensive**: each reads the screen and adds
  passes; measure with `showPerformanceOverlay` on a profile build (or the
  emulator with `-gpu swiftshader_indirect`) before adding one. Impeller's
  second backdrop pass reads the original screen, not the first pass's
  output; a `ShaderMask` over a blur draws nothing. `FadingBlur`
  (`shaders/fading_blur.frag`, screen coordinates, flipped on GLES) blurs
  each row by its own amount. The head's bands and its `FadingBlur` share
  one `BackdropGroup` (`_Glass`), as do the bar and plus.
- **Every screen runs on under the bar**: scrolls end with
  `BarRoom.of(context)`; Schedule and the calendar rest their field over
  their foot (`FieldInBarRoom`). The calendar sizes its grid to what the bar
  leaves; opening, the month runs on under the bar and pushes the day off.
- **Screens not on show are under `TickerMode` off** (`_behind`), or their
  tickers hold the app at 60fps.
- Back goes to the start screen before leaving (`Selection.anyActive`
  first). Tasks' icon is drawn (`_TasksGlyph`): checklist, purple tick over
  a ring — the bar's one colour, dimmer unlit.
- **Every screen's top is glass over what scrolls under it** (`GlassTop`,
  `HeadRoom`, `widgets/glass.dart`): Schedule, Done, Vault, Settings run up
  under the status bar; the head on blur 17 under the ground at 65%,
  thinning over its foot (`GlassTop.leadOf`, 16–44pt): four `GradedBlur`
  bands 2–17 then a `FadingBlur` to none. Scrolls start with
  `HeadRoom.of(context)`. The shell's `SafeArea` leaves the top to the
  screens; Board and the calendar take it themselves. The wide layout keeps
  the head above the body.
- **While the keys are up the bar is drawn at alpha 1/255, not left out**
  (`_WhileKeyboardDown._faint`): bringing its blurs back cost a long frame.
- **A 56pt round plus floats above the bar's right end** on Schedule and
  Calendar (`_AddButton`, `BarFoot`, `_WhileWriting`, `_WhileKeyboardDown`):
  tap opens the field, hold the full form. Undo and selection take the
  bar's place; `withdrawUndo` on screen change.
- **Settings is pages** (`_Page`: Screens, General, Appearance, Calendar,
  Tasks, Reminders, Sync, Backup; About on the list), rows like the phone's
  settings (`_Group`, `_Row`, `_SwitchRow`, `choose`). Clear completed is
  the one red row.

### Keyboard and the add field (read before touching)

- **Nothing moves when the keyboard does**: no `Scaffold` resizes;
  `SafeArea(maintainBottomViewPadding, top: false)` in the shell;
  `KeyboardGap` subtracts the kept strip.
- **The quick-add bar is attached to the keyboard** (`KeyboardLift`
  translates it, same frame). **No curve, spring or cap.**
- **In the bar's room, Android carries the field on the keys**
  (`KeysCarry`, `KeysCarry.kt`, `CarriedField`, `FieldCarry`): Flutter's
  surface and the IME window reach the screen a frame apart as often as
  not, so no Dart timing glues them. Dart sends a picture of the field
  (`toImageSync`, raw RGBA) whenever it changes while up, with where it
  rests; a native view draws it at the keys' top from `onProgress`.
  `onPrepare` puts it up and tells Dart (`carry`); Dart leaves its copy
  undrawn (`KeyboardGap.carried`), draws again at rest, says `drawn`; the
  picture goes three frames later. Closing, it goes three frames after the
  field reaches the foot (`park`). The plus first draws the field open and
  pictures it (`FieldCarry.raise`, `KeyboardGap.raising`), then asks for
  the keys. A filing tick `drop`s the picture. Recordings take the
  display's strip over it (`covers`). Everything else on the keys rides
  the clock below.
- **Keyboard height is the larger of `viewInsets` and Android's report**
  (`KeyboardGap.of`, `MainActivity`): `Type.ime()` from the display bottom
  minus what lies below the window. Don't correct `viewInsets`
  arithmetically — its meaning changes mid-slide.
- **In a slide the field is read off the slide's own clock**
  (`MainActivity.clockOf`, `_Slide`, `KeyboardGap.take`): Android sends the
  slide's position at a vsync, the frame period, length and curve; Dart
  reads it at `currentSystemFrameTimeStamp` less a period (that stamp is
  the vsync the frame is shown at). Reports only correct the clock
  (following them lands a frame behind); a report at fraction 0 is taken to
  start a frame later. A slide with no curve is carried on from its last
  two reports (`_Trail`, ≤1.5 frames). Leads in Settings › Debug ›
  Keyboard (`Tweaks.keysLeadOpen/Close`, 0 shipped). Judge on the phone;
  the emulator trails a frame. Line a recording's `reach` up against
  `insets`.
- **Edge-to-edge is read from the content view's insets, never its
  height** (`MainActivity.contentNav`).
- **A tick on an empty field behaves like cancel** (`QuickAddBar._submit`):
  keyboard goes, focus stays, so the next opening keeps its IME connection.
- **Only `KeyboardLift`, `KeyboardRoom`, `QuickAddBar`'s frame,
  `FieldInBarRoom` (and `CarriedField`, after the frame) read the inset.**
- **Long-press the Settings title for keyboard numbers**
  (`KeyboardGap.showNumbers`, `KeyboardNumbers`). Debug, English only.
- **In the bar's room the field stands on a plain tint** of `p.field`,
  across the field's own room only: clear at its top, 80% at the keys;
  part of the carried picture (`CarriedField.above`). Without the bar
  (`foot == 0`) the field has its ground and fade from what is under it
  (`_groundUnderField`, `_fadeStrength`, `_overGrid`; `GroundFade`, 48pt).
  Schedule pads its end with `KeyboardRoom`.
- **Field and its button are filled `AppPalette.field` with the bar's
  rim** (`BarRoom.rim`); focus shows only the caret. Plus → tick when open,
  plain. Plus opens the full form.
- **Open with the keys up, the field is two rows**: title; then attach
  (`_AttachButton`, a paperclip once something is), the group chip, the ✦
  chip, the tick at the right. Keys down, it folds to one row. After a
  picker the keyboard is asked back once resumed (`_whenInFront`).

### Forms and pickers

- **Date/time pickers are our own sheets** (month grid, wheels); no
  Material dialog or dial.
- **Clock wheels**: no band behind the middle — a `ShaderMask` gives full
  strength one row high, a third outside. The touched wheel turns accent on
  pointer down, white on up. `diameterRatio: 100`.
- **One clock everywhere, chosen in Settings** (`Dates.time`/`Dates.clock`,
  `h24`; `MediaQuery.alwaysUse24HourFormatOf`; `Dates.use24Hour` for
  notifications; `Reminders.refresh` on change).
- **Task form**: back arrow hides once anything is touched; Cancel/Save
  pinned at the foot over `GroundFade`, riding `KeyboardLift`;
  `KeyboardRoom` below the list, `_reveal` keeps fields clear. Save/Cancel
  dismiss the keyboard.
- **Sheet actions are two plain words, Cancel and Save, towards the
  middle.**
- **Reminder lead** (`Task.remindBefore`, `reminderLead`, `_ReminderField`,
  `Dates.lead`, `dayLeads`): null follows Settings, `Task.silent` never;
  all-day tasks whole days only; a row opening a choice sheet.

### Look

- **Platform font**, not Inter/google_fonts.
- **Near-black ground (`#111112`), not true black**, shared by calendar,
  widget, reminder cover and system bars (`_barsOn`); neutral greys.
- **Controls are neutral; accent is rare**: switches, Undo, update prompt,
  touched clock wheel, colour pickers. Tasks wear their own colour.
- **Settings › Debug, admins only** (`Tweaks`, `theme/tweaks.dart`,
  `settings_debug.dart`, a `part` of settings; English only): every
  `AppPalette` colour per theme, the accent's three, the four signals
  (`AppColors.danger/overdue/weekend/holiday` are getters for it), card,
  done-card and chip ink as multipliers. Live while picked, kept on Save,
  in force only while its switch is on; device-only (prefs `debug_tweaks`,
  not backed up); signing out turns it off. Copy hands them over as JSON.
  Native surfaces don't follow.
- **Performance numbers** (`PerfHud`, over everything in
  `MaterialApp.builder`; Debug switches, not stored): fps against the
  display's rate, frames over budget, tickers, build/raster avg/max
  (engine timings, ~1s batches), CPU of process/UI/raster threads from
  `/proc`, RSS, free memory, GPU and temperature where sysfs allows.
  Draggable, starts above the bar. Greyed while Debug mode is off
  (`PerfHud.graphsDrawn`). Idle should read 1 fps and 0 tickers.
- **Recording of Caldo and its keyboard only** (Debug › Recording;
  `Recording`, `RecordingOverlay`, `ScreenRecord.kt` + `RecordService`;
  Android only). The app is `PixelCopy` of Flutter's `SurfaceView`; the
  keyboard comes from MediaProjection (whole display, consent each time, a
  `mediaProjection` foreground service with Stop), and only the IME's
  strip of it (its full height while sliding, `MainActivity.keysSliding`)
  is laid over the app's copy, only while Caldo has focus — nothing else
  of the screen reaches the video. MediaCodec, MP4, ≤1280, ≤30fps, no
  sound, ≤5 min, one kept in `cache/recordings`. Frames only after Dart
  pings `drew`, and 80ms after. A `.log.jsonl` on the video's clock (`t`
  ms; `Timeline.now`): touches, frame timings, HUD numbers, insets,
  routes, lifecycle, errors, `debugPrint`, marks. Rings under fingers, a
  draggable badge (time, mark, stop). A record button on every screen
  (prefs `record_button`, Debug mode only): red dot at the right edge,
  42% height. Back out ends and keeps the recording; Stop shares it
  (`FileProvider` serves `recordings/`). Read with `tool/recording.py <log>
  [--frames s…] [--slow N] [--between a b]`.

### Reminders

- **Alarms are rebuilt from the agenda in `TaskProvider.loadTasks`**
  (`services/reminders.dart`): first sync of a run resets all, later ones
  diff (`Reminders._standing`), after the lists are on screen. All-day at
  the Settings hour (default 9), timed at their time. A setting change
  re-sets standing alarms (`Reminders.configure`).
- **Reminders no-op until `init`** (only from `main`) — keeps tests quiet.
- **Permission asked on first run** from `SettingsProvider.load`. Exact
  alarms (`USE_EXACT_ALARM`), inexact fallback.
- **Buttons: Done, Snooze 15 min, Dismiss** (`Reminders.done/snoozes/
  dismissed`, `onReminderAction`); the hour's snooze on the full-screen
  page only.
- **Full-screen only when locked** (`fullScreenIntent`, `ReminderCover.kt`,
  `MainActivity.wakeFor`): native, opaque (keep it so; don't hide
  Flutter's view under it), glow in the task's colour, `RenderEffect`
  blur. Switch on the Reminders page; `_FullScreenBanner` if not allowed.
  Try: `am start -n com.igor.caldo/.MainActivity -a SELECT_NOTIFICATION
  --ei notificationId 999 --es payload '{"title":…}'` on a locked emulator.
- **Buttons are handled on the plugin's isolate** (`Background._change`):
  write, `Reminders.reset` for that task only, redraw widget, ping the app
  (`IsolateNameServer`, `Background.listen`). Snooze stored
  (`snoozed_until`). Alarms cover the overdue run.
  **`ActionBroadcastReceiver` is declared in the manifest by hand.**

### Home-screen widget

- **It is Schedule in small** (`TodayWidget.kt`, `TodayWidgetRuns.kt`):
  runs, inked cards, working tick, tap opens the form, plus a new task;
  always dark.
- Reads a copy of the agenda (`TodayWidget.publish`), sorted at draw time.
  **Nobody tells it to redraw**: `CaldoApplication` listens to the
  preferences. Ticks run Dart on one process-wide engine (`Headless`,
  `widgetMain`).
- **Android 12+**: each tick a real `CheckBox` with an `animated-selector`
  per swatch (`layout-v31/widget_task_<swatch>.xml`, from
  `tool/make_widget_ticks.py` — rerun after changing a swatch);
  `saveEnabled="false"` (without it every task ticked). The page is one
  frame (`layout/widget_page.xml`) of stable-keyed views placed by top
  margins, never stacked, in a one-row inline `ListView`
  (`RemoteCollectionItems`). Heights measured in process (`fit`), cached;
  ≤60 cards (`MOST`).
- **A tick plays as in the app** (`TodayWidget.tick`): `SETTLE` 490ms,
  `HOLD` 150ms, slide 260ms (`stateListAnimator`/`translationY`,
  `animator/widget_*.xml`), leaving cards fade. Moves from
  `TodayWidget.last`; Dart writes after the card has gone;
  `Background.toggle(done:)` writes the box's state.
- **Phone events show too** (`PhoneEvents.kt`, `layout/widget_event.xml`),
  read by the widget; keys from 1e9; shown per `SettingsProvider.storedEvents`.
- **Its cards are the app's glass**: ink 30%/9.45% done, 1.5dp rim at
  56%/17.6% (`widget_rim`, tinted from code; its clear `<solid>` is
  load-bearing), grain at 0.0682 (`widget_grain`, tiled, unfiltered, in a
  1dp `layer-list` item, gravity fill), clipped by `clipToOutline` on
  `widget_pane`; no grain before Android 12. If the app's card numbers
  change, change `animator/widget_{ink,rim,grain}.xml`, `INK`/`RIM` and
  `make_widget_ticks.py`'s `RIM`.
- **It wakes itself when the clock changes what it shows**
  (`TodayWidget.wake`, `TodayWidgetRuns.nextLate`): midnight, or a task of
  today's coming due. Exact where allowed, non-waking.

### Phone calendars, language, updates, backup

- **Phone events sit beside tasks like holidays** (`EventsProvider`,
  `DeviceCalendars`, `EventCard`, `caldo/calendars`): opt-in, read-only,
  calendars stored as excluded ones; all-day events read in UTC
  (`events_test.dart` passes under `TZ=America/Los_Angeles`). Screens read
  the provider as nullable.
- **Twelve languages** (`S`, `l10n/strings.dart`, `words_*.dart`; missing
  keys fall back to English; `l10n_test.dart` checks keys and `{blanks}`).
  Plural rule per family. `S.of(context)` on screens, `S.current`
  elsewhere (`SettingsProvider.prime` on isolates). English keeps fixed
  patterns; others use `intl` skeletons, capitalised. Kotlin uses
  `getBestDateTimePattern` and `values-xx/strings.xml`.
  `l10n_screens_test.dart` draws key screens in every language.
- **Updates** (`services/updates.dart`, `widgets/update_prompt.dart`,
  `caldo/updates`, `SelfUpdate.kt`): GitHub's releases vs installed
  (`Updates.pick`), the newest offered with every skipped release's notes.
  A centered modal (`UpdatePrompt`) blurs the current screen and opens
  with What's new (`New:`/`- ` lines) and Later + Update. Looked for on
  start and resume, at most once a minute (`Updates.look`). **Later**
  hides it until restart; Settings › About can reopen it. **Notes holding
  `<!-- priority: high -->` make it urgent**: `UpdateWall` takes the
  navigator's place until installed (no Later; Back leaves), kept in prefs
  (`updateUrgent`), dropped when GitHub has nothing newer. Installs the
  ABI's APK through Caldo's own `PackageInstaller` session; ends on the
  home screen with an `UpdateDone` notification. The repo is public, so no
  token. No `taskAffinity=""` (it
  made two Caldos). Nothing checks until `Updates.enable`. To test: `adb
  root`, install a lower build, drop the target as
  `cache/updates/Caldo-<latest>.apk` (chowned).
- **Backup** (`Backup`, `AppDatabase.dump/replaceAll`,
  `SettingsProvider.exported/restore`, `caldo/backup`): JSON of raw rows +
  schema version (newer refused), one transaction, settings but not phone
  calendars, ≤64MB, restore previews. **Auto backup** (`Backup.autoIfDue`)
  to a persisted folder on open/resume when due, last seven
  `caldo-auto-*` kept.

### Sync

- **Groundwork** (`AppDatabase._addSync`): every row has `uuid`,
  `updated_at`, `dirty`; deletions go to `tombstones`. **Integer ids stay**
  (alarms, widget, screens). **Triggers stamp, not writes**; suppressed
  while `sync_state.applying`. One `defaultListUuid`.
- **A round pushes then pulls** (`Sync`, `SyncStore`); a pulled row loses
  to a newer local change; rows marked sent only as sent; cursor written
  with the rows; another account marks everything dirty. Tested with
  `FakeServer`, `AppDatabase.named` (`sync_test.dart`).
- **Server: Supabase Cloud free tier** (project `eqgczddzmvmczwcgbenr`,
  URL and publishable key in `Account`); a device can be pointed at a
  local Supabase in Settings (demo key); cleartext only to local addresses
  (`res/xml/network_security.xml`). Plain `supabase` package. Session in
  preferences, renewed without holding the first frame. Rounds on open,
  resume, `Sync.soon` (2s after a read-back), realtime, every 5 min.
- **A round twice a day with the app closed** (`DailySync.kt`,
  WorkManager, booked over `caldo/sync`), run by whichever engine holds
  the session — the app's if alive, else the widget's `Headless`
  (`Background.sync`, `Account.syncOnce`): two engines renewing one
  session spend its refresh token twice and Supabase ends it. Pulled tasks
  get alarms one by one (`SyncStore.touchedTasks`). Not on Linux. To try:
  move the emulator clock 13h on (`adb root`), `cmd jobscheduler run -f -n
  androidx.work.systemjobscheduler com.igor.caldo <id>`.
- **Sign-in is a username and password; accounts by invite only**
  (`Account.signIn`/`join`, `showSignInSheet`/`showJoinSheet`,
  `…_invites.sql`). A name is kept as `name@caldo.invalid`
  (`Account.loginOf`/`nameIn`). Auth's `before_user_created` hook refuses
  an account without an unused invite; a trigger spends it. Rows in
  `public.admins` may `make_invite()` (Invite someone in Settings;
  `Account.admin`, asked at sign-in and each round until yes). One
  account per invite, no expiry, sent as `caldo://invite/<code>` (handed
  over on the widget's launch channel; Flutter deep linking off); pasted
  into Join on Linux. No password reset but by an admin.
- **All-day tasks travel as a day** (`SyncStore._toDay`/`_fromDay`); timed
  ones as instants.
- **Attachment files travel after the rows** (`FileSync.carry`,
  `FileStore`, `Account._Files`, bucket `attachments`): a pass after each
  round (`Sync._carry`) compares the server's list with the files named
  here, up what is missing there, down what is missing here (`.part`, then
  renamed). Key is the copy's folder uuid under `<user id>/`; others are
  ignored (`FileSync.keyOf`). >50MB stays put. A file no task names leaves
  the server a day later. Deleting the account removes the files first.

### Vault

Secrets inside Caldo, synced end-to-end encrypted, fingerprint with a
master password behind it.

- **Two layers of key** (`VaultProvider`, `Sealing`): a random 32-byte
  vault key seals each secret (AES-256-GCM, fresh nonce, row uuid as
  associated data); the master password (Argon2id, `Kdf.strong` 64 MiB ×3,
  on an isolate) seals the vault key, setting stored per key. A new
  password re-wraps the same key. pointycastle, pure Dart.
- **Tables `vault_keys` and `secrets`** (`_addVault`, stamped via
  `_stamp`); everything typed, the name too, in one box (`Secret.seal`).
  Synced and backed up as is; a backup from before leaves the vault alone
  (`_vaultTables`).
- **Two vaults made apart become one**: unlocking opens every key the
  password opens and moves secrets to the oldest (`_merge`); a key under
  another password waits (`sealedElsewhere`, `showOtherPassword`). Signed
  in with no vault, the screen syncs first (`looking`).
- **Fingerprint** (`Vault.kt`, `caldo/vault`): Android's `BiometricPrompt`
  (not AndroidX — Flutter's activity isn't a FragmentActivity), API 28+. A
  Keystore AES key, auth per use, invalidated by new enrolment ("gone" →
  password). It seals a copy of the vault key in prefs (`vault_finger`,
  never exported or synced); `proof` checks it is this vault's. Asked for
  when the screen comes on show locked.
- **Locks after `lockAfter` minutes away** (default 1; 0 = at once); the
  prompt's pause (`asking`) doesn't count. `FLAG_SECURE` only while open
  and on show — emulator screenshots of it are black on purpose; look on
  Linux.
- **Copy** marks the clip sensitive and takes it back after 30s if still
  ours (`VaultDevice.copy/clearCopied`, re-asked on resume).
- Forgot the password: Delete vault on the locked page. No recovery.

### Agents

A tab of chats with agents on the user's computers (workers): model,
effort, folder, plugins, skills, rules; Claude and Codex as chats drawn by
the app, a terminal beside them; anything else a terminal.

- **Claude and Codex are chats drawn by the app** (`Talk`,
  `lib/mcp/talk.dart`; `TalkView`, `MarkdownText`). Claude: `claude -p
  --input-format stream-json --output-format stream-json --verbose
  --include-partial-messages --permission-prompt-tool stdio`, one process
  for many turns; permission questions come as `can_use_tool` control
  requests (allow/deny; "always" passes `permission_suggestions` back).
  Codex: `codex app-server` (JSON-RPC `thread/start|resume`, `turn/start`,
  approvals as server requests; written from its `generate-ts` types,
  never run here). Both emit the same items (`TalkSink`): user, text,
  thinking, tool (one line; opened, detail and output cut at 4000), ask,
  note. Shell and `agents.json` agents are terminals only.
- **Claude's AskUserQuestion is answered, not allowed** (asked as "ask
  question in chat mode works bad", 2026-11-22): it comes as a
  `can_use_tool` request in every permission mode; allowed as it came,
  Claude heard nothing was chosen. The ask item carries the questions
  (`questionsOf`), drawn as options to tap, one or any, plus Other…
  (`_Questions`); Answer sends `updatedInput` with `answers` by each
  question's words, several joined with ", " (`claudeVerdict`; tried on
  Claude itself). The app writes `answer <item> <json>` (`answerOf`); a
  worker from before reads that as no item and lets it be; Allow from an
  app from before is told to Claude as "ask in plain words". No tool
  line for it: the question is its record. Codex has nothing like it here.
- **Codex is answered with what its question offers** (asked as
  "permissions for codex agents doesnt work", 2026-11-26; `codexVerdict`):
  codex-cli 0.172 lists `availableDecisions` without `acceptForSession`
  or `decline`; told those anyway it ran the command once and asked at the
  next. "Always" is then its proposed prefix rule, "deny" a cancel. Its
  `item/permissions/requestApproval` (network, folders) is asked, not
  refused. Full access or never chosen mid-turn answers what waits and
  what comes for the rest of the turn (`Talk.retuned`); the program is
  still put by after it, as before.
- **One program holds a session at a time** (`chats.mode`): the head's
  Chat/Terminal switch shows either side; the side not holding it offers
  the move (`chat_in` `mode`). To the terminal: resumed in tmux (`claude
  --resume`, `codex resume`); back: what was said there is read from
  Claude's transcript after the move (`claudeTranscript`,
  `WorkerState.marks`) or Codex's resumed thread.
- **Live things go by broadcast** on the chat's private channel
  `chat:<id>` (RLS on `realtime.messages`; a broadcast lands in 1–5ms, a
  row in 36–460ms). The worker broadcasts answer pieces (every 40ms),
  items and state, and keeps items as `chat_items` rows (upserted by id);
  the app broadcasts its input and inserts it into `chat_in` with the same
  `key`, taken once (`Worker._keys`). The user's words show at once
  (`TalkFeed.said`, id `u<key>`). Copy a broadcast payload before sending:
  the client writes `type`/`event` into the map.
- **A chat's program outlives the worker** (`Kept`, `lib/mcp/kept.dart`):
  detached behind a shell holding its input, a named pipe, open read-write;
  output, errors, pids, exit status and what was written (`.written`) are
  files under `~/.cache/caldo/chats/<chat>.talk.*`. The worker reads output
  every 30ms and saves offsets each second (`worker.json` `talks`); a new
  worker re-reads what was unheard (`Talk.takeUp`, `_Replay`) to rebuild
  open questions and tools, then goes on live. Items keep their seq. Dart
  can't append to a pipe: open it `FileMode.write`. A program is given 30s
  to come up (`Kept.startWithin`); given up on, its process group and
  scope are killed, or the next message starts a second on its session.
  NULs are taken out of items and terminal output (`withoutNul`,
  `_NoNul`): Postgres refuses them, and the row was retried for ever. A program killed with
  the session is noted "ended from outside"; the next message resumes.
  A message chat with a resumable session releases its agent after five
  quiet minutes between turns and resumes it on the next message.
- **Terminals go by broadcast too**: keys and lines on `chat:<id>` beside
  their row; the worker broadcasts output every 50ms (`_castOut`, `out`)
  as well as `chat_out` rows (the record). Pieces name their run (`life`),
  row `seq`/`start` and `at`, so `TermOrder` draws each stretch once. One
  channel per chat for both feeds (`Agents._hold`): of two joins to one
  topic from one socket the server keeps the later. xterm tells themes and
  styles apart by identity, so the screen keeps both (`_theme`,
  `_TermFont.style`).
- **Usage under the chat's head** (`ChatUsage`, `lib/mcp/usage.dart`;
  `ChatUsageStrip`, `showChatUsage`): context filled, account limits,
  cost; a tap opens tokens, turns, time, model. A talk reports figures as
  they are (`set`) or as added (`add`); the worker sums adds into the
  chat's totals (`_Talker.usage`), since a program's totals restart with
  it. Claude's `total_cost_usd`, `modelUsage`, `duration_api_ms` are the
  program's running totals; `usage`, `duration_ms`, `num_turns` the
  turn's. Context is the last main request's in + cache + out (not a
  helper's, with `parent_tool_use_id`). Limits from `rate_limit_event`'s
  `unifiedWindows`; Codex's from `account/rateLimits/updated`, tokens from
  `thread/tokenUsage/updated` (the first adds only `last`). Broadcast on
  change; written to `chats.usage` only at a turn's end or 20s into a long
  one (every row write has each app re-read the list). Red from 95%,
  brighter from 80%. Terminal turns aren't counted.
- **Accounts** (asked 2026-11-23: "i dont like i see non updated usage",
  and Claude/Codex accounts to list with their usage and pick for a chat;
  `agent_accounts`, `…_agent_accounts.sql`; `AgentLogins`,
  `lib/mcp/accounts.dart`; `Worker._tendAccounts`; `AccountsScreen`,
  `agent_accounts.dart`, a `part` of the agents screen). Limits are the
  account's, not the chat's: the worker reads them every 2 min (Claude:
  `GET api.anthropic.com/api/oauth/usage` with the login's token, as
  `/usage` does, ~0.8s, no turn; an expired token is left for Claude to
  renew, as two renewers spend a refresh token twice; Codex: its app
  server's `account/rateLimits/read` every 5 min, written from the
  protocol, not run here) and whenever a chat hears them
  (`_heardLimits`, merged by window). The strip shows the account's
  (`withLimitsOf`); a limit past its reset reads 0% (`usedNow`). Each
  worker's own login is a `main` row; others live in
  `~/.config/caldo/mcp/accounts/<id>` as `CLAUDE_CONFIG_DIR`/`CODEX_HOME`,
  every entry of `~/.claude`/`~/.codex` but the login linked in
  (`mirror`; `~/.claude.json` copied once less `oauthAccount`), so
  plugins, skills and sessions are shared and a chat can change account in
  its settings and carry its session on. Started as `env VAR=… claude …`
  (`_envOf`, `Talk.env`). Sign-in runs `claude auth login` /
  `codex login --device-auth` in tmux (`login-<id>`, 500 wide so the link
  isn't wrapped); the link (Claude's printed after ~0.5s) and Codex's code
  go on the row, the code Claude's page gives comes back as `login_code`,
  typed in and cleared. A wrong code ends it `failed` with Claude's words.
  Removed: `claude auth logout`, links deleted, then the folder. Tried on
  the local stack with this machine's own Claude login.
- **The chat list is one forward list that follows the foot** while the
  reader is there (`_follow`); a reader scrolled up is left alone.
- **A swipe over the terminal is sent as the wheel** (`TermSwipe`):
  xterm.dart drops touch drags in the alternate screen; a notch a line,
  arrows if the program hasn't asked for the mouse. xterm.dart 4.0 numbers
  the wheel 68–71; `TermSwipe.wheelFixed` makes it 64–67. A snapshot
  restores the program's modes (`Tmux.modes`).
- **A real terminal**: a program in a tmux session on the worker (`Tmux`,
  `tmux -L caldo -f /dev/null`, session `c<uuid without dashes>`), raw
  output piped to a file (`pipe-pane -O`), read every 50ms; keys as bytes
  (`send-keys -H`). A typed line is pasted (`paste-buffer -p`) and Enter
  sent 150ms later (Claude takes both in one write as a paste). The
  program waits on a flag file until the pipe is in place. tmux answers
  terminal queries; the app's xterm must not (`_drawing`). `TermCleaner`
  strips `ESC [ <>=…` requests.
- **A chat is Ready, Working, Waiting for you or Finished** (asked as "i
  dont see when chat definetly finished work", 2026-11-24): `idle` is
  only a chat that has done nothing yet (a ring); a turn's end — a
  result, Codex's turn completed, Claude's Stop hook in the terminal —
  writes `finished` (a tick, `_StateMark`), so a finished chat is told by
  its shape, not a shade. **The usage limit is `limited`** (an hourglass,
  "Out of usage", and under it which limit and when it resets,
  `limitBrief`, from the chat's usage — not the worker's English note;
  asked 2026-11-25). All take a message (`Chat.live`, `Worker._ready`).
  `…_chat_finished.sql`, `…_chat_your_turn.sql` and `…_chat_limited.sql`
  widen the check; an older app reads the newer states as Starting.
- **A chat whose computer is away reads Offline, whatever it last said**
  (`Agents.away`: worker unseen 90s; a cloud-off mark, `_Away` over the
  field with the time it was last seen; ended and failed chats stay as
  they ended). A dead worker left chats "Working", taking messages that
  waited in `chat_in` unseen (asked 2026-11-25: "nothing showed, just
  nothing worked").
- **A turn that ends asking or offering is `your_turn`, not `finished`**
  (asked 2026-11-25: "agents ask me smth in the end or offer me, but chat
  writes finished"): `asksBack` reads the last paragraph (and the one
  before a trailing list) for a `?` outside code and links, or an offer's
  words in the app's languages. Shown as Waiting for you (red dot), pushed
  as a turn's end, takes a message like `finished`. A usage-limit stop is
  `limited`.
- **Server-only tables, not synced rows** (`…_agents.sql`): `workers`
  (heartbeat 30s, online if seen <90s, what it offers), `chats` (state new
  → running/asking/idle/finished/your_turn/limited → ended/failed, note, size, session), `chat_out`
  (pieces ≤ every 200ms; a `capture-pane -e` snapshot after 300 pieces
  once quiet, older rows deleted; the app reads from the latest snapshot),
  `chat_in` (keys, line, size, stop, start, answer, interrupt, mode;
  realtime payload applied at once, polled every 15s, deleted once taken),
  `chat_items`. RLS: own rows only.
- **Agents › Workers** shows host CPU, RAM and GPU from the Linux worker's
  heartbeat (`WorkerUsage`, `workers.resources`). CPU is averaged between
  beats, RAM uses `MemAvailable`, and GPU shows the busiest device that
  reports load via DRM or `nvidia-smi`. Offline and older workers show dashes.
- **What a worker can run** (`AgentBook`): Claude and Codex if on the
  PATH, a shell, and `~/.config/caldo/mcp/agents.json` (`{"llama":
  {"label": …, "command": ["llama-cli", ["-m", "{model}"], "{prompt}"],
  "models": […], "prompt": "arg|type|none"}}`; a list with an empty blank
  is dropped). Claude's command is built in `launchOf`: `--model --effort
  --permission-mode --resume -n`, `--settings` with its hooks and, only if
  changed, `enabledPlugins`; skills in `--append-system-prompt`. Plugins
  from `installed_plugins.json`, skills from `~/.claude/skills` and
  plugins' `skills/`, folders from `~/.claude.json`'s projects.
- **Claude's hooks say how it stands**: SessionStart (session kept for
  `--resume`), UserPromptSubmit/PostToolUse → running, Notification →
  asking, Stop → idle (`last_assistant_message` is a task's answer); each
  appends its JSON to `<chat>.events`.
- **Rules**: standing instructions (name, words, optional `opening`) in a
  server-only `agent_rules` table, edited under Agents › Rules
  (`RulesScreen`, `RuleScreen`, `agent_rules.dart`) and chosen on the new
  chat's form (kept in `agents_last`). A chat keeps a copy of their words
  (`chats.rules`, `[{name, body}]`), so later edits don't change it.
  Written by `rulesText`: Claude in `--append-system-prompt` after the
  skills' sentence, Codex as `developerInstructions` / `-c
  developer_instructions=`, `agents.json` agents through `{rules}`.
  Offered only to agents that take them (`AgentSpec.takesRules`); `rules`
  left out of the insert when none. A chat left without a first message
  starts with the chosen rules' openings (`firstMessage`, shown as the
  hint; app only). Errands take none.
- **Projects, not folders** (asked for in place of the form's folder):
  `agent_projects` (name, colour, info in `context`, `sources` from `~`),
  side by side — **no subprojects** (taken out 2026-11-25,
  `…_flat_projects.sql`; a subtask carries its parents' words instead);
  edited under Agents › Projects (`ProjectsScreen`, `ProjectScreen`,
  `agent_projects.dart`). A chat keeps a copy (`chats.project`,
  `Agents.snapshotOf`), used only if the project is deleted; `project_id`
  also sorts the list, which wears each project's colour.
- **A chat knows only what the user wrote in Caldo** (asked 2026-11-26:
  "codex for default dont read claude.md, then make claude dont read it
  too"): Claude runs with `quietEnv` (`CLAUDE_CODE_DISABLE_CLAUDE_MDS`,
  `…_AUTO_MEMORY`). Its context (`contextText`, after the rules) is the
  project's info, **read live** at each program start (`Worker._withContext`),
  then each parent chat's own context, outermost first (a subchat has all
  its parent has), then its own (`chats.context`, `…_chat_context.sql`).
  Changing any of them in the app sends `settings` to the chats it reaches
  (`setContext`, `setProjectInfo`, `retuneProject`). Claude takes it from a
  file (`--append-system-prompt-file`, `Tmux.promptOf`) with
  `--system-prompt-snapshot off` — without it a resumed session keeps the
  prompt it began with (tried on Haiku) — both only if its `--help` has them
  (`AgentSpec.promptFile/freshPrompt`). Terminals start from a script
  (`<chat>.run`): tmux refuses a command over ~16k.
- **Context is seen from the chat** (`ChatContextScreen`,
  `agent_context.dart`; the chat's menu › Context): parents' context read
  only (a tap opens that chat's page, where it is changed), project info
  and its own, each edited whole (`_ContextEditor`). **No files are shown**
  ("i dont wanna see any of files"). "Take from CLAUDE.md" begins the
  project's info from its folders' `CLAUDE.md` on the chat's computer
  (`readContext`, `agent_context_asks`, `ContextFiles`), into the editor to
  look over. Agents keep the info current with the MCP tools
  `project_info` / `update_project_info` (old → new, or the whole text).
- **Every chat from the app works in a folder of its own** (`Workspace`,
  `lib/mcp/workspace.dart`; `chats.workspace`, `{}` asked, filled by the
  worker): `~/.local/share/caldo/work/<chat>`, each source in a git repo
  a worktree on `caldo/<id8>` from the checkout's HEAD, any other source
  given as it is (`--add-dir`). One worktree is the start folder, else
  the chat's folder. `dir` is written back. Gone
  with the chat, its branch kept if it holds unmerged work; strays swept
  at the worker's start. Errands and chats from before keep `dir`.
- **Subchats** (asked 2026-11-26: "each subchat is the same as chat, but
  must have parent chat context and his own"; `chats.parent_id`,
  `…_subchats.sql`, set once, deleted with its parent): New subchat in a
  chat's menu opens `NewChatScreen(parent:)`, begun as the parent was, on
  its computer, no worker or project to choose; agents with `subchats`
  (not the shell). The worker places it in the parent's folder
  (`_borrow`; a parent not started has its folder made for both) and
  writes that workspace on it, so it is never its own (`ownFolder` false):
  deleting it leaves the folder. **Context: forked, else told.** Same
  agent and a resumable parent session: `--resume <parent> --fork-session`
  (Codex `thread/fork`), its own session from then on (`_Talker.fork`).
  Otherwise `parentWords` (the parent's messages and answers, latest 24k
  chars) goes ahead of its first message (`before`), not shown in the
  chat. Either way a note says where it began, and `subchatText` in its
  rules names the parent for `read_chat`/`message_chat`. Listed under its
  parent, indented (`Chat.families`: a family goes where its first member
  would); the chat screen shows parent and subchats as pills (`_Family`).
  Tried on the local stack with a stand-in `claude`.
- **A chat names itself from its first message** (`Worker._name`,
  `nameChat`): Haiku (`namingArgs`: no tools, settings, MCP or session, in
  the temp dir) gives three to six words as structured output
  (`--json-schema`, message in `<message>` tags — asked for plain text it
  answered the message), in the app's language (`chats.language`, else the
  message's). Written only while `chats.title` is empty. Once per chat per
  worker run; not for a shell or a `/` line.
- **A message can be left for later** (hold Send, right-click on a desk):
  30 min / 1h / 3h / Tomorrow 9:00 / a day and time, in a server-only
  `chat_later` table (not `chat_in`, which a worker empties). The worker
  says each when due (`Worker._sayLater`), deleting the row first; one for
  a stopped chat waits for Start again. Listed over the field
  (`LaterList`: Send now / Edit / Delete). Only from workers that say so
  (`AgentKind.later`).
- **A chat's context can be cleared, as `/clear` does** (asked for the
  reviewer to start each round afresh, 2026-11-24): `chat_in` `clear`,
  from the chat's menu, `/clear` typed in its chat, or the MCP tool
  `clear_context` (this chat by default). The worker puts the program by
  and forgets the session (`_Talker.clear`, `_forget`; `chats.session`
  null, `usage.context` dropped, a note); the next message starts afresh
  with the chat's rules, skills and subscriptions. Asked mid-turn, it
  waits for the turn and for every message said behind it (`_owed`), or
  a pull request told during the round went unanswered. Chat mode only (a
  terminal's Claude takes `/clear` itself); workers that say so
  (`AgentKind.clears`). Tried on the local stack with a stand-in `claude`.
- **A chat stopped at the usage limit carries on only if ticked**
  (asked 2026-11-25; it used to book itself): Claude marks the refused
  turn's stand-in message `error: "rate_limit"`, and its last
  `rate_limit_event` (`rejected`) says `resetsAt`; Codex fails the turn
  with `codexErrorInfo: usageLimitExceeded` (from its types, unseen). The
  worker posts a `note` marked `limit: true` (`resets` in ms;
  `CarryOn.stops`) — **not a kind of its own: `chat_items_kind_check`
  refuses unknown kinds**, and a refused row used to hold back the chat's
  every later item (now dropped alone, `_postEach`). `TalkView` draws the
  latest as a card (`_Limit`: which limit, when it resets, and a switch,
  off) until the user writes; older ones are a line. The switch leaves
  `CarryOn.words` in `chat_later` (key `limit…`, `CarryOn.at`: a minute
  after the reset, else 15 min on), **kept out of the later strip** — a
  tick-box and a "left for later" message were seen and disliked; off
  takes it back. Said, the words are drawn as a note ("Carried on after
  the limit"), not as the user's.
  Refused again while one waits, the worker moves it. A turn that goes
  through first takes it back (`_Talker._unbook`). Chat mode only.
- **Photos and files go with a message**: plus before the field
  (`Attachments.pick`), chips over it, ≤50MB each, uploaded to a private
  `chat-files` bucket under `<user>/<chat>/<uuid>` (Storage takes no
  Cyrillic keys) before the line names them (`chat_in.files`); nothing
  sent if an upload fails. The worker takes each to
  `<chat>.files/<uuid>/<name>` (`Worker._fetch`, name kept inside the
  folder) and tells the agent the paths (`withFiles`). Photos in Chat
  mode stay in the bucket for tap-to-zoom previews in the transcript.
  Other attachments are removed from the bucket after delivery.
  Agents can show a local image in their own chat with `send_image`
  and an optional caption. Claude gets `--add-dir=<dir>` (with `=`: the flag is
  variadic). A message's lines are said in turn (`_inTurn`). Only from
  workers that say so (`AgentKind.files`); not with Send later. Deleting a
  chat takes its folder and bucket files.
- **Chats talk to each other through Caldo's MCP server** (asked as
  "agents (chats) chatting with each other", 2026-11-23; `ChatTools`,
  `lib/mcp/chat_tools.dart`): `chats` lists them, `read_chat` reads one,
  `message_chat` sends one a message. A chat's program is started with
  its id in `CALDO_CHAT` (`chatEnv`; `Kept.start`'s environment, the tmux
  script's export), which the MCP servers it starts inherit, so the tool
  knows who is sending. The message is a `line` in `chat_in` with
  `sender` ({chat, title, waits}; `…_chat_from.sql`); the worker tells
  the agent it is from another chat, not the user, and how an answer gets
  back (`withSender`), and keeps `sender` on the user item, drawn as
  "From chat “…”" over the bubble. Waited on (the default, up to 10 min),
  a busy chat is waited for first — else its running turn's words would
  be taken for the answer — and the answer is the text items after the
  message's own (`u<key>`) once it stands idle. Refused: itself, ended
  chats, offline computers, shells (pasted, a message would run as a
  command), a worker from before (`chats` in its agents' JSON), waiting
  on a terminal, and waiting on a chat that is waiting on this one (each
  would wait out the other). Without `CALDO_CHAT` (a Claude Code session
  of the user's own) it sends as "an assistant outside Caldo's chats".
  Only where the user has Caldo's MCP server set up for Claude (`claude
  mcp add`); Codex passes few variables to MCP servers and cuts tools at
  60s, so it is unseen there. Tried on the local stack with a stand-in
  `claude` calling `caldo-mcp call message_chat`: an asked question came
  back in ~1.5s.
- **A chat can be subscribed to a repository's pull requests** (asked
  as "every new PR, reviewer get an message", 2026-11-24, so a reviewing
  chat stops looking every ten minutes; `Subscription`, `pullEvents`,
  `GitHub`, `lib/mcp/subscriptions.dart`; server-only
  `chat_subscriptions`, `…_chat_subscriptions.sql`). The chat's worker
  reads `gh pr list --state all --limit 50` once a minute a repository
  (`Worker._watch`; soon after a row is made, by realtime) — no turns
  spent, GitHub's own login on that computer. Events: opened (also out
  of draft, reopened; the default), pushed, closed (merged or not);
  never one opened before the row was made. Told as one message a look,
  a `line` whose `sender` is `{event, title: repo, subscription}`:
  `withSender` tells the agent it is not the user and nobody waits; the
  app draws "GitHub · owner/name" over it; it never names a chat. What
  was told is written to `seen` before it is said (a failing write must
  not repeat it each minute); one for a chat not running here waits for
  Start again. No `target` is the chat's folder's repository (`gh repo
  view` there, written in). `error` says why it could not look. Made by
  the MCP tools `subscribe`/`subscriptions`/`unsubscribe` (an agent
  subscribes itself) or in the chat's settings (`_SubscriptionsList`,
  `SubscriptionScreen`, `chat_subscriptions.dart`, saved at once, not
  with the settings). Only Claude and Codex, from a worker that says so
  (`AgentKind.events`). Polled, not a webhook: nothing to host or set up
  on GitHub, at most a minute late. Tried on the local stack with a
  stand-in `claude` and `gh`: told 55s after the PR, the push 60s after.
- **Which chat opened a pull request is noted, not written in it**
  (asked 2026-11-24, so a reviewer can talk to the author; a
  `Chat: [id]` line in each description was tried in the rules first and
  asked off — the repository is public). The worker reads every finished
  tool call (`_Talker.item`; Claude's `PostToolUse` hook in a terminal):
  a `gh pr create`/`new` in Bash or Codex's Shell, or a
  `create_pull_request` tool, with GitHub's link in its output
  (`pullsOpened`), goes into server-only `chat_pulls`
  (`…_chat_pulls.sql`; one row a PR, the first chat keeps it). A
  subscription's opened and pushed events say "opened by chat [id]
  "title"" (`Worker._openers`, `openerLabel`); the MCP tool `pull_chat`
  answers by number or link. A file read or search that mentions the
  command is not taken.
- **The watcher's errands are chats** (`Worker.errand`, when tmux is
  installed; `ClaudeCli` without it): Claude in the task's folder, the
  answer its first turn's `result` (or `--timeout`, then it goes on in its
  chat); handed back, the same chat resumes. The form has "Open its chat";
  the list marks task chats.
- **Tasks picked out on Schedule or the calendar can be sent to agents, a
  chat each** (asked for, 2026-11-22: "each of the task must spawn own
  agent … user must specify which worker, model, effort"):
  `NewChatScreen(tasks:)`, one form for all, and an optional "Tell each
  first" said before each task. Each chat is titled by its task (not named
  by Haiku), told `taskMessage` (title, due, notes, checklist) and kept as
  its task's (`chats.task_uuid`), so "Open its chat" shows for it too
  (`_findChat`). Only agents that take a first message, never the shell.
  One task opens its chat; more go back with a count. A Start that fails
  part way goes on with the rest next time (`_sent`). Each task sent is put
  In progress and marked with what it went to: `Task.agent`, schema v15,
  synced, a label (`agentMark`: "Opus", "Codex · gpt-5"), worn as the
  watcher's tasks wear theirs (`ClaudeMark.of`). A mark only, apart from
  `Task.claude` on purpose: the watcher would run a task by its label.
- **Sending a task is one form from everywhere** (asked for, 2026-11-25:
  "a better system to send tasks from calendar, schedule or kanban board
  to agents"; the user chose the full form, review on finish, now or when
  due): `sendToAgents` opens `NewChatScreen(tasks:)` from the picked-out
  cards' bar, a card's swipe, a desktop's right-click menu and the form's
  Agent row (which opens the chat once sent).
- **Where the agent stands is on the task** (`Task.agentState`, schema
  v16, synced; `AgentState`: waiting, working, asking, review, failed),
  so every card says it with nothing to ask the server. The card's mark
  reads "✦ Opus · Working" in the Agents list's colour for that state and
  stands in for the In progress badge. The app writes `waiting` at the
  send; the worker running the chat writes the rest (`Worker._follow`,
  `_turnDone`, `Caldo.agentSays`), one write after another, only on a
  change. **An answer is left for review, never ticked**: the first turn's
  answer goes into the notes under "— Claude, d.mm hh:mm —" (once a chat;
  later turns are in the chat) and the task stays In progress. The
  watcher's errands are told by the watcher itself (`_errands`), which
  also no longer ticks. A rolled-on repeat drops its state.
- **"When due"** (`_whenDue`, offered only when a task is not due yet and
  the worker says `tasks`): the chat is made at once `waiting`
  (`…_chat_waiting.sql`), with what was said on the form apart in
  `chats.preface`. Its worker (`_startDue`, at most every 10s) reads the
  task each time — moved, it waits for the new day — starts it once
  `Task.isDueBy`, and tells it `taskMessage` of the task as it is then;
  a deleted or ticked-off task ends it. The chat screen offers Start now
  (`Agents.startNow`: `waiting` → `new`, rebuilt from the preface too).
  The worker needs the account's tasks for all this (`Worker.caldo`, the
  watcher's `Caldo`). Tried end to end on the local stack with a stand-in
  `claude`: now, when due with notes edited meanwhile, deleted while
  waiting, Start now.
- **A chat's settings can be seen and changed after it began** (asked
  for, 2026-11-22: "see and edit the chat settings, model and etc";
  `ChatSettingsScreen`, `chat_settings.dart`, from the chat's menu or a
  tap on its head): computer, agent and folder shown (a folder changed
  would lose Claude's session, which lives under it); title, model,
  effort, permissions, plugins, skills and rules changed. A rule the chat
  keeps stays in its own words unless dropped; one added takes today's.
  Saved, the row is updated (`Agents.change`) and, past the title, a
  `chat_in` `settings` tells the worker (`Worker._retune`): a chat's
  program is put by at once if idle, else after its turn
  (`_Talker.retune`, `_putBy`), and the next message starts one with
  `--resume` — the note "Settings changed: …" is written where that
  happens, not at the save. A terminal with a session (Claude, or Codex
  moved from its chat) is started again at once, Claude's after its Stop
  hook (`_Live.retune`); one without keeps its settings until started
  again. Only from workers that say so (`AgentKind.settings`); older ones
  show them greyed with a line to reinstall. Tried on the local stack with
  a stand-in `claude` and from the emulator: opus → sonnet came back as
  `--model sonnet … --resume s1`.
- **The app**: `AgentsScreen` (long press/right-click deletes),
  `NewChatScreen` (prefs `agents_last`), `ChatScreen` (Chat/Terminal
  switch; Send stops a running turn when the field is empty; the terminal
  is xterm 4, `readOnly` on the phone, with a line field and a key row —
  Esc, Tab, Shift+Tab, arrows, ^C, Enter — fitting the width; a desktop's
  keys go straight in; size sent 400ms after it settles; text size in
  `terminal_font`). Bundled JetBrains Mono (no-ligature cut), falling back
  to `Term Symbols` (from Adwaita Mono) for ⏵ ⎿ and others no Android font
  has. Nothing is read unless the tab or a chat is open (`Agents.watch`).
- After a worker restart a terminal is taken up if its tmux session lives
  (`worker.json` offsets and seqs), else marked ended. Attach with `tmux -L
  caldo attach -t c<id>` (in the chat's menu).
- **Testing costs real Claude turns**; the shell agent doesn't. Test a
  worker against the local stack with `Tmux(socket: 'caldoe2e')` — never
  the user's `caldo` socket. Look for tasks with `claude` set first: a
  test worker takes them up at once.
- **Pushes** (asked for 2026-11-25; `Push`, `Push.kt`, Edge Function
  `push`, `push_tokens`): FCM data messages, drawn by `PushService` with
  the app closed or not, one per chat, none for the chat on screen; a tap
  opens the chat over Agents. Asked for as the user, never by a trigger:
  the worker tells a chat waiting (`Notices`: a question at once; a turn
  *the user* began, 20s after it ends unless another begins — turns begun
  by another chat or an event are quiet, or the reviewer would ring all
  day; a stop at the limit and a pull request opened, at once, whoever
  began it — the pull request again in its turn's end, which replaces it
  on the phone); an agent's own word is the MCP tool `notify`. **Muting a chat
  (`chats.muted`) silences its waiting, not `notify`**, as a mention gets
  through. Firebase is set up from `~/keys/caldo-google-services.json` at
  build time as resource strings (no google-services plugin; override with
  `CALDO_FIREBASE_CONFIG`); a build without it has no pushes. The function's
  key is the secret `FCM_SERVICE_ACCOUNT`; `FCM_URL`/`GOOGLE_TOKEN_URL`
  point it at a stand-in to try it. Not on the desktop. Try the drawing on
  the emulator as root: `am broadcast -n
  com.igor.caldo/com.google.firebase.iid.FirebaseInstanceIdReceiver -a
  com.google.android.c2dm.intent.RECEIVE --es chat <uuid> --es title …
  --es text …` (signed in, or it is dropped).

### Android platform bits

- **Launcher icon** (`LauncherIcon.kt`, two `activity-alias`es): Samsung
  gets the free-standing page, others the filled one; switched in
  `MainActivity.onStop` (`leftForGood`), not `onCreate` or
  `onUserLeaveHint`, which close the task.
- **Ask for the fastest display mode at the current resolution.**

## The MCP server

So an assistant can read and change the tasks.

- **It is one more device on the sync server**: signs in as the user and
  goes through `sync_push`/`sync_pull` (`Remote`, `SupabaseRemote`), so the
  phone hears within seconds. Each tool pulls first (`Caldo.refresh`); the
  account is held in memory (`Book`).
- **It ticks with the app's model**: `models/task.dart` is Flutter-free
  (`package:meta`, no `setEquals`) so `Task.completed`, `toStage`, `Repeat`
  run there. Keep it so; `task_list.dart` and `special_day.dart` import
  Material and aren't used there. Server address and login naming live in
  `services/caldo_server.dart` for the same reason.
- **An edit sends only the changed fields** (`Caldo._diff`), stamped past
  the row's own, and is read back: a loss to another device is reported.
- **The session, not the password, is kept** (`caldo-mcp login`,
  `~/.config/caldo/mcp/session.json`, 600), renewed only under a file lock,
  file read first (`SessionFile`, `ready`): every Claude session runs its
  own server, and a refresh token spent twice ends the session.
  `recoverSession` won't renew with `autoRefreshToken` off; it signs out
  *on the server*, ending the session everywhere — so a kept session is
  taken up only with a minute left (`_endingSoon`), else renewed.
- **Out of reach on purpose**: the vault, creating groups, attachment
  files. Ids are the uuid's first 8 characters; times are this computer's.
- **Install**: `tool/mcp/install.sh` → a kernel snapshot run by Flutter's
  Dart (`dart compile exe` refuses sqlite3's build hooks),
  `~/.local/bin/caldo-mcp`. Rerun after changing `lib/mcp` or the models.
  `caldo-mcp call <tool> '<json>'` runs one; `XDG_CONFIG_HOME` points it
  at another session.
- **The watcher** (`caldo-mcp watch`, `lib/mcp/watch.dart`; systemd user
  service `caldo-watch` from `tool/mcp/watch.sh`, options passed through,
  PATH baked in; rerun both scripts after changing it). New chat programs,
  terminals and their tools run in individual systemd user scopes under
  `caldo-agents.slice` when supported by the user manager. Scopes outlive
  watcher restarts and are cleaned up when their command exits. The slice
  caps memory at 65% of physical RAM and swap at 1 GiB, with no
  `MemoryHigh`: with swap capped it could only throttle, and the slice
  stalled (64 of 120 minutes; chats 7s to start). Existing chats move into the slice the next time their
  agent or terminal starts. **Agents wait for memory**: the PR and
  Reviewer rules run builds, tests, emulators and Supabase through
  `caldo-room GB command…` (`tool/mcp/room.sh`, installed by
  `install.sh`): it waits until the machine and every limit above it have
  that much free, one check at a time, the next held 30s while the last
  takes its memory. Measured: full `flutter test` 2.8 GB, an APK build
  ~4 GB (Gradle's caps), the emulator 2.2 GB. **A task is sent
  by naming a model on it** (`Task.claude`, schema v14: opus, sonnet, haiku
  or fable, `ClaudeModels`): a ✦ chip by the add field's group chip
  (`_ClaudeButton`, reset each opening), a form row, or the tools'
  `claude`; the card shows `ClaudeMark`. No "Claude" group. The board says
  how it stands: Not started waits; In progress while Claude works (a chat
  where tmux is installed, else `claude -p --model <it>`, prompt on stdin,
  `--output-format json`, `--permission-mode auto` by default); then the
  answer goes into the notes ("— Claude, d.mm hh:mm —", cut at 6000) and
  it stays In progress for review (`AgentState.review`). A failure stays In progress with the reason; moved back to
  Not started it runs again, resuming its session (`watch.json`; not for
  repeating tasks). A dated task waits for its time. `in: ~/folder` in the
  notes picks the folder, else `--dir` (home). One task at a time, one
  watcher (`watch.lock`); a task left by a stopped watcher gets
  "Interrupted". Woken by realtime on `sync_rows`, then 2s; polled each
  minute.

## Linux

**≥900pt wide is a desktop program**, narrower is the phone app in a
window. **The user hasn't seen either on their own desk** — their first
word outranks this section.

- **`onDesktop` asks Flutter, not `dart:io`** (`utils/platform.dart`);
  tests run as Android; desktop tests use
  `TargetPlatformVariant.only(TargetPlatform.linux)`.
- **Services do desktop work in Dart** (`Desktop`, `if (onDesktop)` in
  `Attachments`, `Backup`, `Updates`, `Reminders`): GTK dialogs,
  `xdg-open`. Tested in `desktop_test.dart`.
- Data in `~/.local/share/com.igor.caldo`; downloads in
  `~/.cache/com.igor.caldo`.
- **Name the Linux plugin halves directly** in `pubspec.yaml` (keeps
  Android halves and `jni` out of the APK).
- **System SQLite** (`hooks: user_defines: sqlite3: source: system`; after
  changing it delete `build/native_assets/android`); `linux/sqlite_shim.cc`
  provides `libsqlite3.so` linking `libsqlite3.so.0`, never a bundled copy.
- **Reminders fire only while the app is open** (`Reminders._alarms`,
  `_arm`, `_announce`, re-checked every ≤30s); Done and snoozes.
  **`Background._prepare` does nothing on desktop** — re-registering
  plugins broke every reminder after the first.
- **"Keys up" means an add field has focus** (`KeyboardGap.writing`);
  Enter on empty or Escape lets go. **Escape is Back** (`_EscapeGoesBack`).
- **Narrow layout**: mouse drags scroll like a finger, no scrollbars
  (`DesktopScrolling`); the wheel over the grid turns a notch at a time
  (`_onWheel`); chips use long press (`buildDefaultDragHandles: false`);
  phone density. 640–900 wide keeps the phone column centred (`PhoneWide`,
  left in the tree when wide).
- **Window** (`my_application.cc`): reopens at its closed size (first
  1240×780, min 340×560), saved on `delete-event`; single instance; dark
  title bar.
- **Not on desktop**: widget, phone calendars, full-screen reminder,
  camera, keyboard numbers, fingerprint. Five phrases have `…Desktop`
  variants.
- **Install**: `linux/install.sh` → `~/.local/opt/caldo`,
  `~/.local/bin/caldo`, entry `com.igor.caldo.desktop`.
- **Self-update** (`Desktop.replaceWith`) from `Caldo-linux-x64.tar.gz`
  when a release carries it: unpack beside, swap by name, relaunch; if
  unwritable, open the release page. Version from `pubspec.yaml`.

### The wide layout

Sidebar, each screen drawn for its width, task form as a right panel.

- **`Desk.wideOf(context)` is the one question** (`widgets/desk.dart`,
  `DeskScope` in `MaterialApp.builder`; `Desk.isWide` without
  subscribing). Tests pump `CaldoApp` (`desk_test.dart`, `pumpApp`).
- **Layout only switches with nothing open** (`DeskScope.observer`);
  screens under `GlobalKey`s (`_pages`).
- **Sidebar** (`DeskSidebar`): New task, Search, screens with overdue
  count, groups as a list (click shows, drag reorders, right-click/pencil
  edits), Settings at the foot. No chip rows.
- **Form panel** (`TaskPanel`, `DeskFormPanel`, `openTaskForm`,
  `TaskEditScreen.inPanel`): screens padded by its width unless <420
  remains. With changes (`_typed`, `_wordsDiffer`) it doesn't give way, it
  nudges (`_Nudged`). Escape closes it, twice if a field holds typed text
  (`_escapeForm`).
- **Calendar**: one state (`_buildWide`), month opened full height, day
  panel 384 wide on the right, arrows + Today over the month;
  `MonthSizes.desk` at ≥72pt a day. Titles click to open and drag to move
  (`_TaskTitle`, `_DropDay`, `MouseDraggable`); carry tile ≤150×64.
- **Schedule/Done**: 760 column, lists span the window (`DeskColumn`,
  `DeskGutter`); titles at one height (`ScreenHeader`, 48).
- **Board**: three lanes at once down to 200 each (`_Board.wideFraction`).
- **Settings**: list beside page (`_entries`, `_page`).
- **Sheets are centred dialogs** (`showAppSheet`; `PickerSheet` on the
  phone); **Search is a panel from the top** (`openSearch`).
- **Mouse**: drag picks up after 6pt (`pickUpListener`,
  `MouseDragRecognizer`), no drag-scroll (`WideScrolling`); Ctrl+click
  selects; right-click opens `showTaskMenu` (put-off is there,
  `PutOff.move`).
- **Keys** (`DeskKeys`, a `Focus` above the navigator, `DeskActions`):
  Ctrl+N, Ctrl+F/K, Ctrl+1–6; calendar arrows, PgUp/PgDn, Home/T. Only
  Escape while a dialog is open; arrows pass through to fields.
- **Typed times** (`parseClock`): "9", "930", "9:30 pm".
- **Never first-use a `late final` `AnimationController` in `dispose`**;
  make it in `initState` (form panel, `UndoSlot`, `SelectionSlot`).

## Tests

`flutter test` — 734 tests, all passing; keep it so. `supabase test db` — 116.

- Each test file has its own temp DB dir (`initTestDatabase`);
  `AppDatabase.close()` for the same reason.
- Real DB work can't finish in `testWidgets`' fake async: seed in
  `tester.runAsync`; for UI-triggered writes use a capturing provider
  (`_CapturingProvider` in `screens_test.dart`) or poll inside `runAsync`.
- Screens are pumped at phone sizes so overflows fail — intentional.
- The test font draws em squares: assert layout, not glyph widths.
- Exported keys: `monthTitleKey`, `calendarHandleKey`, `daySheetKey`,
  `searchFieldKey`, `screenTitleKey`, `taskCardTickKey`, `deskSidebarKey`,
  `deskFormKey`, `deskNewTaskKey`.
- "A Timer is still pending" usually means the `dispose` fault above.
- `TaskPanel` is app-wide: wide-layout tests close it in `tearDown`.

## Building

Load-bearing for reminders: **desugaring** in `app/build.gradle.kts`, the
**action receiver**, the **two scheduled receivers and three permissions**
in the manifest, and **`res/raw/keep.xml`** (keeps the notification icon
from R8).

`android/gradle.properties` is capped on purpose (`-Xmx2G`, four workers,
1G Kotlin daemon; 13GB machine) — don't raise. Stop the daemon after:

```sh
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
(cd android && ./gradlew --stop)
```

**Signing**: `~/keys/caldo-release.jks` via `android/key.properties` (both
outside git). Lose them and no update installs over Caldo again. A release
build without `key.properties` fails on purpose. **Firebase**:
`~/keys/caldo-google-services.json`, also outside git; without it a build
still succeeds, with no pushes (a warning says so).

**Release only when asked.** Commit each change; don't bump, build or
publish unprompted (the updater ships whatever is latest). A release is
both `release/` (`Caldo-arm64.apk`, `Caldo-armv7.apk`,
`Caldo-universal.apk`) and `gh release create vX.Y.Z release/*.apk` from the
latest commit. `<!-- priority: high -->` in the notes only when asked.
`tool/package_linux.sh` adds `Caldo-linux-x64.tar.gz`; whether a release
carries it is the user's call.

Linux: `flutter build linux --release` → `build/linux/x64/release/bundle`;
needs SQLite headers (`pkg-config sqlite3`).

## Running on the emulator

The shell's `ANDROID_SDK_ROOT` (`/opt/android-sdk`) has no emulator; use
`~/Android/Sdk`:

```sh
SD=~/Android/Sdk
ANDROID_SDK_ROOT=$SD ANDROID_HOME=$SD $SD/emulator/emulator -avd pixel_api34 &
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -a android.intent.action.MAIN -n com.igor.caldo/.LauncherFree
adb exec-out screencap -p > shot.png
```

(`monkey` may send Home, which switches `LauncherIcon`.) **The emulator
always runs the latest commit**: after every change build a release APK (no
bump) and install it. Judge by eye from a screenshot before saying it works.
Screen 1080×1920 at **dpr 2.625** (411×731). `input text` can't send
Cyrillic. **Long press needs motion events**, not `input swipe`:

```sh
adb shell input motionevent DOWN 540 880
sleep 1
for y in 840 760 680 600; do adb shell input motionevent MOVE 540 $y; done
adb shell input motionevent UP 540 600
```

Not bugs: ANRs under load (host starvation); a loaded host drops frames,
which looks like a detached keyboard bar — judge keyboard UI on a quiet
machine against the committed build; debug builds draw at half rate; the
emulator's keyboard slides up (~270ms) but drops down in one lump; the
first month opening after a cold start is slow (GL warm-up);
`screenrecord` drops frames.

## Running the sync server

Supabase in Docker (`supabase/`, CLI `~/.local/bin/supabase` v3.1.0):

```sh
supabase start -x imgproxy
supabase test db
supabase stop          # holds 2-3GB
```

API `http://127.0.0.1:54321` (emulator: `10.0.2.2:54321`), dashboard
:54323, Mailpit :54324. If docker access fails, `newgrp docker`.

**The cloud project** is linked (`supabase/.temp`): `supabase db push
--remote` applies migrations; `supabase functions deploy <name> --use-api`
the Edge Functions (`supabase/functions`). **Never `config push` the repo's
`config.toml`** (it is the local stack's): push a file declaring only what
is meant, with `--workdir` on a scratch directory. `supabase db query
--remote` writes to the live database — ask first; `--read-only` needs no
asking. Make an admin with `insert into public.admins select id from
auth.users where email = '<name>@caldo.invalid'`.

## Running on Linux

`tool/desktop/try.sh` runs the build on its own Xvfb display (`:99`), home
and session bus; `--stop` ends it.

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
button key to `press`). To try a reminder: stop the app, insert a task a
minute ahead with `sqlite3` (`due_at` ms, `has_time` 1), restart. Close with
`WM_DELETE_WINDOW` to test size saving. Not bugs: a drag pausing >40ms
before release isn't a fling; GTK's file dialog may drop the second typed
character; the save dialog selects the name without ".json"; clicking a
file row opens it. **Never `pkill -f` a pattern the killing command itself
contains.**

## Conventions

- Comments explain **why**, at about Dicty's density.
- Commit messages are prose: what changed and why. End with the
  `Co-Authored-By` line.
- `flutter analyze` clean before every commit.
- Keep these notes short: a decision, its code names, and the one reason
  that stops it being undone. The story goes in the commit message.

## Known gaps

- Linux: reminders need Caldo open; a clicked notification can't raise the
  window; no scrollbars in the wide layout; x64 only; Undo's brush-off is
  measured against the window; `caldo://` links open nothing.
- No password reset but by hand; a free Supabase project pauses after
  about a week without requests.
- Backups carry attachment records, not files; files over 50MB never sync.
- Holiday names are in each country's language (English-speaking
  countries and Canada in English).

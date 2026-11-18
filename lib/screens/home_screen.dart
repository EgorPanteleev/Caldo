import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../db/database.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../services/account.dart';
import '../services/backup.dart';
import '../services/reminders.dart';
import '../services/sync.dart';
import '../services/today_widget.dart';
import '../services/updates.dart';
import '../theme/app_theme.dart';
import '../widgets/desk.dart';
import '../widgets/glass.dart';
import '../widgets/quick_add_bar.dart' show BarFoot, BarRoom, KeyboardGap;
import '../widgets/selection.dart';
import '../widgets/task_views.dart';
import '../widgets/sign_in_sheet.dart' show showJoinSheet;
import '../widgets/tick_off.dart' show UndoSlot, withdrawUndo;
import '../widgets/update_banner.dart';
import 'board_screen.dart';
import 'calendar_screen.dart';
import 'desk_shell.dart';
import 'done_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'task_edit_screen.dart';
import 'tasks_screen.dart';
import 'vault_screen.dart';

/// Top-level shell: whichever screen is open, and the way between them —
/// a bar of four tabs floating along the foot; and in a desktop's wide
/// window a sidebar down the left, with a task's form in a panel down the
/// right (`Desk`, `DeskSidebar`, `DeskFormPanel`).
///
/// A menu behind a button at the top left came first; the bar was asked
/// for after the user saw one they liked ("i strongly like bottoms like
/// this", of a floating pill of tabs), and for a while the two were a
/// choice in Settings. Six tabs then read as "overwhelmed", so Schedule,
/// the board and Done went under one tab as views of the same tasks
/// ([taskViews]), switched between by their names in the header, and the
/// menu went.
class HomeScreen extends StatefulWidget {
  /// Which screen to open on. Only read as the shell is built: changing the
  /// setting is about the next launch, and a screen that jumped out from
  /// under the setting being changed would be startling.
  final AppScreen start;

  const HomeScreen({super.key, this.start = AppScreen.schedule});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // The pages are in the order of [AppScreen], Settings after them.
  late int _index = widget.start.index;

  /// The task view last on show, which the Tasks tab goes back to: someone
  /// who works from the board should not be put on Schedule every time.
  late int _lastView = taskViews.contains(widget.start)
      ? widget.start.index
      : AppScreen.schedule.index;

  // Each under a key of its own, so a screen keeps its state — the day
  // picked, how far it is scrolled — when a window dragged wider or narrower
  // moves it from one layout into the other.
  late final List<Widget> _pages = [
    for (final page in [
      const TasksScreen(),
      const CalendarScreen(),
      BoardScreen(shown: _boardShown),
      DoneScreen(shown: _doneShown),
      VaultScreen(shown: _vaultShown),
      const SettingsScreen(),
    ])
      KeyedSubtree(key: GlobalKey(), child: page),
  ];

  /// What the two screens with a field lend the bar: their field, for the
  /// plus, and their Undo and selection, for the bar's place.
  final _feet = [BarFoot(), BarFoot()];

  BarFoot? get _foot => _index < _feet.length ? _feet[_index] : null;

  /// A page told the room the bar takes at its foot ([BarRoom]). Every
  /// page runs on under the bar, so what scrolls is seen through its
  /// frosting, and leaves that much room at the end of its scroll; the two
  /// with a field rest it in the bar's room too.
  Widget _room(int i) => BarRoom(
    height: BarRoom.room,
    foot: i < _feet.length ? _feet[i] : null,
    child: _behind(i, _pages[i]),
  );

  /// A screen not on show keeps its state but not its animations: an
  /// `IndexedStack` leaves the screens behind the current one ticking, and
  /// the Vault's spinner, waiting there to be first shown, had the whole
  /// app drawing sixty frames a second from start.
  Widget _behind(int i, Widget page) =>
      TickerMode(enabled: i == _index, child: page);

  /// The plus above the bar brings up the screen's field on the keyboard;
  /// held, it is the full form. It is only there on the two screens with a
  /// field.
  void _add() => _foot?.open?.call();

  void _addInFull() => _foot?.form?.call();

  /// Whether the board and Done are the screen on show, which is when each
  /// reads what it draws — and the vault, which is kept out of screenshots
  /// only while it is.
  late final _boardShown = ValueNotifier<bool>(_index == _board);
  late final _doneShown = ValueNotifier<bool>(_index == _done);
  late final _vaultShown = ValueNotifier<bool>(_index == _vault);

  static final _board = AppScreen.board.index;
  static final _done = AppScreen.done.index;
  static final _vault = AppScreen.vault.index;

  @override
  void initState() {
    super.initState();
    // After the first frame rather than before it: the answer comes off the
    // network, and nothing on screen should wait for it.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => Updates.instance.look(),
    );
    TodayWidget.listen(_openFromWidget, invited: _openInvite);
    // One that started the app is already waiting by the first frame.
    Reminders.opened.addListener(_openReminder);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openReminder());
    WidgetsBinding.instance.addObserver(this);
    _checkFullScreen();
    _waitForMidnight();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => Backup.autoIfDue(context.read<SettingsProvider>()),
    );
    DeskActions.instance
      ..newTask = _newTask
      ..search = _search
      ..show = _show
      ..onCalendar = _index == AppScreen.calendar.index;
  }

  /// A new task, from the sidebar or the keys: the form the screen on show
  /// would open — on the calendar's day, on today — or, where the screen has
  /// none of its own, one on today; the board's has no day, as its own plus
  /// gives it none.
  void _newTask() {
    final form = _foot?.form;
    if (form != null) return form();
    openTaskForm(
      context,
      initialDate: _index == _board ? null : dayOf(DateTime.now()),
    );
  }

  void _search() => openSearch(context);

  /// The screen at [place] in the sidebar's order, if it is in it; Settings
  /// is the sixth.
  void _selectView(AppScreen view) => _select(view.index);

  void _show(int place) {
    final hidden = context.read<SettingsProvider>().hiddenScreens;
    if (place < AppScreen.values.length &&
        hidden.contains(AppScreen.values[place])) {
      return;
    }
    _select(place);
  }

  /// Escape on the form's panel closes it, as Cancel does — but with
  /// something typed and the caret still in a field, the first press only
  /// leaves the field: Escape is pressed out of habit, and a note is a lot
  /// to lose to one.
  void _escapeForm() {
    final panel = TaskPanel.instance;
    final typing = DeskKeys.typing;
    FocusManager.instance.primaryFocus?.unfocus();
    if (!(panel.dirty && typing)) panel.close();
  }

  /// Wakes the lists at the turn of the day, for an app left open across
  /// it; one left in the background is caught up on its return instead.
  Timer? _midnight;

  void _waitForMidnight() {
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now) + const Duration(seconds: 1), () {
      context.read<TaskProvider>().catchUp();
      _waitForMidnight();
    });
  }

  /// Whether Android lets a reminder take the screen, once asked; asked on
  /// opening and on every return, since the way to allow it is a page in
  /// Android's settings, and coming back from it is a return.
  bool? _fullScreenAllowed;

  /// The offer to allow it has been closed for this opening.
  bool _fullScreenPutOff = false;

  Future<void> _checkFullScreen() async {
    final allowed = await Reminders.instance.canFullScreen();
    if (mounted && allowed != _fullScreenAllowed) {
      setState(() => _fullScreenAllowed = allowed);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _checkFullScreen();
    Reminders.instance.recheckExact();
    context.read<TaskProvider>().catchUp();
    Backup.autoIfDue(context.read<SettingsProvider>());
    // Another device may have changed things while this one was away.
    Sync.instance.run();
    // And a release may have come out.
    Updates.instance.look();
  }

  /// A reminder tapped with the phone in use opens its task, as a row of
  /// the widget does; over the lock screen the activity shows it itself.
  void _openReminder() {
    final id = Reminders.opened.value;
    if (id == null || !mounted) return;
    Reminders.opened.value = null;
    _openFromWidget(id);
  }

  /// An invite link opens the sheet that makes an account with it — unless
  /// this device is already signed in, when there is nothing for it to do.
  void _openInvite(String invite) {
    final account = Account.instance;
    if (account.email.value != null || account.server.value == null) return;
    // The link that started the app arrives before its first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      showJoinSheet(context, invite: Account.inviteIn(invite));
    });
  }

  /// A row of the home-screen widget opens its task's form, and the
  /// widget's plus a new one on today, over whichever screen is showing —
  /// and over nothing else: a form left open from before is closed first.
  Future<void> _openFromWidget(int? id) async {
    final task = id == null ? null : await AppDatabase.instance.getTask(id);
    if (!mounted || (id != null && task == null)) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    await openTaskForm(
      context,
      task: task,
      initialDate: task == null ? dayOf(DateTime.now()) : null,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midnight?.cancel();
    Reminders.opened.removeListener(_openReminder);
    DeskActions.instance
      ..newTask = null
      ..search = null
      ..show = null;
    for (final foot in _feet) {
      foot.dispose();
    }
    _boardShown.dispose();
    _doneShown.dispose();
    _vaultShown.dispose();
    super.dispose();
  }

  /// Switch screens, refreshing the dated views so they stay correct across a
  /// midnight rollover or edits made from another one.
  ///
  /// What is picked out on a screen is put down on the way off it: the
  /// screens stay alive behind one another, and one left holding a selection
  /// would have back answer to it from out of sight.
  void _select(int i) {
    if (i == _index) return;
    Selection.dropAll();
    withdrawUndo();
    setState(() {
      _index = i;
      if (taskViews.any((v) => v.index == i)) _lastView = i;
    });
    _boardShown.value = i == _board;
    _doneShown.value = i == _done;
    _vaultShown.value = i == _vault;
    DeskActions.instance.onCalendar = i == AppScreen.calendar.index;
    final provider = context.read<TaskProvider>();
    if (i == AppScreen.schedule.index) provider.loadTasks();
    if (i == AppScreen.calendar.index) provider.loadMonth(provider.month);
  }

  /// The screen back returns to before it leaves the app, as it does in an
  /// app with tabs along the foot: the one the app opened on, or the first
  /// one still in the app if that has since been taken out of it.
  int _home(Set<AppScreen> hidden) => !hidden.contains(widget.start)
      ? widget.start.index
      : AppScreen.values.firstWhere((s) => !hidden.contains(s)).index;

  /// The least a screen is squeezed to beside the form's panel. In a
  /// window with less to spare than that the panel lies over the screen
  /// instead of moving it aside.
  static const _leastBeside = 420.0;

  /// The shell in a desktop's wide window: the sidebar, the screen on show,
  /// and the form's panel over the screen's right edge.
  ///
  /// Every screen but the calendar is given the panel's width as room at
  /// its right while a form is open, so its cards stand beside the form
  /// rather than under it. The calendar keeps its width: the panel is as
  /// wide as the day down its right side and covers exactly that, and the
  /// month beside it does not move.
  ///
  /// The two screens with a field still hand over what their plus opens
  /// ([BarFoot]), for the sidebar's New task; with no bar's room to rest in
  /// (`BarRoom.height` nothing) the field itself stays at the foot of the
  /// screen.
  Widget _wide(AppPalette p, Widget banners) {
    final panel = TaskPanel.instance;
    return ListenableBuilder(
      listenable: panel,
      builder: (context, _) => PopScope(
        canPop: !panel.isOpen,
        onPopInvokedWithResult: (didPop, _) {
          // What is picked out answers to Escape first, on its own.
          if (!didPop && !Selection.anyActive) _escapeForm();
        },
        child: Scaffold(
          backgroundColor: p.bg,
          resizeToAvoidBottomInset: false,
          body: ScrollConfiguration(
            behavior: const WideScrolling(),
            child: Row(
              children: [
                DeskSidebar(
                  index: _index,
                  onSelected: _select,
                  onNew: _newTask,
                  onSearch: _search,
                ),
                Expanded(
                  child: Column(
                    children: [
                      banners,
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final beside =
                                panel.isOpen &&
                                box.maxWidth - Desk.side >= _leastBeside;
                            return ClipRect(
                              child: Stack(
                                children: [
                                  IndexedStack(
                                    index: _index,
                                    children: [
                                      for (var i = 0; i < _pages.length; i++)
                                        BarRoom(
                                          height: 0,
                                          foot: i < _feet.length
                                              ? _feet[i]
                                              : null,
                                          child: _behind(
                                            i,
                                            i == AppScreen.calendar.index
                                                ? _pages[i]
                                                : AnimatedPadding(
                                                    duration: const Duration(
                                                      milliseconds: 220,
                                                    ),
                                                    curve: Curves.easeOutCubic,
                                                    padding: EdgeInsets.only(
                                                      right: beside
                                                          ? Desk.side
                                                          : 0,
                                                    ),
                                                    child: _pages[i],
                                                  ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const Positioned(
                                    top: 0,
                                    bottom: 0,
                                    right: 0,
                                    child: DeskFormPanel(),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final hidden = context.select<SettingsProvider, Set<AppScreen>>(
      (s) => s.hiddenScreens,
    );
    final home = _home(hidden);
    // Offered only to someone who wants full-screen reminders and is not
    // getting them: switched off in Settings, it is not asked about again.
    final wantsFullScreen = context.select<SettingsProvider, bool>(
      (s) => s.loaded && s.reminders && s.fullScreenReminders,
    );
    final offerFullScreen =
        wantsFullScreen && _fullScreenAllowed == false && !_fullScreenPutOff;
    // Above whichever screen is open rather than inside one of them: they
    // are about the app, not about a day.
    Widget banners(Update? update) => AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        children: [
          const SizedBox(width: double.infinity),
          if (update != null) UpdateBanner(update: update),
          if (offerFullScreen)
            _FullScreenBanner(
              onAllow: Reminders.instance.requestFullScreen,
              onDismiss: () => setState(() => _fullScreenPutOff = true),
            ),
        ],
      ),
    );
    if (Desk.wideOf(context)) {
      return _wide(
        p,
        ValueListenableBuilder<Update?>(
          valueListenable: Updates.instance.offered,
          builder: (context, update, _) => banners(update),
        ),
      );
    }
    final pages = TaskViews(
      shown: [
        for (final view in taskViews)
          if (!hidden.contains(view)) view,
      ],
      onSelected: _selectView,
      child: IndexedStack(
        index: _index,
        children: [for (var i = 0; i < _pages.length; i++) _room(i)],
      ),
    );
    final screen = SafeArea(
      // The strip at the foot of the screen stays reserved while the
      // keyboard is over it. Android stops counting the gesture bar as
      // padding the moment the keys cover it, and without this the screen
      // grows by that much as the keyboard arrives — which on a phone drawn
      // edge to edge was the month and the day's tasks shifting slightly
      // every time the add field was tapped. Nothing about the screen should
      // move when the keyboard does; only the field rides it up.
      maintainBottomViewPadding: true,
      // The screens run up under the status bar, so what scrolls under a
      // screen's head is blurred there too ([GlassTop]); each keeps clear
      // of it itself. A banner takes the status bar's room in their place,
      // at once rather than as it slides in, so the screen under it doesn't
      // jump up first.
      top: false,
      child: Stack(
        children: [
          ValueListenableBuilder<Update?>(
            valueListenable: Updates.instance.offered,
            builder: (context, update, pages) {
              final any = update != null || offerFullScreen;
              return Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: any ? MediaQuery.paddingOf(context).top : 0,
                  ),
                  banners(update),
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: any,
                      child: pages!,
                    ),
                  ),
                ],
              );
            },
            child: pages,
          ),
          // What the bar stands on: the foot of the screen blurred more and
          // more towards the bottom, so the bar isn't a pill pasted on top
          // of sharp cards. Goes with the bar.
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _WhileKeyboardDown(
              child: SizedBox(
                height: BarRoom.room + BarGround.lead,
                child: BarGround(),
              ),
            ),
          ),
          // Over the screen rather than under it, so the ground the screen
          // stands on runs on beneath the bar. It goes while the keyboard is
          // up: the screen's field is brought up in its place and rides the
          // keys, and the bar stays behind them.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _WhileKeyboardDown(
              child: ListenableBuilder(
                listenable: Listenable.merge([?_foot, ?_foot?.selection]),
                builder: (context, _) => _TabBar(
                  index: _index,
                  tasksTab: _tasksTab(hidden),
                  hidden: hidden,
                  foot: _foot,
                  onSelected: _select,
                  onAdd: _add,
                  onAddInFull: _addInFull,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return PopScope(
      canPop: _index == home,
      onPopInvokedWithResult: (didPop, _) {
        // Back puts down what is picked out first; the selection answers to
        // it on its own.
        if (!didPop && !Selection.anyActive) _select(home);
      },
      child: Scaffold(
        backgroundColor: p.bg,
        // Each screen decides for itself what the keyboard does to it. Resize
        // here and the shell shortens all of them before any of them is asked.
        resizeToAvoidBottomInset: false,
        body: screen,
      ),
    );
  }

  /// Where the Tasks tab goes: the view last on show, or the first one
  /// still in the app if that has since been taken out; none if all three
  /// have been.
  int? _tasksTab(Set<AppScreen> hidden) {
    final shown = [
      for (final view in taskViews)
        if (!hidden.contains(view)) view.index,
    ];
    if (shown.isEmpty) return null;
    return shown.contains(_lastView) ? _lastView : shown.first;
  }
}

/// Offers to let reminders take the whole screen while the phone is locked,
/// when that has been asked for in Settings and Android does not allow it.
///
/// Shown where the update banner is, above whichever screen is open. Allow
/// opens the page in Android's settings; the shell asks again on the way
/// back and the banner goes once it is allowed. Closing it puts it off until
/// the app is next opened; switching full screen off in Settings is the way
/// to stop it for good.
class _FullScreenBanner extends StatelessWidget {
  final VoidCallback onAllow;
  final VoidCallback onDismiss;

  const _FullScreenBanner({required this.onAllow, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context).color;
    final s = S.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.fullscreen_rounded, size: 22, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              s.fullScreenOffer,
              style: TextStyle(color: p.text, fontSize: 14),
            ),
          ),
          TextButton(
            onPressed: onAllow,
            child: Text(
              s.allow,
              style: TextStyle(color: accent, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: s.notNow,
            icon: Icon(Icons.close_rounded, color: p.muted, size: 20),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// The screens, in a pill floating along the foot of the window, the one on
/// show lifted out in a pill of its own that slides to the one picked, and
/// a round plus floating above its far end for a new task.
///
/// Four tabs: Tasks — Schedule, the board and Done, whichever was last on
/// show ([taskViews]) — the calendar, the vault, and Settings last, always
/// there, as the way to put back what was taken out.
///
/// Neutral: the screen on show is lifted in grey, not the accent, which is
/// kept for what is rare.
///
/// The plus is where the add field went. The field sat over the bar as a
/// second pill of the same grey, and the two read as one toolbar stacked on
/// another — "badly fit". Chosen over a plus as a sixth tab, which squeezed
/// every name and was a tab that is not a screen. It sat in the bar's row
/// at first, and was asked up out of it ("mustn't be in the same row"), so
/// the bar has the whole width again. A tap brings up the screen's field on
/// the keyboard, in the bar's place; held, it opens the full form, as the
/// plus beside the field did. Undo and the selection stand in the bar's
/// place, as they stood in the field's — which costs the tabs for Undo's
/// four seconds, unless it is tapped or brushed away. The plus stays over
/// Undo, and goes while tasks are picked out: nothing is added halfway
/// through dealing with them.
class _TabBar extends StatelessWidget {
  final int index;

  /// The page the Tasks tab opens; null with all three views taken out.
  final int? tasksTab;
  final Set<AppScreen> hidden;
  final BarFoot? foot;
  final ValueChanged<int> onSelected;
  final VoidCallback onAdd;
  final VoidCallback onAddInFull;

  const _TabBar({
    required this.index,
    required this.tasksTab,
    required this.hidden,
    required this.foot,
    required this.onSelected,
    required this.onAdd,
    required this.onAddInFull,
  });

  static const _height = BarRoom.pill;

  /// Settings, after the screens [AppScreen] names.
  static final _settings = AppScreen.values.length;

  static bool _isView(int i) => taskViews.any((v) => v.index == i);

  @override
  Widget build(BuildContext context) {
    // Only Schedule and the calendar have a field for it to bring up. On
    // the board, Done and Settings it opened the form on its own, and was
    // asked off them.
    final gone = foot == null || (foot?.selection?.active ?? false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: BarRoom.tabsSide, bottom: 10),
          child: IgnorePointer(
            ignoring: gone,
            child: AnimatedScale(
              scale: gone ? 0.6 : 1,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: gone ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: _AddButton(onTap: onAdd, onLongPress: onAddInFull),
              ),
            ),
          ),
        ),
        _bar(context),
      ],
    );
  }

  Widget _bar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BarRoom.tabsSide,
        BarRoom.above,
        BarRoom.tabsSide,
        BarRoom.below,
      ),
      // Undo under the selection, as in the field's place: a tick offered
      // back while cards are being picked out waits beneath the bar for
      // them.
      child: SelectionSlot(
        selection: foot?.selection,
        child: UndoSlot(
          place: foot?.undo,
          // A tap on it away from Undo only puts it away. It is over the
          // tabs, and the tap is more likely to have been meant for them
          // than for a new task.
          onField: () {},
          child: SizedBox(
            key: tabBarKey,
            height: _height,
            child: _screens(context),
          ),
        ),
      ),
    );
  }

  Widget _screens(BuildContext context) {
    final p = AppTheme.of(context);
    // Whether there is anything, and nothing else: watching the whole
    // provider rebuilt the bar on every change to every task.
    final overdue = context.select<TaskProvider, bool>(
      (p) => p.allOverdue.isNotEmpty,
    );
    // Each tab as the page it opens and the item it draws; the Tasks tab
    // stands for all three views and is lit on any of them.
    final tabs = <(int, ScreenItem)>[
      if (tasksTab case final views?) (views, tasksItem),
      for (final screen in [AppScreen.calendar, AppScreen.vault])
        if (!hidden.contains(screen)) (screen.index, screenItems[screen.index]),
      (_settings, screenItems[_settings]),
    ];
    bool lit(int page) => page == index || (_isView(page) && _isView(index));
    // The overdue backlog is Schedule's, so the dot goes on the Tasks tab —
    // or on the calendar, where the overdue days are, when Schedule is out.
    bool late(int page) => !hidden.contains(AppScreen.schedule)
        ? _isView(page)
        : page == AppScreen.calendar.index;
    final at = tabs.indexWhere((tab) => lit(tab.$1));
    // The picked tab's pill all but touches the rim, as on the bar this was
    // matched to: four points in, it was a pill floating inside a pill. A
    // seam of the bar's fill is kept, or the pill's grey runs into the rim
    // and the rim is lost round the picked tab.
    const inset = 1.0;
    final pill = Container(
      padding: const EdgeInsets.all(inset),
      decoration: BoxDecoration(
        color: p.panelHi.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(_height / 2),
        border: Border.all(color: BarRoom.rim(p), width: BarRoom.rimWidth),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth / tabs.length;
          return Stack(
            children: [
              if (at >= 0)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  left: width * at,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color.lerp(p.field, p.muted, 0.18),
                      borderRadius: BorderRadius.circular(_height / 2),
                    ),
                  ),
                ),
              Row(
                children: [
                  for (final (page, item) in tabs)
                    Expanded(
                      child: _Tab(
                        item: item,
                        selected: lit(page),
                        dot: overdue && late(page),
                        onTap: () => onSelected(page),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
    // A little frosted: what scrolls under the bar shows through it,
    // blurred, rather than the bar being a solid slab over the screen.
    return ClipRRect(
      borderRadius: BorderRadius.circular(_height / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 17, sigmaY: 17),
        child: pill,
      ),
    );
  }
}

/// Identifies the tab bar's pill.
const tabBarKey = Key('tab-bar');

/// Identifies the plus above the tab bar.
const barAddKey = Key('bar-add');

/// The plus, a disc in the bar's own grey and edge, so the two read as a
/// pair at the foot. Plain, as the plus beside the field was: it is pressed
/// often and looked at rarely. Frosted as the bar is, and like it without a
/// shadow, which would show dark through the fill.
class _AddButton extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _AddButton({required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    // No tooltip: a long press is the full form, and a tooltip would take
    // it.
    return Semantics(
      button: true,
      label: S.of(context).newTask,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 17, sigmaY: 17),
          child: Material(
            key: barAddKey,
            color: p.panelHi.withValues(alpha: 0.6),
            shape: CircleBorder(
              side: BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                onTap();
              },
              onLongPress: () {
                HapticFeedback.mediumImpact();
                onLongPress();
              },
              customBorder: const CircleBorder(),
              child: SizedBox.square(
                dimension: 56,
                child: Icon(Icons.add_rounded, color: p.text, size: 28),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws [child] only while the keyboard is down. With it up, the screen's
/// field is in the bar's place, riding the keys, and the bar is behind them
/// anyway — but not for the first frames of a slide, when the field would
/// be coming up through it. Reads the lift, so it is rebuilt on every frame
/// of one; it is the smallest widget that can.
///
/// Hidden, it is still drawn, at the faintest alpha there is: not drawn at
/// all, the bar's blurs gave up what they draw through, and the frame that
/// brought them back took 23-30ms to draw on the 120Hz Galaxy, at the end of
/// every closing in every recording (2.11.22-2.11.30) — three frames lost
/// just as the keys went. Drawn, they cost what they cost with the keys
/// down, behind the keys.
class _WhileKeyboardDown extends StatelessWidget {
  final Widget child;

  const _WhileKeyboardDown({required this.child});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: KeyboardGap.instance.changes,
      builder: (context, child) {
        final down = !KeyboardGap.up(context);
        return IgnorePointer(
          ignoring: !down,
          child: Opacity(opacity: down ? 1 : _faint, child: child),
        );
      },
      child: child,
    );
  }

  /// One step of 255: drawn, and nothing anyone can see.
  static const _faint = 1 / 255;
}

class _Tab extends StatelessWidget {
  final ScreenItem item;
  final bool selected;

  /// Something is overdue: the one thing worth pulling the user back to a
  /// screen they are not on.
  final bool dot;
  final VoidCallback onTap;

  const _Tab({
    required this.item,
    required this.selected,
    required this.dot,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final color = selected ? p.text : p.muted;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  if (item.glyph case final glyph?)
                    glyph(selected, color)
                  else
                    Icon(
                      selected ? item.activeIcon : item.icon,
                      color: color,
                      size: 22,
                    ),
                  if (dot)
                    Positioned(
                      top: -2,
                      right: -4,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: AppColors.overdue,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              // Shrunk rather than cut: four to a phone's width is about
              // eleven letters each, and "Einstellungen" has thirteen.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  item.label(S.of(context)),
                  maxLines: 1,
                  style: TextStyle(
                    color: color,
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the tab bar and the desktop's sidebar draw for each screen, in the
/// order of [AppScreen] and Settings last. Settings draws its list of
/// screens from it too, so a screen looks the same everywhere.
final screenItems = [
  // A list, not a tick: the screen is a running order of days, and a tick
  // is what sits on each of the rows inside it.
  ScreenItem(Icons.list_alt_outlined, Icons.list_alt, (s) => s.schedule),
  ScreenItem(
    Icons.calendar_month_outlined,
    Icons.calendar_month,
    (s) => s.calendar,
  ),
  ScreenItem(Icons.view_kanban_outlined, Icons.view_kanban, (s) => s.board),
  ScreenItem(Icons.task_alt_outlined, Icons.task_alt, (s) => s.done),
  ScreenItem(Icons.lock_outline_rounded, Icons.lock_rounded, (s) => s.vault),
  ScreenItem(Icons.settings_outlined, Icons.settings, (s) => s.settings),
];

/// The bar's one tab for the three task views. Drawn, not a font icon: a
/// lone checkbox read as a form field, not as a screen of tasks, and the
/// font has no checklist with a tick in its own colour.
final tasksItem = ScreenItem(
  Icons.check_box_outlined,
  Icons.check_box,
  (s) => s.tasks,
  glyph: (selected, color) => _TasksGlyph(selected: selected, color: color),
);

class ScreenItem {
  final IconData icon;
  final IconData activeIcon;
  final String Function(S) label;

  /// Draws the tab in place of [icon] where a font icon won't do.
  final Widget Function(bool selected, Color color)? glyph;

  const ScreenItem(this.icon, this.activeIcon, this.label, {this.glyph});
}

/// A short checklist: a ticked line over an open one. The tick is the one
/// purple in the bar — asked for — dimmer unlit so the tab doesn't outshine
/// the one that is lit; lit, the rest only brightens, since filling the
/// ring would tick it. Two rows of boxes and dashes looked cramped at this
/// size; a clipboard, and a box with a tick breaking out of it, came next.
class _TasksGlyph extends StatelessWidget {
  final bool selected;
  final Color color;

  const _TasksGlyph({required this.selected, required this.color});

  static const purple = Color(0xFF8B6CF0);

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 22,
      child: CustomPaint(
        painter: _TasksPainter(
          ink: color,
          tick: selected ? purple : Color.lerp(purple, color, 0.45)!,
        ),
      ),
    );
  }
}

class _TasksPainter extends CustomPainter {
  final Color ink;
  final Color tick;

  const _TasksPainter({required this.ink, required this.tick});

  @override
  void paint(Canvas canvas, Size size) {
    // In a 22-unit square, near the font icons' weight of two units. The
    // top line ends clear of the overdue dot.
    final u = size.width / 22;
    Paint stroke(double width, Color color) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    canvas.drawPath(
      Path()
        ..moveTo(2.8 * u, 6.6 * u)
        ..lineTo(4.8 * u, 8.6 * u)
        ..lineTo(8.6 * u, 4.6 * u),
      stroke(2.2, tick),
    );
    canvas.drawCircle(Offset(5.6 * u, 15.2 * u), 2.6 * u, stroke(1.9, ink));
    final line = stroke(2.2, ink);
    canvas.drawLine(Offset(11.5 * u, 6.8 * u), Offset(19.5 * u, 6.8 * u), line);
    canvas.drawLine(
      Offset(11.5 * u, 15.2 * u),
      Offset(19.5 * u, 15.2 * u),
      line,
    );
  }

  @override
  bool shouldRepaint(_TasksPainter old) => old.ink != ink || old.tick != tick;
}

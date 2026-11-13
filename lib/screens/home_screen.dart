import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../db/database.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../services/reminders.dart';
import '../services/today_widget.dart';
import '../services/updates.dart';
import '../theme/app_theme.dart';
import '../widgets/quick_add_bar.dart' show BarRoom;
import '../widgets/selection.dart';
import 'board_screen.dart';
import 'calendar_screen.dart';
import 'done_screen.dart';
import 'settings_screen.dart';
import 'task_edit_screen.dart';
import 'tasks_screen.dart';

/// Top-level shell: whichever screen is open, and a bar of the screens
/// floating along the foot of it.
///
/// The screens were behind a menu at the top left of each of them, which
/// slid the screen aside; a bar was asked for after the user saw one they
/// liked ("i strongly like bottoms like this", of a floating pill of tabs).
/// It is one tap where the menu took two, and every screen is always in
/// sight.
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

  /// The two screens with a field run their ground on under the bar and keep
  /// the room clear themselves ([BarRoom]); the rest simply end above it.
  late final List<Widget> _pages = [
    const BarRoom(height: _TabBar.room, child: TasksScreen()),
    const BarRoom(height: _TabBar.room, child: CalendarScreen()),
    _aboveBar(BoardScreen(shown: _boardShown)),
    _aboveBar(DoneScreen(shown: _doneShown)),
    _aboveBar(const SettingsScreen()),
  ];

  static Widget _aboveBar(Widget screen) => Padding(
    padding: const EdgeInsets.only(bottom: _TabBar.room),
    child: screen,
  );

  /// Whether the board and Done are the screen on show, which is when each
  /// reads what it draws.
  late final _boardShown = ValueNotifier<bool>(_index == _board);
  late final _doneShown = ValueNotifier<bool>(_index == _done);

  static final _board = AppScreen.board.index;
  static final _done = AppScreen.done.index;

  /// A release newer than this one, once the check on opening has found it.
  Update? _update;

  @override
  void initState() {
    super.initState();
    // After the first frame rather than before it: the answer comes off the
    // network, and nothing on screen should wait for it.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final update = await Updates.instance.check();
      if (mounted && update != null) setState(() => _update = update);
    });
    TodayWidget.listen(_openFromWidget);
    // One that started the app is already waiting by the first frame.
    Reminders.opened.addListener(_openReminder);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openReminder());
    WidgetsBinding.instance.addObserver(this);
    _checkFullScreen();
    _waitForMidnight();
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
    context.read<TaskProvider>().catchUp();
  }

  /// A reminder tapped with the phone in use opens its task, as a row of
  /// the widget does; over the lock screen the activity shows it itself.
  void _openReminder() {
    final id = Reminders.opened.value;
    if (id == null || !mounted) return;
    Reminders.opened.value = null;
    _openFromWidget(id);
  }

  /// A row of the home-screen widget opens its task's form, and the
  /// widget's plus a new one on today, over whichever screen is showing —
  /// and over nothing else: a form left open from before is closed first.
  Future<void> _openFromWidget(int? id) async {
    final task = id == null ? null : await AppDatabase.instance.getTask(id);
    if (!mounted || (id != null && task == null)) return;
    final navigator = Navigator.of(context)..popUntil((route) => route.isFirst);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => TaskEditScreen(
          task: task,
          initialDate: task == null ? dayOf(DateTime.now()) : null,
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midnight?.cancel();
    Reminders.opened.removeListener(_openReminder);
    _boardShown.dispose();
    _doneShown.dispose();
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
    setState(() => _index = i);
    _boardShown.value = i == _board;
    _doneShown.value = i == _done;
    final provider = context.read<TaskProvider>();
    if (i == AppScreen.schedule.index) provider.loadTasks();
    if (i == AppScreen.calendar.index) provider.loadMonth(provider.month);
  }

  /// The screen back returns to before it leaves the app, as it does in an
  /// app with tabs along the foot: the one the app opened on, or the first
  /// one still in the bar if that has since been taken out of it.
  int _home(Set<AppScreen> hidden) => !hidden.contains(widget.start)
      ? widget.start.index
      : AppScreen.values.firstWhere((s) => !hidden.contains(s)).index;

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
        body: SafeArea(
          // The strip at the foot of the screen stays reserved while the
          // keyboard is over it. Android stops counting the gesture bar as
          // padding the moment the keys cover it, and without this the screen
          // grows by that much as the keyboard arrives — which on a phone
          // drawn edge to edge was the month and the day's tasks shifting
          // slightly every time the add field was tapped. Nothing about the
          // screen should move when the keyboard does; only the field rides
          // it up.
          maintainBottomViewPadding: true,
          child: Stack(
            children: [
              Column(
                children: [
                  // Above whichever screen is open rather than inside one of
                  // them: it is about the app, not about a day.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: Column(
                      children: [
                        const SizedBox(width: double.infinity),
                        if (_update != null)
                          _UpdateBanner(
                            update: _update!,
                            onDismiss: () => setState(() => _update = null),
                          ),
                        if (offerFullScreen)
                          _FullScreenBanner(
                            onAllow: Reminders.instance.requestFullScreen,
                            onDismiss: () =>
                                setState(() => _fullScreenPutOff = true),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: IndexedStack(index: _index, children: _pages),
                  ),
                ],
              ),
              // Over the screen rather than under it, so the ground the
              // screen stands on runs on beneath the bar. The keyboard comes
              // up over it: the field rides the keys and the bar stays behind.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _TabBar(
                  index: _index,
                  hidden: hidden,
                  onSelected: _select,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says a newer Caldo is out, and fetches and installs it on a tap.
///
/// Closing it hides it until the app is next opened, and no longer than
/// that: an update put off is not an update refused, and a banner that could
/// be closed for good would leave nothing anywhere to say one was waiting.
class _UpdateBanner extends StatefulWidget {
  final Update update;
  final VoidCallback onDismiss;

  const _UpdateBanner({required this.update, required this.onDismiss});

  @override
  State<_UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<_UpdateBanner> {
  /// Said in place of the usual line when the last tap did not end in the
  /// install — why not, and what to do about it.
  String? _note;

  Future<void> _install() async {
    setState(() => _note = null);
    try {
      final started = await Updates.instance.install(widget.update);
      if (!mounted) return;
      if (!started) {
        setState(() => _note = S.of(context).allowInstall);
      }
    } catch (_) {
      if (mounted) setState(() => _note = S.of(context).downloadFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context).color;
    return ValueListenableBuilder<DownloadProgress>(
      valueListenable: Updates.instance.progress,
      builder: (context, progress, _) {
        final downloading = progress != null;
        final s = S.of(context);
        final line = downloading
            ? s.downloading(widget.update.version, (progress * 100).round())
            : _note ?? s.updateOut(widget.update.version);
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.system_update_alt_rounded,
                    size: 20,
                    color: accent,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      line,
                      style: TextStyle(color: p.text, fontSize: 14),
                    ),
                  ),
                  if (!downloading) ...[
                    TextButton(
                      onPressed: _install,
                      child: Text(
                        s.update,
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: s.notNow,
                      icon: Icon(Icons.close_rounded, color: p.muted, size: 20),
                      onPressed: widget.onDismiss,
                    ),
                  ] else
                    const SizedBox(height: 48),
                ],
              ),
              if (downloading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 12, 10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      color: accent,
                      backgroundColor: p.field,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Offers to let reminders take the whole screen while the phone is locked,
/// when that has been asked for in Settings and Android does not allow it.
///
/// Drawn as the update banner is, above whichever screen is open. Allow
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
/// show lifted out in a pill of its own that slides to the one picked.
///
/// The board comes after the two that are about when, being about how far
/// along; Done after it, and Settings last: it is a place to look, not a
/// setting. Settings can take any of the four out of it, and is always there
/// itself, as the way to put them back.
///
/// Neutral, as the menu was: the screen on show is lifted in grey, not the
/// accent, which is kept for what is rare.
class _TabBar extends StatelessWidget {
  final int index;
  final Set<AppScreen> hidden;
  final ValueChanged<int> onSelected;

  const _TabBar({
    required this.index,
    required this.hidden,
    required this.onSelected,
  });

  static const _height = 62.0;
  static const _above = 4.0;
  static const _below = 8.0;

  /// The height the bar takes at the foot of a screen, gaps included.
  static const room = _above + _height + _below;

  /// Settings, after the screens [AppScreen] names.
  static final _settings = AppScreen.values.length;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    // Whether there is anything, and nothing else: watching the whole
    // provider rebuilt the bar on every change to every task.
    final overdue = context.select<TaskProvider, bool>(
      (p) => p.allOverdue.isNotEmpty,
    );
    final shown = [
      for (final screen in AppScreen.values)
        if (!hidden.contains(screen)) screen.index,
      _settings,
    ];
    // The overdue backlog is Schedule's, so the dot goes there — or on the
    // calendar, where the overdue days are, when Schedule is out.
    final late = !hidden.contains(AppScreen.schedule)
        ? AppScreen.schedule.index
        : AppScreen.calendar.index;
    final at = shown.indexOf(index);
    const inset = 4.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, _above, 12, _below),
      child: Container(
        height: _height,
        padding: const EdgeInsets.all(inset),
        decoration: BoxDecoration(
          color: p.panelHi,
          borderRadius: BorderRadius.circular(_height / 2),
          border: Border.all(color: p.field),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth / shown.length;
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
                    for (final i in shown)
                      Expanded(
                        child: _Tab(
                          item: menuItems[i],
                          selected: index == i,
                          dot: overdue && i == late,
                          onTap: () => onSelected(i),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final MenuItem item;
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
                        decoration: const BoxDecoration(
                          color: AppColors.overdue,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              // Shrunk rather than cut: five to a phone's width is about
              // nine letters each, and "Einstellungen" has thirteen.
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

/// What the tab bar draws for each screen, in the order of [AppScreen] and
/// Settings last. Settings draws its list of screens from it too, so a
/// screen looks the same in both places.
final menuItems = [
  // A list, not a tick: the screen is a running order of days, and a tick
  // is what sits on each of the rows inside it.
  MenuItem(Icons.list_alt_outlined, Icons.list_alt, (s) => s.schedule),
  MenuItem(
    Icons.calendar_month_outlined,
    Icons.calendar_month,
    (s) => s.calendar,
  ),
  MenuItem(Icons.view_kanban_outlined, Icons.view_kanban, (s) => s.board),
  MenuItem(Icons.task_alt_outlined, Icons.task_alt, (s) => s.done),
  MenuItem(Icons.settings_outlined, Icons.settings, (s) => s.settings),
];

class MenuItem {
  final IconData icon;
  final IconData activeIcon;
  final String Function(S) label;
  const MenuItem(this.icon, this.activeIcon, this.label);
}

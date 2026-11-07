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
import '../utils/dates.dart';
import '../widgets/selection.dart';
import 'board_screen.dart';
import 'calendar_screen.dart';
import 'done_screen.dart';
import 'settings_screen.dart';
import 'task_edit_screen.dart';
import 'tasks_screen.dart';

/// Width the menu takes.
const _menuWidth = 244.0;

/// How far the menu's leading edge lies over the screen.
///
/// The screen slides this much less than the menu is wide, so the two overlap
/// rather than meeting flush. Flush, there is nothing to say which of them is
/// in front — and with the screen the rounded one, it was the screen that read
/// as the panel on top. Now the menu's rounded edge and its shadow fall across
/// the screen, which is the whole of what "above" looks like.
const _menuOverlap = 18.0;

/// Top-level shell. The three destinations live in a menu at the top left of
/// each of them, not in a bar along the bottom.
///
/// Opening it slides the whole screen to the right rather than laying a panel
/// over it: the screen is not covered up, it has moved aside, and what is on
/// it stays legible while the menu is open.
class HomeScreen extends StatefulWidget {
  /// Which screen to open on. Only read as the shell is built: changing the
  /// setting is about the next launch, and a screen that jumped out from
  /// under the setting being changed would be startling.
  final AppScreen start;

  const HomeScreen({super.key, this.start = AppScreen.schedule});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _menu = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 220),
  );

  late final Animation<double> _slide = CurvedAnimation(
    parent: _menu,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  // The pages are in the order of [AppScreen], Settings after them.
  late int _index = widget.start.index;

  late final List<Widget> _pages = [
    TasksScreen(onMenu: _openMenu),
    CalendarScreen(onMenu: _openMenu),
    BoardScreen(onMenu: _openMenu, shown: _boardShown),
    DoneScreen(onMenu: _openMenu, shown: _doneShown),
    SettingsScreen(onMenu: _openMenu),
  ];

  bool get _isOpen => _menu.value > 0.5;

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
    if (state == AppLifecycleState.resumed) _checkFullScreen();
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
    _closeMenu();
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
    Reminders.opened.removeListener(_openReminder);
    _menu.dispose();
    _boardShown.dispose();
    _doneShown.dispose();
    super.dispose();
  }

  /// What is picked out on a screen is put down on the way off it: the
  /// screens stay alive behind the menu, and one left holding a selection
  /// would have back answer to it from somewhere else.
  void _openMenu() {
    Selection.dropAll();
    _menu.forward();
  }

  void _closeMenu() => _menu.reverse();

  /// Switch screens, refreshing the dated views so they stay correct across a
  /// midnight rollover or edits made from another one.
  void _select(int i) {
    _closeMenu();
    if (i == _index) return;
    setState(() => _index = i);
    _boardShown.value = i == _board;
    _doneShown.value = i == _done;
    final provider = context.read<TaskProvider>();
    if (i == AppScreen.schedule.index) provider.loadTasks();
    if (i == AppScreen.calendar.index) provider.loadMonth(provider.month);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    // Offered only to someone who wants full-screen reminders and is not
    // getting them: switched off in Settings, it is not asked about again.
    final wantsFullScreen = context.select<SettingsProvider, bool>(
      (s) => s.loaded && s.reminders && s.fullScreenReminders,
    );
    final offerFullScreen =
        wantsFullScreen && _fullScreenAllowed == false && !_fullScreenPutOff;
    return PopScope(
      // While the menu is open, back closes it rather than leaving the app.
      canPop: !_isOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeMenu();
      },
      child: Scaffold(
        backgroundColor: p.sidebar,
        // Each screen decides for itself what the keyboard does to it. Resize
        // here and the shell shortens all three before any of them is asked.
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            AnimatedBuilder(
              animation: _slide,
              builder: (context, child) => Transform.translate(
                offset: Offset((_menuWidth - _menuOverlap) * _slide.value, 0),
                child: child,
              ),
              child: _Screen(
                // The screen keeps every pixel it had; it has only moved, so
                // nothing on it reflows as the menu opens.
                onTapWhileOpen: _closeMenu,
                isOpen: _menu,
                child: SafeArea(
                  // The strip at the foot of the screen stays reserved while
                  // the keyboard is over it. Android stops counting the
                  // gesture bar as padding the moment the keys cover it, and
                  // without this the screen grows by that much as the
                  // keyboard arrives — which on a phone drawn edge to edge
                  // was the month and the day's tasks shifting slightly every
                  // time the add field was tapped. Nothing about the screen
                  // should move when the keyboard does; only the field rides
                  // it up.
                  maintainBottomViewPadding: true,
                  child: Column(
                    children: [
                      // Above whichever screen is open rather than inside
                      // one of them: it is about the app, not about a day.
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
                ),
              ),
            ),
            // On top of the screen and sliding in from off the left edge, so
            // it reads as a panel lifted above the window rather than
            // something uncovered behind it. It laps over the screen's edge by
            // `_menuOverlap`, which is what shows it is in front.
            AnimatedBuilder(
              animation: _slide,
              builder: (context, child) => Transform.translate(
                offset: Offset(-_menuWidth * (1 - _slide.value), 0),
                child: child,
              ),
              child: SizedBox(
                width: _menuWidth,
                child: _Menu(index: _index, onSelected: _select),
              ),
            ),
          ],
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
  /// installer — why not, and what to do about it.
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

/// The screen as it sits under the menu: a plain slab, its leading edge run
/// beneath the menu's rounded one, swallowing taps while the menu is open so
/// the first tap back on it is a close rather than a stray press.
///
/// It is deliberately square. Rounded, it read as the card on top — two
/// rounded edges meeting flush say nothing about which is in front, and the
/// one that is rounded and lit is the one the eye puts there.
class _Screen extends StatelessWidget {
  final Animation<double> isOpen;
  final VoidCallback onTapWhileOpen;
  final Widget child;

  const _Screen({
    required this.isOpen,
    required this.onTapWhileOpen,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return AnimatedBuilder(
      animation: isOpen,
      builder: (context, inner) {
        final t = isOpen.value;
        return DecoratedBox(
          decoration: BoxDecoration(color: p.bg),
          child: Stack(
            children: [
              inner!,
              if (t > 0)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTapWhileOpen,
                    onHorizontalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) < 0) onTapWhileOpen();
                    },
                  ),
                ),
            ],
          ),
        );
      },
      child: child,
    );
  }
}

/// The drawer behind the menu button: the screens, the current one picked
/// out. The board comes after the two that are about when, being about how
/// far along; Done under it, and above Settings: it is a place to look, not
/// a setting. Settings can take any of the four out of it, and is always
/// there itself, as the way to put them back.
class _Menu extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelected;

  const _Menu({required this.index, required this.onSelected});

  /// Settings, after the screens [AppScreen] names.
  static final _settings = AppScreen.values.length;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    // The count and nothing else: watching the whole provider rebuilt the
    // menu on every change to every task.
    final overdue = context.select<TaskProvider, int>(
      (p) => p.allOverdue.length,
    );
    final hidden = context.select<SettingsProvider, Set<AppScreen>>(
      (s) => s.hiddenScreens,
    );
    final shown = [
      for (final screen in AppScreen.values)
        if (!hidden.contains(screen)) screen.index,
      _settings,
    ];
    // The overdue backlog is Schedule's, so the count goes there — or on
    // the calendar, where the overdue days are, when Schedule is out.
    final late = !hidden.contains(AppScreen.schedule)
        ? AppScreen.schedule.index
        : AppScreen.calendar.index;

    return Material(
      color: p.sidebar,
      // Rounded off down its leading edge and shadowed, so it sits above the
      // window rather than flush against it.
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(24)),
      elevation: 16,
      shadowColor: Colors.black.withValues(alpha: 0.6),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Caldo',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Dates.longDay(DateTime.now()),
                    style: TextStyle(color: p.faint, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            const SizedBox(height: 8),
            for (final i in shown)
              _MenuItem(
                item: menuItems[i],
                selected: index == i,
                // The overdue backlog is what the dot on the button stands
                // for, so the menu says how much of it there is.
                badge: i == late && overdue > 0 ? overdue : null,
                onTap: () => onSelected(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final MenuItem item;
  final bool selected;
  final int? badge;
  final VoidCallback onTap;

  const _MenuItem({
    required this.item,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    // The screen that is open is the one lifted out in the neutral; it was
    // the accent, icon and row both, on a panel of otherwise quiet greys.
    final color = selected ? p.text : p.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? p.field : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Icon(
                  selected ? item.activeIcon : item.icon,
                  color: color,
                  size: 22,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    item.label(S.of(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? p.text : p.muted,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.overdue.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                        color: AppColors.overdue,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the menu draws for each screen, in the order of [AppScreen] and
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

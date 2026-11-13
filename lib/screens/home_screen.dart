import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../db/database.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../services/backup.dart';
import '../services/reminders.dart';
import '../services/today_widget.dart';
import '../services/updates.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/menu_button.dart' show MenuScope;
import '../widgets/quick_add_bar.dart' show BarFoot, BarRoom, KeyboardGap;
import '../widgets/selection.dart';
import '../widgets/tick_off.dart' show UndoSlot, withdrawUndo;
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

/// Top-level shell: whichever screen is open, and the way between them —
/// a bar of the screens floating along the foot, or a menu behind a button
/// at the top left of each, as Settings says.
///
/// The menu came first; the bar was asked for after the user saw one they
/// liked ("i strongly like bottoms like this", of a floating pill of tabs),
/// and the menu was then asked back as a choice. The bar is one tap where
/// the menu took two; the menu leaves the screens their full height.
///
/// The menu slides the whole screen to the right rather than laying a panel
/// over it: the screen is not covered up, it has moved aside, and what is on
/// it stays legible while the menu is open.
class HomeScreen extends StatefulWidget {
  /// Which screen to open on. Only read as the shell is built: changing the
  /// setting is about the next launch, and a screen that jumped out from
  /// under the setting being changed would be startling.
  final AppScreen start;

  /// Whether the screens are in the tab bar, as stored when the app was
  /// started — in force until the settings have been read.
  final bool inBar;

  const HomeScreen({
    super.key,
    this.start = AppScreen.schedule,
    this.inBar = true,
  });

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
    const TasksScreen(),
    const CalendarScreen(),
    BoardScreen(shown: _boardShown),
    DoneScreen(shown: _doneShown),
    const SettingsScreen(),
  ];

  /// What the two screens with a field lend the bar: their field, for the
  /// plus, and their Undo and selection, for the bar's place.
  final _feet = [BarFoot(), BarFoot()];

  BarFoot? get _foot => _index < _feet.length ? _feet[_index] : null;

  /// A page with the room the bar takes at its foot. The two screens with a
  /// field run their ground on under the bar and rest their field in its
  /// room ([BarRoom]); the rest simply end above it. Both wrappers are
  /// there with no bar as well, at nothing, so switching the setting keeps
  /// every screen's state.
  Widget _room(int i, bool inBar) => BarRoom(
    height: inBar ? BarRoom.room : 0,
    foot: inBar && i < _feet.length ? _feet[i] : null,
    child: i < _feet.length
        ? _pages[i]
        : Padding(
            padding: EdgeInsets.only(bottom: inBar ? BarRoom.room : 0),
            child: _pages[i],
          ),
  );

  /// The plus above the bar brings up the screen's field on the keyboard;
  /// held, it is the full form. It is only there on the two screens with a
  /// field.
  void _add() => _foot?.open?.call();

  void _addInFull() => _foot?.form?.call();

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
    // Back closes the menu while it is open, so the shell is built again as
    // it starts to open and once it has shut.
    _menu.addStatusListener((_) => setState(() {}));
    _checkFullScreen();
    _waitForMidnight();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => Backup.autoIfDue(context.read<SettingsProvider>()),
    );
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
    Backup.autoIfDue(context.read<SettingsProvider>());
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
    _midnight?.cancel();
    Reminders.opened.removeListener(_openReminder);
    _menu.dispose();
    for (final foot in _feet) {
      foot.dispose();
    }
    _boardShown.dispose();
    _doneShown.dispose();
    super.dispose();
  }

  /// What is picked out on a screen is put down on the way off it: the
  /// screens stay alive behind one another, and one left holding a selection
  /// would have back answer to it from out of sight. Opening the menu is the
  /// way off with no bar.
  void _openMenu() {
    Selection.dropAll();
    withdrawUndo();
    _menu.forward();
  }

  void _closeMenu() => _menu.reverse();

  /// Switch screens, refreshing the dated views so they stay correct across a
  /// midnight rollover or edits made from another one.
  void _select(int i) {
    _closeMenu();
    if (i == _index) return;
    Selection.dropAll();
    withdrawUndo();
    setState(() => _index = i);
    _boardShown.value = i == _board;
    _doneShown.value = i == _done;
    final provider = context.read<TaskProvider>();
    if (i == AppScreen.schedule.index) provider.loadTasks();
    if (i == AppScreen.calendar.index) provider.loadMonth(provider.month);
  }

  /// The screen back returns to before it leaves the app, as it does in an
  /// app with tabs along the foot: the one the app opened on, or the first
  /// one still in the bar if that has since been taken out of it. With the
  /// menu, back leaves from wherever it is, as it always did.
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
    final inBar = context.select<SettingsProvider, bool>(
      (s) => s.screensInBarIfKnown ?? widget.inBar,
    );
    // Offered only to someone who wants full-screen reminders and is not
    // getting them: switched off in Settings, it is not asked about again.
    final wantsFullScreen = context.select<SettingsProvider, bool>(
      (s) => s.loaded && s.reminders && s.fullScreenReminders,
    );
    final offerFullScreen =
        wantsFullScreen && _fullScreenAllowed == false && !_fullScreenPutOff;
    final screen = SafeArea(
      // The strip at the foot of the screen stays reserved while the
      // keyboard is over it. Android stops counting the gesture bar as
      // padding the moment the keys cover it, and without this the screen
      // grows by that much as the keyboard arrives — which on a phone drawn
      // edge to edge was the month and the day's tasks shifting slightly
      // every time the add field was tapped. Nothing about the screen should
      // move when the keyboard does; only the field rides it up.
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
                child: MenuScope(
                  open: inBar ? null : _openMenu,
                  child: IndexedStack(
                    index: _index,
                    children: [
                      for (var i = 0; i < _pages.length; i++) _room(i, inBar),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // Over the screen rather than under it, so the ground the screen
          // stands on runs on beneath the bar. It goes while the keyboard is
          // up: the screen's field is brought up in its place and rides the
          // keys, and the bar stays behind them.
          if (inBar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _WhileKeyboardDown(
                child: ListenableBuilder(
                  listenable: Listenable.merge([?_foot, ?_foot?.selection]),
                  builder: (context, _) => _TabBar(
                    index: _index,
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
      canPop: !_isOpen && (!inBar || _index == home),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_isOpen) {
          _closeMenu();
        } else if (inBar && !Selection.anyActive) {
          // Back puts down what is picked out first; the selection answers
          // to it on its own.
          _select(home);
        }
      },
      child: Scaffold(
        backgroundColor: inBar ? p.bg : p.sidebar,
        // Each screen decides for itself what the keyboard does to it. Resize
        // here and the shell shortens all of them before any of them is asked.
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
                // The slide's own curve, so the blur keeps pace with the
                // menu rather than with the clock.
                isOpen: _slide,
                child: screen,
              ),
            ),
            // On top of the screen and sliding in from off the left edge, so
            // it reads as a panel lifted above the window rather than
            // something uncovered behind it. It laps over the screen's edge by
            // `_menuOverlap`, which is what shows it is in front.
            if (!inBar)
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

/// The screen as it sits under the menu: a plain slab, its leading edge run
/// beneath the menu's rounded one, swallowing taps while the menu is open so
/// the first tap back on it is a close rather than a stray press.
///
/// It is deliberately square. Rounded, it read as the card on top — two
/// rounded edges meeting flush say nothing about which is in front, and the
/// one that is rounded and lit is the one the eye puts there.
///
/// It goes out of focus as the menu comes over it, so the menu is the one
/// thing to read while it is open ([_OutOfFocus]).
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
              _OutOfFocus(open: isOpen, ground: p.bg, child: inner!),
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

/// The screen, with blurred pictures of it laid over as the menu opens.
///
/// The picture is taken once, when the menu starts to open, and blurred
/// once at each of a few strengths; each frame of the slide only fades from
/// one strength to the next. Blurring the screen
/// itself (`ImageFiltered`) drew the whole of it offscreen and blurred that
/// at full resolution on every frame, with a new radius each time — on the
/// emulator it put 2–3ms of raster on every frame of the slide, and a third
/// of them past the 8ms a 120Hz phone has: "a bit laggy".
///
/// The live screen goes on being drawn under the picture rather than
/// replaced by it, so a screen picked from the menu is already there as
/// the menu closes, with the picture of the old one fading off it.
class _OutOfFocus extends SingleChildRenderObjectWidget {
  final Animation<double> open;

  /// Painted under the picture, so it is opaque: through a blurred letter's
  /// soft edge, the sharp one underneath would show.
  final Color ground;

  const _OutOfFocus({
    required this.open,
    required this.ground,
    required super.child,
  });

  @override
  _RenderOutOfFocus createRenderObject(BuildContext context) =>
      _RenderOutOfFocus(open, ground);

  @override
  void updateRenderObject(BuildContext context, _RenderOutOfFocus render) {
    render
      ..open = open
      ..ground = ground;
  }
}

class _RenderOutOfFocus extends RenderProxyBox {
  _RenderOutOfFocus(this._open, this.ground);

  /// How far out of focus the screen is with the menu all the way open.
  /// It was 6, and "a little less blurry" was asked for.
  static const _blur = 4.0;

  /// How many strengths the blur is taken at, evenly up to [_blur]. One,
  /// faded in over the sharp screen, did not read as a blur growing: the
  /// sharp edges show through until the picture is all but opaque, so the
  /// blur seemed to arrive late and at once. Faded from each strength to
  /// the next, it grows as the menu comes in.
  static const _steps = 4;

  /// Pixels per point the pictures are taken at. A blur leaves nothing a
  /// finer picture would show, and a quarter of the pixels is a quarter of
  /// the work to take one and to draw it.
  static const _scale = 0.5;

  Animation<double> _open;
  set open(Animation<double> value) {
    if (value == _open) return;
    if (attached) {
      _open.removeListener(_changed);
      value.addListener(_changed);
    }
    _open = value;
    _changed();
  }

  Color ground;

  /// The screen at each strength, the weakest first.
  List<ui.Image>? _pictures;

  void _letGo() {
    for (final picture in _pictures ?? const <ui.Image>[]) {
      picture.dispose();
    }
    _pictures = null;
  }

  void _changed() {
    // Shut, they are let go of, so the next opening takes the screen as it
    // is by then.
    if (_open.value <= 0) _letGo();
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _open.addListener(_changed);
  }

  @override
  void detach() {
    _open.removeListener(_changed);
    super.detach();
  }

  @override
  void dispose() {
    _letGo();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final t = _open.value.clamp(0.0, 1.0);
    if (t > 0 && _pictures == null && !size.isEmpty) _pictures = _take();
    super.paint(context, offset);
    final pictures = _pictures;
    if (t == 0 || pictures == null) return;
    // Every picture is opaque, so the weaker of the two neighbours is drawn
    // whole and the stronger faded in over it; below the first, the live
    // screen is the weaker one.
    final at = t * _steps;
    final below = at.floor().clamp(0, _steps);
    final fraction = at - below;
    if (below > 0) _draw(context.canvas, offset, pictures[below - 1], 1);
    if (below < _steps && fraction > 0) {
      _draw(context.canvas, offset, pictures[below], fraction);
    }
  }

  void _draw(Canvas canvas, Offset offset, ui.Image picture, double alpha) {
    canvas.drawImageRect(
      picture,
      Offset.zero & Size(picture.width.toDouble(), picture.height.toDouble()),
      offset & size,
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, alpha)
        ..filterQuality = FilterQuality.low,
    );
  }

  /// The screen at [_scale], on its ground, blurred at each strength.
  List<ui.Image> _take() {
    // Painted into a layer of its own and let go of again, as
    // `SnapshotWidget` does; the screen is then painted in place as usual.
    final layer = OffsetLayer();
    final context = PaintingContext(layer, Offset.zero & size);
    super.paint(context, Offset.zero);
    // ignore: invalid_use_of_protected_member
    context.stopRecordingIfNeeded();
    final sharp = layer.toImageSync(Offset.zero & size, pixelRatio: _scale);
    layer.dispose();

    final w = sharp.width, h = sharp.height;
    final pictures = [
      for (var step = 1; step <= _steps; step++)
        _blurred(sharp, w, h, _blur * _scale * step / _steps),
    ];
    sharp.dispose();
    return pictures;
  }

  ui.Image _blurred(ui.Image sharp, int w, int h, double sigma) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = ground,
    );
    canvas.drawImage(
      sharp,
      Offset.zero,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          // Clamped, so the screen's edges do not fade into a dark rim
          // against the menu.
          tileMode: TileMode.clamp,
        ),
    );
    final picture = recorder.endRecording();
    final blurred = picture.toImageSync(w, h);
    picture.dispose();
    return blurred;
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

/// The screens, in a pill floating along the foot of the window, the one on
/// show lifted out in a pill of its own that slides to the one picked, and
/// a round plus floating above its far end for a new task.
///
/// The board comes after the two that are about when, being about how far
/// along; Done after it, and Settings last: it is a place to look, not a
/// setting. Settings can take any of the four out of it, and is always there
/// itself, as the way to put them back.
///
/// Neutral, as the menu is: the screen on show is lifted in grey, not the
/// accent, which is kept for what is rare.
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
  final Set<AppScreen> hidden;
  final BarFoot? foot;
  final ValueChanged<int> onSelected;
  final VoidCallback onAdd;
  final VoidCallback onAddInFull;

  const _TabBar({
    required this.index,
    required this.hidden,
    required this.foot,
    required this.onSelected,
    required this.onAdd,
    required this.onAddInFull,
  });

  static const _height = BarRoom.pill;

  /// Settings, after the screens [AppScreen] names.
  static final _settings = AppScreen.values.length;

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
    // The picked tab's pill all but touches the rim, as on the bar this was
    // matched to: four points in, it was a pill floating inside a pill. A
    // seam of the bar's fill is kept, or the pill's grey runs into the rim
    // and the rim is lost round the picked tab.
    const inset = 1.0;
    return Container(
      padding: const EdgeInsets.all(inset),
      decoration: BoxDecoration(
        color: p.panelHi,
        borderRadius: BorderRadius.circular(_height / 2),
        border: Border.all(color: BarRoom.rim(p), width: BarRoom.rimWidth),
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
    );
  }
}

/// Identifies the tab bar's pill.
const tabBarKey = Key('tab-bar');

/// Identifies the plus above the tab bar.
const barAddKey = Key('bar-add');

/// The plus, a disc in the bar's own grey and edge, so the two read as a
/// pair at the foot. Plain, as the plus beside the field was: it is pressed
/// often and looked at rarely. Shadowed, since it floats over the cards.
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
      child: Material(
        key: barAddKey,
        color: p.panelHi,
        shape: CircleBorder(
          side: BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth),
        ),
        elevation: 6,
        shadowColor: Colors.black,
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
    );
  }
}

/// Draws [child] only while the keyboard is down. With it up, the screen's
/// field is in the bar's place, riding the keys, and the bar is behind them
/// anyway — but not for the first frames of a slide, when the field would
/// be coming up through it. Reads the lift, so it is rebuilt on every frame
/// of one; it is the smallest widget that can.
class _WhileKeyboardDown extends StatelessWidget {
  final Widget child;

  const _WhileKeyboardDown({required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: KeyboardGap.instance.covered,
      builder: (context, _, child) {
        final down = KeyboardGap.of(context) <= 0;
        return IgnorePointer(
          ignoring: !down,
          child: Opacity(opacity: down ? 1 : 0, child: child),
        );
      },
      child: child,
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

/// What the tab bar and the menu draw for each screen, in the order of [AppScreen] and
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

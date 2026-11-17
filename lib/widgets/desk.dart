import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/task.dart';
import '../utils/platform.dart';

/// Whether Caldo is laid out as a desktop program rather than as a phone's
/// app: a sidebar of the screens and the groups down the left, each screen
/// drawn for the width it has, and a task's form in a panel at the right.
///
/// The first Linux build was the phone's app in a window, held to a phone's
/// width in the middle of whatever room it was given ([PhoneWide]). That is
/// still what a narrow window gets — a tiled half of a small screen is the
/// shape of a phone — and a window wide enough for more gets this.
///
/// Asked through [wideOf] by whatever draws differently for it. Nothing
/// above a screen pumped on its own in a test provides it, and the tests are
/// told they are on a phone besides, so there it is always narrow.
class Desk extends InheritedWidget {
  final bool wide;

  const Desk({super.key, required this.wide, required super.child});

  /// The narrowest window laid out wide: the sidebar, a column of cards and
  /// the form's panel beside it, with nothing squeezed.
  static const breakpoint = 900.0;

  /// The sidebar's width.
  static const sidebar = 236.0;

  /// The width of what stands down the right: the calendar's day, and a
  /// task's form. One width for both, so the form covers the day exactly
  /// and the month beside it does not move.
  static const side = 384.0;

  /// The widest a run of cards is drawn. Past this a card is a stripe and a
  /// title is a long way from its time.
  static const column = 760.0;

  static bool wideOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Desk>()?.wide ?? false;

  /// The same, for asking outside a build — as something is tapped — where
  /// there is nothing to redraw when the answer changes.
  static bool isWide(BuildContext context) =>
      context.getInheritedWidgetOfExactType<Desk>()?.wide ?? false;

  /// The room either side of a column of [column] in a box [width] wide.
  static double gutter(double width) =>
      width > column ? (width - column) / 2 : 0;

  @override
  bool updateShouldNotify(Desk old) => old.wide != wide;
}

/// Decides between the two layouts, above the navigator, so a sheet or a
/// dialog can ask as readily as a screen.
///
/// The window's width decides — but only while nothing is open over the
/// screens. A form with something typed in it is a panel in one layout and
/// a page in the other, and a window dragged across the line would have
/// taken it away with the layout it was in; so the layout in force is kept
/// until the form, the page or the dialog has been closed.
class DeskScope extends StatefulWidget {
  final GlobalKey<NavigatorState> navigator;
  final Widget Function(BuildContext context, bool wide) builder;

  const DeskScope({super.key, required this.navigator, required this.builder});

  /// Tells the scope a route has come or gone, which is when a layout held
  /// back can be changed.
  static final observer = _Routes();

  @override
  State<DeskScope> createState() => _DeskScopeState();
}

class _Routes extends NavigatorObserver {
  final changed = ValueNotifier<int>(0);

  // After the frame: a route comes and goes while the navigator is being
  // built or torn down.
  void _tell() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => changed.value++);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _tell();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _tell();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _tell();
}

class _DeskScopeState extends State<DeskScope> {
  bool? _wide;

  late final _changes = Listenable.merge([
    TaskPanel.instance,
    DeskScope.observer.changed,
  ]);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return ListenableBuilder(
      listenable: _changes,
      builder: (context, _) {
        final wanted = onDesktop && width >= Desk.breakpoint;
        final busy =
            TaskPanel.instance.isOpen ||
            (widget.navigator.currentState?.canPop() ?? false);
        final wide = _wide = busy ? (_wide ?? wanted) : wanted;
        return Desk(wide: wide, child: widget.builder(context, wide));
      },
    );
  }
}

/// A task's form as the wide layout shows it: in a panel down the right of
/// the window, with the list or the month it was opened from still on show
/// beside it.
///
/// One for the app. Whatever opens a form asks this for it (`openTaskForm`),
/// and the shell draws what it holds. A form with changes in it is not
/// replaced by a click on another task: it is [nudged] instead, and its
/// Cancel and Save answer for it.
class TaskPanel extends ChangeNotifier {
  TaskPanel._();

  static final instance = TaskPanel._();

  FormRequest? _request;

  /// The form on show, or null for none.
  FormRequest? get request => _request;

  bool get isOpen => _request != null;

  /// Whether the form on show has been changed since it opened; the form
  /// says.
  bool dirty = false;

  /// Goes up each time a form with changes in it was asked to give way.
  final nudged = ValueNotifier<int>(0);

  void open({Task? task, DateTime? date}) {
    if (_request != null && dirty) {
      nudged.value++;
      return;
    }
    // The task already open is left as it is, scrolled where it was.
    if (task != null && _request?.task?.id == task.id) return;
    _request = FormRequest(task: task, date: date);
    dirty = false;
    notifyListeners();
  }

  void close() {
    if (_request == null) return;
    _request = null;
    dirty = false;
    notifyListeners();
  }
}

/// What a form was opened on: a task to edit, or none and the day a new one
/// starts on. Each is a form of its own, so the panel is keyed by it.
class FormRequest {
  final Task? task;
  final DateTime? date;

  const FormRequest({this.task, this.date});
}

/// Holds a column of cards to [Desk.column] in the middle of a wide window,
/// and leaves a phone's alone.
class DeskColumn extends StatelessWidget {
  final Widget child;

  const DeskColumn({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!Desk.wideOf(context)) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Desk.column),
        child: child,
      ),
    );
  }
}

/// Builds a list that scrolls across the whole of a wide window while its
/// rows keep to the column in the middle: [builder] is handed the room to
/// leave either side, which is nothing on a phone.
///
/// The list itself is not narrowed. A wheel turned over the empty room
/// beside a narrowed list scrolls nothing, and most of a wide window is
/// that room.
class DeskGutter extends StatelessWidget {
  final Widget Function(BuildContext context, double gutter) builder;

  const DeskGutter({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    if (!Desk.wideOf(context)) return builder(context, 0);
    return LayoutBuilder(
      builder: (context, box) => builder(context, Desk.gutter(box.maxWidth)),
    );
  }
}

/// How the wide layout scrolls: by the wheel and the trackpad, and not by
/// dragging with the mouse.
///
/// In a window the shape of a phone a drag of the mouse scrolls, as a finger
/// does (`DesktopScrolling`), because everything there is swiped. Here a
/// drag is for picking a card up — at once, with no long press — and a list
/// that took the same drag for a scroll would get to it first.
class WideScrolling extends MaterialScrollBehavior {
  const WideScrolling();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// Picks a card up as soon as the mouse has dragged it a little way.
///
/// Flutter's own immediate drag takes two points of movement for a drag,
/// under a mouse, and a click is rarely that still: a card clicked to be
/// opened came up to be carried instead, and the click was lost. Six points
/// is a drag meant as one.
class MouseDragRecognizer extends MultiDragGestureRecognizer {
  MouseDragRecognizer({super.debugOwner});

  static const slop = 6.0;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _MouseDragState(event.position, event.kind, gestureSettings);

  @override
  String get debugDescription => 'mouse drag';
}

class _MouseDragState extends MultiDragPointerState {
  _MouseDragState(super.initialPosition, super.kind, super.gestureSettings);

  @override
  void checkForResolutionAfterMove() {
    if (pendingDelta!.distance > MouseDragRecognizer.slop) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}

class _MouseDragStartListener extends ReorderableDragStartListener {
  const _MouseDragStartListener({
    super.key,
    required super.child,
    required super.index,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      MouseDragRecognizer(debugOwner: this);
}

/// What picks a row of a reorderable list up: a long press on a phone, and
/// in the wide layout the drag itself.
Widget pickUpListener(
  BuildContext context, {
  required Key key,
  required int index,
  required Widget child,
}) => Desk.wideOf(context)
    ? _MouseDragStartListener(key: key, index: index, child: child)
    : ReorderableDelayedDragStartListener(key: key, index: index, child: child);

/// A [Draggable] picked up as [MouseDragRecognizer] picks a card up.
class MouseDraggable<T extends Object> extends Draggable<T> {
  const MouseDraggable({
    super.key,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.dragAnchorStrategy,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDragEnd,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => MouseDragRecognizer()..onStart = onStart;
}

/// The keys a desktop has that a phone does not.
///
/// Escape is its Back: it leaves a page or a sheet, puts down what is
/// picked out, closes the form's panel or the menu — whatever Back would
/// have done on a phone, asked of the same navigator. A field that wants
/// the key for itself, as the add field does to close, is nearer the focus
/// and has it first.
///
/// The rest are the wide layout's: Ctrl+N for a new task, Ctrl+F or Ctrl+K
/// to search, Ctrl+1 to 6 for the screens in the sidebar's order, and on
/// the calendar the arrows for the day, Page Up and Down for the month and
/// Home or T for today. Not while a dialog is open over the screens, and
/// the plain keys not while something is being typed: an arrow in a field
/// moves its caret.
///
/// Heard here, above the navigator, rather than in the shell: with nothing
/// focused the focus is the route's own, which is above the shell, and a
/// key bound down there would only work after a click on something.
class DeskKeys extends StatelessWidget {
  final GlobalKey<NavigatorState> navigator;
  final bool wide;
  final Widget child;

  const DeskKeys({
    super.key,
    required this.navigator,
    required this.wide,
    required this.child,
  });

  /// Whether the focus is in a field being typed in.
  static bool get typing {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keys = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) navigator.currentState?.maybePop();
      return KeyEventResult.handled;
    }
    if (!wide || (navigator.currentState?.canPop() ?? false)) {
      return KeyEventResult.ignored;
    }
    final act = DeskActions.instance;
    if (keys.isControlPressed && !keys.isAltPressed) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final screen = _digits.indexOf(key);
      if (key == LogicalKeyboardKey.keyN) {
        act.newTask?.call();
      } else if (key == LogicalKeyboardKey.keyF ||
          key == LogicalKeyboardKey.keyK) {
        act.search?.call();
      } else if (screen >= 0) {
        act.show?.call(screen);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    final step = act.step;
    if (step == null ||
        !act.onCalendar ||
        typing ||
        keys.isAltPressed ||
        keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        step(days: -1);
      case LogicalKeyboardKey.arrowRight:
        step(days: 1);
      case LogicalKeyboardKey.arrowUp:
        step(days: -7);
      case LogicalKeyboardKey.arrowDown:
        step(days: 7);
      case LogicalKeyboardKey.pageUp:
        step(months: -1);
      case LogicalKeyboardKey.pageDown:
        step(months: 1);
      case LogicalKeyboardKey.home || LogicalKeyboardKey.keyT:
        act.today?.call();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static const _digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
  ];

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: child,
    );
  }
}

/// What the keys ask for in the wide layout, said by whoever can do it: the
/// shell, and the calendar for its arrows. The keys themselves are heard
/// above the navigator (`DeskKeys`), where a key reaches whatever has the
/// focus or nothing has.
class DeskActions {
  DeskActions._();

  static final instance = DeskActions._();

  VoidCallback? newTask;
  VoidCallback? search;

  /// Shows a screen, by its place in the sidebar.
  ValueChanged<int>? show;

  /// Whether the calendar is the screen on show, which is when the arrows
  /// are its to answer.
  bool onCalendar = false;

  /// Moves the calendar's day by so many days, or its month by so many
  /// months.
  void Function({int days, int months})? step;

  /// Takes the calendar back to today.
  VoidCallback? today;
}

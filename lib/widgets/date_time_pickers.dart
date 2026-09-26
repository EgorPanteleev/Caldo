import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../providers/task_provider.dart' show dayOf;
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'month_grid.dart';

/// Asks for a date with the app's own calendar instead of the Material
/// dialog. Returns null when the sheet is dismissed.
Future<DateTime?> showAppDatePicker({
  required BuildContext context,
  DateTime? initial,
  DateTime? firstDate,
  DateTime? lastDate,
}) {
  final now = dayOf(DateTime.now());
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _Sheet(
      child: _DateSheet(
        initial: initial ?? now,
        firstDate: firstDate ?? DateTime(now.year - 5),
        lastDate: lastDate ?? DateTime(now.year + 10),
      ),
    ),
  );
}

/// Asks for a time of day on scroll wheels instead of the Material clock
/// dial. Returns null when the sheet is dismissed.
Future<TimeOfDay?> showAppTimePicker({
  required BuildContext context,
  TimeOfDay? initial,
}) {
  return showModalBottomSheet<TimeOfDay>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _Sheet(
      child: _TimeSheet(
        initial: initial ?? const TimeOfDay(hour: 9, minute: 0),
      ),
    ),
  );
}

/// The rounded panel every picker sits in, with a drag handle on top.
class _Sheet extends StatelessWidget {
  final Widget child;
  const _Sheet({required this.child});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: p.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: p.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Scrollable, so a small screen or a large font scale can never
            // overflow the sheet — it just scrolls.
            Flexible(child: SingleChildScrollView(child: child)),
          ],
        ),
      ),
    );
  }
}

// ---- Date -----------------------------------------------------------------

class _DateSheet extends StatefulWidget {
  final DateTime initial;
  final DateTime firstDate;
  final DateTime lastDate;

  const _DateSheet({
    required this.initial,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<_DateSheet> createState() => _DateSheetState();
}

class _DateSheetState extends State<_DateSheet> {
  static const _basePage = 6000;

  late final DateTime _baseMonth;
  late final PageController _controller;
  late DateTime _shown;

  @override
  void initState() {
    super.initState();
    _baseMonth = DateTime(widget.initial.year, widget.initial.month);
    _shown = _baseMonth;
    _controller = PageController(initialPage: _basePage);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  DateTime _monthOfPage(int page) =>
      DateTime(_baseMonth.year, _baseMonth.month + (page - _basePage));

  void _step(int by) {
    final page = (_controller.page?.round() ?? _basePage) + by;
    _controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final mondayFirst = context.watch<SettingsProvider>().weekStartsMonday;
    final today = dayOf(DateTime.now());

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetHeader(
          title: Dates.monthTitle(_shown),
          onPrevious: () => _step(-1),
          onNext: () => _step(1),
        ),
        WeekdayRow(mondayFirst: mondayFirst),
        SizedBox(
          height: 290,
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (i) => setState(() => _shown = _monthOfPage(i)),
            itemBuilder: (context, i) => MonthGrid(
              month: _monthOfPage(i),
              selected: widget.initial,
              mondayFirst: mondayFirst,
              firstDate: widget.firstDate,
              lastDate: widget.lastDate,
              onSelect: (day) => Navigator.of(context).pop(day),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _QuickChip(
                label: 'Today',
                onTap: () => Navigator.of(context).pop(today),
              ),
              _QuickChip(
                label: 'Tomorrow',
                onTap: () => Navigator.of(
                  context,
                ).pop(today.add(const Duration(days: 1))),
              ),
              _QuickChip(
                label: 'Next week',
                onTap: () => Navigator.of(
                  context,
                ).pop(today.add(const Duration(days: 7))),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Time -----------------------------------------------------------------

/// The height of one row of a wheel, and of the whole drum.
const _itemExtent = 56.0;
const _wheelHeight = 224.0;

/// Where the window down the middle of the mask starts and stops: one row's
/// worth, centred, so it lines up exactly with the value a wheel parks on.
const _bandTop = (_wheelHeight - _itemExtent) / 2 / _wheelHeight;
const _bandBottom = 1 - _bandTop;

class _TimeSheet extends StatefulWidget {
  final TimeOfDay initial;
  const _TimeSheet({required this.initial});

  @override
  State<_TimeSheet> createState() => _TimeSheetState();
}

class _TimeSheetState extends State<_TimeSheet> {
  late int _hour = widget.initial.hour;
  late int _minute = widget.initial.minute;

  /// The hour as the wheel shows it: 1 to 12, with midnight and noon as 12.
  int get _hour12 => _hour % 12 == 0 ? 12 : _hour % 12;
  bool get _isPm => _hour >= 12;

  late final FixedExtentScrollController _hours = FixedExtentScrollController(
    initialItem: _hour12 - 1,
  );
  late final FixedExtentScrollController _minutes = FixedExtentScrollController(
    initialItem: _minute,
  );
  late final FixedExtentScrollController _meridiem =
      FixedExtentScrollController(initialItem: _isPm ? 1 : 0);

  /// Four points through the day, one tap away and a single row wide.
  static const _presets = [
    TimeOfDay(hour: 9, minute: 0),
    TimeOfDay(hour: 12, minute: 0),
    TimeOfDay(hour: 15, minute: 0),
    TimeOfDay(hour: 18, minute: 0),
  ];

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    _meridiem.dispose();
    super.dispose();
  }

  /// Puts the three wheels back together into a 24-hour clock.
  void _set({int? hour12, int? minute, bool? pm}) {
    final h = hour12 ?? _hour12;
    final afternoon = pm ?? _isPm;
    setState(() {
      _hour = (h % 12) + (afternoon ? 12 : 0);
      if (minute != null) _minute = minute;
    });
  }

  void _apply(TimeOfDay time) {
    setState(() {
      _hour = time.hour;
      _minute = time.minute;
    });
    const duration = Duration(milliseconds: 240);
    _hours.animateToItem(
      _hour12 - 1,
      duration: duration,
      curve: Curves.easeOut,
    );
    _minutes.animateToItem(_minute, duration: duration, curve: Curves.easeOut);
    _meridiem.animateToItem(
      _isPm ? 1 : 0,
      duration: duration,
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final current = TimeOfDay(hour: _hour, minute: _minute);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
          child: Text(
            'Select time',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ),
        SizedBox(
          height: _wheelHeight,
          // The band down the middle is nothing but a window in the mask — no
          // fill, no outline. Inside it the numbers are drawn at full strength
          // and outside at a fraction of it, and because that is done to the
          // pixels rather than to each number, one halfway across the edge
          // comes out bright above the line and dim below it. That split is
          // what shows a wheel standing between two values.
          child: ShaderMask(
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x00FFFFFF),
                Color(0x52FFFFFF),
                Color(0x52FFFFFF),
                Color(0xFFFFFFFF),
                Color(0xFFFFFFFF),
                Color(0x52FFFFFF),
                Color(0x52FFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: [
                0.0,
                0.14,
                _bandTop,
                _bandTop,
                _bandBottom,
                _bandBottom,
                0.86,
                1.0,
              ],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Wheel(
                  controller: _hours,
                  count: 12,
                  width: 62,
                  label: (i) => '${i + 1}',
                  onChanged: (i) => _set(hour12: i + 1),
                ),
                SizedBox(
                  width: 24,
                  child: Text(
                    ':',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _Wheel(
                  controller: _minutes,
                  count: 60,
                  width: 62,
                  label: (i) => i.toString().padLeft(2, '0'),
                  onChanged: (i) => _set(minute: i),
                ),
                const SizedBox(width: 10),
                _Wheel(
                  controller: _meridiem,
                  count: 2,
                  width: 64,
                  looping: false,
                  label: (i) => i == 0 ? 'AM' : 'PM',
                  onChanged: (i) => _set(pm: i == 1),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final preset in _presets)
                _QuickChip(
                  label: Dates.clock(preset),
                  selected: preset.hour == _hour && preset.minute == _minute,
                  onTap: () => _apply(preset),
                ),
            ],
          ),
        ),
        // Two words, no boxes. A filled button and an outlined one either side
        // of a sheet this plain were the only heavy things in it, and they
        // were arguing over which of the two was the one to press.
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 16, 40, 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _SheetAction(
                label: 'Cancel',
                onTap: () => Navigator.of(context).pop(),
              ),
              _SheetAction(
                label: 'Save',
                onTap: () => Navigator.of(context).pop(current),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One number wheel. The row in the middle is the bright, large, heavy one and
/// the rest are small and dim — the only thing saying which value is picked,
/// now that there is no band behind it.
///
/// One wheel of the clock. Every number on it is drawn the same size, weight
/// and colour — what marks the one the wheel is parked on is the mask over the
/// lot of them, which is bright down the middle and dim outside it.
///
/// The whole wheel goes over to the accent while it is being turned, and back
/// to plain when it stops.
class _Wheel extends StatefulWidget {
  final FixedExtentScrollController controller;
  final int count;
  final double width;
  final String Function(int) label;
  final ValueChanged<int> onChanged;

  /// Hours and minutes run round; AM/PM has two values and an end to it.
  final bool looping;

  const _Wheel({
    required this.controller,
    required this.count,
    required this.width,
    required this.label,
    required this.onChanged,
    this.looping = true,
  });

  @override
  State<_Wheel> createState() => _WheelState();
}

class _WheelState extends State<_Wheel> {
  bool _turning = false;

  bool _onScroll(ScrollNotification notification) {
    final turning = notification is! ScrollEndNotification;
    if (turning != _turning) setState(() => _turning = turning);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final style = TextStyle(
      color: _turning ? AppTheme.accentOf(context).color : p.text,
      fontSize: 30,
      height: 1,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final children = [
      for (var i = 0; i < widget.count; i++)
        Center(child: Text(widget.label(i), style: style)),
    ];

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: SizedBox(
        width: widget.width,
        child: ListWheelScrollView.useDelegate(
          controller: widget.controller,
          itemExtent: _itemExtent,
          // Flat: a drum curls the numbers away from the eye, and the band is
          // already saying which of them is the one.
          diameterRatio: 100,
          perspective: 0.00001,
          physics: const FixedExtentScrollPhysics(),
          onSelectedItemChanged: (i) {
            HapticFeedback.selectionClick();
            widget.onChanged(i % widget.count);
          },
          childDelegate: widget.looping
              ? ListWheelChildLoopingListDelegate(children: children)
              : ListWheelChildListDelegate(children: children),
        ),
      ),
    );
  }
}

// ---- Shared pieces --------------------------------------------------------

/// A word at the foot of a sheet that does something: no fill, no outline, and
/// the same weight as its opposite number, since neither is more the answer
/// than the other until the user has decided.
class _SheetAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SheetAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              color: p.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// A sheet header with the title between two step arrows.
class _SheetHeader extends StatelessWidget {
  final String title;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _SheetHeader({
    required this.title,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.chevron_left, color: p.muted),
            tooltip: 'Previous month',
            onPressed: onPrevious,
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            icon: Icon(Icons.chevron_right, color: p.muted),
            tooltip: 'Next month',
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

/// A small pill shortcut inside a picker sheet.
class _QuickChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _QuickChip({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? p.panelHi : p.panel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? p.muted : p.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: p.text,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

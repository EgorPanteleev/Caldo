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
      child: _TimeSheet(initial: initial ?? const TimeOfDay(hour: 9, minute: 0)),
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
            Flexible(
              child: SingleChildScrollView(
                child: child,
              ),
            ),
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
                onTap: () => Navigator.of(context)
                    .pop(today.add(const Duration(days: 1))),
              ),
              _QuickChip(
                label: 'Next week',
                onTap: () => Navigator.of(context)
                    .pop(today.add(const Duration(days: 7))),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Time -----------------------------------------------------------------

class _TimeSheet extends StatefulWidget {
  final TimeOfDay initial;
  const _TimeSheet({required this.initial});

  @override
  State<_TimeSheet> createState() => _TimeSheetState();
}

class _TimeSheetState extends State<_TimeSheet> {
  late int _hour = widget.initial.hour;
  late int _minute = widget.initial.minute;

  late final FixedExtentScrollController _hours =
      FixedExtentScrollController(initialItem: _hour);
  late final FixedExtentScrollController _minutes =
      FixedExtentScrollController(initialItem: _minute);

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
    super.dispose();
  }

  void _apply(TimeOfDay time) {
    setState(() {
      _hour = time.hour;
      _minute = time.minute;
    });
    _hours.animateToItem(time.hour,
        duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
    _minutes.animateToItem(time.minute,
        duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    final current = TimeOfDay(hour: _hour, minute: _minute);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 14, 2),
          child: Row(
            children: [
              Text('Time',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              // The running value, so the chosen time is readable without
              // deciphering the wheels.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: accent.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: accent.color.withValues(alpha: 0.4)),
                ),
                child: Text(
                  Dates.formatTimeOfDay(current),
                  style: TextStyle(
                    color: accent.color,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _WheelCaption('HOUR', color: p.faint),
            const SizedBox(width: 18),
            _WheelCaption('MINUTE', color: p.faint),
          ],
        ),
        SizedBox(
          height: 180,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // The band marking the values the wheels are parked on.
              Container(
                height: 48,
                margin: const EdgeInsets.symmetric(horizontal: 40),
                decoration: BoxDecoration(
                  color: accent.color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: accent.color.withValues(alpha: 0.35),
                  ),
                ),
              ),
              // Numbers dissolve towards the edges instead of being cut off.
              ShaderMask(
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent,
                  ],
                  stops: [0.0, 0.26, 0.74, 1.0],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _Wheel(
                      controller: _hours,
                      count: 24,
                      selected: _hour,
                      onChanged: (v) => setState(() => _hour = v),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        ':',
                        style: TextStyle(
                          color: accent.color,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _Wheel(
                      controller: _minutes,
                      count: 60,
                      selected: _minute,
                      onChanged: (v) => setState(() => _minute = v),
                    ),
                  ],
                ),
              ),
            ],
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
                  label: Dates.formatTimeOfDay(preset),
                  selected: preset.hour == _hour && preset.minute == _minute,
                  onTap: () => _apply(preset),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(current),
                  child: const Text('Set time'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The small caption naming a wheel.
class _WheelCaption extends StatelessWidget {
  final String text;
  final Color color;

  const _WheelCaption(this.text, {required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 74,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// One looping number wheel (hours or minutes).
class _Wheel extends StatelessWidget {
  final FixedExtentScrollController controller;
  final int count;
  final int selected;
  final ValueChanged<int> onChanged;

  const _Wheel({
    required this.controller,
    required this.count,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    return SizedBox(
      width: 74,
      child: ListWheelScrollView.useDelegate(
        controller: controller,
        itemExtent: 46,
        diameterRatio: 1.5,
        perspective: 0.004,
        physics: const FixedExtentScrollPhysics(),
        onSelectedItemChanged: (i) {
          HapticFeedback.selectionClick();
          onChanged(i % count);
        },
        overAndUnderCenterOpacity: 0.55,
        childDelegate: ListWheelChildLoopingListDelegate(
          children: [
            for (var i = 0; i < count; i++)
              Center(
                child: Text(
                  i.toString().padLeft(2, '0'),
                  style: TextStyle(
                    color: i == selected ? accent.color : p.text,
                    fontSize: i == selected ? 27 : 22,
                    fontWeight:
                        i == selected ? FontWeight.w700 : FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- Shared pieces --------------------------------------------------------

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
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
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
    final accent = AppTheme.accentOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? accent.color.withValues(alpha: 0.18)
                : p.panel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? accent.color : p.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? accent.color : p.text,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

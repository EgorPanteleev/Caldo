import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'date_time_pickers.dart';
import 'screen_header.dart';

/// Asks how a task due on [due] repeats. Returns null when the sheet is
/// dismissed or cancelled.
///
/// One sheet rather than a list of presets with a "Custom…" page behind it:
/// the presets are chips across the top, and everything they stand for is
/// laid out under them, so picking "Every week" and then the days it falls
/// on is one place, not two.
Future<Repeat?> showRepeatSheet({
  required BuildContext context,
  required Repeat initial,
  required DateTime due,
}) {
  return showModalBottomSheet<Repeat>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PickerSheet(
      child: _RepeatSheet(initial: initial, due: due),
    ),
  );
}

class _RepeatSheet extends StatefulWidget {
  final Repeat initial;
  final DateTime due;

  const _RepeatSheet({required this.initial, required this.due});

  @override
  State<_RepeatSheet> createState() => _RepeatSheetState();
}

class _RepeatSheetState extends State<_RepeatSheet> {
  late Repeat _rule = widget.initial;

  /// How many rounds "After" offers when it is first chosen.
  static const _defaultCount = 5;

  static const _presets = [
    Repeat.none,
    Repeat.daily,
    Repeat.weekdaysOnly,
    Repeat.weekly,
    Repeat.monthly,
    Repeat.yearly,
  ];

  void _set(Repeat rule) => setState(() => _rule = rule);

  /// A preset keeps whatever end the rule already had: choosing how often
  /// is a separate question from choosing until when.
  void _preset(Repeat preset) => _set(
    preset.isNone
        ? preset
        : preset.copyWith(until: _rule.until, left: _rule.left),
  );

  bool _isPreset(Repeat preset) => preset.isNone
      ? _rule.isNone
      : _rule.copyWith(clearUntil: true, clearLeft: true) == preset;

  Future<void> _pickUntil() async {
    final picked = await showAppDatePicker(
      context: context,
      initial: _rule.until ?? widget.due.add(const Duration(days: 30)),
      firstDate: widget.due,
    );
    if (picked != null) _set(_rule.copyWith(until: picked, clearLeft: true));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final mondayFirst = context.watch<SettingsProvider>().weekStartsMonday;
    final rule = _rule;
    final order = mondayFirst ? [1, 2, 3, 4, 5, 6, 7] : [7, 1, 2, 3, 4, 5, 6];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.repeatLabel,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          // The rule as the cards will write it, so what is being built is
          // read back as it is built.
          Text(
            s.repeatName(rule),
            style: TextStyle(color: p.muted, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in _presets)
                QuickChip(
                  label: s.repeatName(preset),
                  selected: _isPreset(preset),
                  onTap: () => _preset(preset),
                ),
            ],
          ),
          if (!rule.isNone) ...[
            const SizedBox(height: 24),
            SectionLabel(s.repeatEveryLabel),
            // The count on a line of its own and the units under it: side by
            // side, the four units ran to a second line with one left on it.
            _Stepper(
              value: rule.every,
              onChanged: (n) => _set(rule.copyWith(every: n)),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final unit in RepeatUnit.values.skip(1))
                  QuickChip(
                    label: s.unitName(unit),
                    selected: rule.unit == unit,
                    onTap: () => _set(
                      Repeat(
                        unit: unit,
                        every: rule.every,
                        until: rule.until,
                        left: rule.left,
                      ),
                    ),
                  ),
              ],
            ),
            if (rule.unit == RepeatUnit.week) ...[
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final d in order)
                    _Weekday(
                      label: s.weekdayShort(d),
                      // No days chosen means the day it is due on, so that
                      // one is shown as chosen.
                      selected: rule.weekdays.isEmpty
                          ? d == widget.due.weekday
                          : rule.weekdays.contains(d),
                      onTap: () {
                        final days = {
                          ...(rule.weekdays.isEmpty
                              ? {widget.due.weekday}
                              : rule.weekdays),
                        };
                        if (!days.remove(d)) days.add(d);
                        // The last one cannot go: a weekly rule falls on a
                        // day of some kind.
                        if (days.isEmpty) return;
                        _set(
                          rule.copyWith(
                            weekdays: setEqualsDue(days) ? const {} : days,
                          ),
                        );
                      },
                    ),
                ],
              ),
            ],
            if (rule.unit == RepeatUnit.month) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  QuickChip(
                    label: s.repeatOnDay(widget.due.day),
                    selected: !rule.monthEnd,
                    onTap: () => _set(rule.copyWith(monthEnd: false)),
                  ),
                  QuickChip(
                    label: s.repeatOnLastDay,
                    selected: rule.monthEnd,
                    onTap: () => _set(rule.copyWith(monthEnd: true)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            SectionLabel(s.repeatEnds),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                QuickChip(
                  label: s.repeatName(Repeat.none),
                  selected: rule.until == null && rule.left == null,
                  onTap: () =>
                      _set(rule.copyWith(clearUntil: true, clearLeft: true)),
                ),
                QuickChip(
                  label: rule.until == null
                      ? s.endsOn
                      : Dates.shortDay(rule.until!),
                  selected: rule.until != null,
                  onTap: _pickUntil,
                ),
                QuickChip(
                  label: s.endsAfter(rule.left ?? _defaultCount),
                  selected: rule.left != null,
                  onTap: () => _set(
                    rule.copyWith(
                      left: rule.left ?? _defaultCount,
                      clearUntil: true,
                    ),
                  ),
                ),
                if (rule.left != null)
                  _Stepper(
                    value: rule.left!,
                    min: 2,
                    onChanged: (n) => _set(rule.copyWith(left: n)),
                  ),
              ],
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                SheetAction(
                  label: s.cancel,
                  onTap: () => Navigator.of(context).pop(),
                ),
                SheetAction(
                  label: s.save,
                  onTap: () => Navigator.of(context).pop(_rule),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Whether [days] is only the day the task is due on, which a rule says
  /// by naming no days at all — so a plain weekly rule stays plain.
  bool setEqualsDue(Set<int> days) =>
      days.length == 1 && days.single == widget.due.weekday;
}

/// A number with a minus and a plus either side of it.
class _Stepper extends StatelessWidget {
  final int value;
  final int min;
  final ValueChanged<int> onChanged;

  const _Stepper({required this.value, required this.onChanged, this.min = 1});

  static const _max = 99;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    Widget button(IconData icon, int to, bool enabled) => IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 18),
      color: p.text,
      disabledColor: p.faint,
      onPressed: enabled ? () => onChanged(to) : null,
    );
    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(Icons.remove, value - 1, value > min),
          SizedBox(
            width: 24,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p.text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          button(Icons.add, value + 1, value < _max),
        ],
      ),
    );
  }
}

/// A day of the week a weekly rule can fall on: a round toggle with the
/// day's short name.
class _Weekday extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Weekday({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? p.panelHi : p.panel,
            border: Border.all(color: selected ? p.muted : p.border),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: selected ? p.text : p.muted,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

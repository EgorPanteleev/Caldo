import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/special_day.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import 'colour_selector.dart';
import 'date_time_pickers.dart';

/// Makes a special day, or with [day] changes or deletes it.
Future<void> showSpecialDaySheet(BuildContext context, {SpecialDay? day}) =>
    showAppSheet<void>(context, child: _SpecialDaySheet(day: day));

/// The colour each kind starts in, until one is picked.
const _kindColours = {
  SpecialKind.birthday: 'pink',
  SpecialKind.anniversary: 'red',
  SpecialKind.other: 'amber',
};

class _SpecialDaySheet extends StatefulWidget {
  final SpecialDay? day;

  const _SpecialDaySheet({this.day});

  @override
  State<_SpecialDaySheet> createState() => _SpecialDaySheetState();
}

class _SpecialDaySheetState extends State<_SpecialDaySheet> {
  late final TextEditingController _name;
  late SpecialKind _kind;
  late int _month;
  late int _day;
  int? _year;
  late String _styleId;
  late bool _remind;

  /// Whether a colour has been picked here: until one is, the colour goes
  /// with the kind.
  bool _coloured = false;

  @override
  void initState() {
    super.initState();
    final day = widget.day;
    final today = DateTime.now();
    _name = TextEditingController(text: day?.name ?? '');
    _kind = day?.kind ?? SpecialKind.birthday;
    _month = day?.month ?? today.month;
    _day = day?.day ?? today.day;
    _year = day?.year;
    _styleId = day?.styleId ?? _kindColours[_kind]!;
    _remind = day?.remind ?? true;
    _coloured = day != null;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final tasks = context.read<TaskProvider>();
    // The wheel offers 31 days in every month; the 30th of February is
    // kept as the month's last.
    final last = DateTime(2000, _month + 1, 0).day;
    final day = SpecialDay(
      id: widget.day?.id,
      name: name,
      kind: _kind,
      month: _month,
      day: _day > last ? last : _day,
      year: _year,
      styleId: _styleId,
      remind: _remind,
      createdAt: widget.day?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
    );
    if (widget.day == null) {
      await tasks.addSpecialDay(day);
    } else {
      await tasks.updateSpecialDay(day);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final day = widget.day!;
    final tasks = context.read<TaskProvider>();
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteQuestion(day.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await tasks.deleteSpecialDay(day.id!);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final kinds = {
      SpecialKind.birthday: s.kindBirthday,
      SpecialKind.anniversary: s.kindAnniversary,
      SpecialKind.other: s.kindOther,
    };
    return Padding(
      // A sheet is not lifted the way a screen is, so it makes the
      // keyboard's room out of its own height.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.day == null ? s.newSpecialDay : s.editSpecialDay,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (widget.day != null)
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: AppColors.danger),
                    tooltip: s.delete,
                    onPressed: _delete,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: specialNameFieldKey,
              controller: _name,
              autofocus: widget.day == null,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(labelText: s.specialName),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final MapEntry(key: kind, value: label) in kinds.entries)
                  QuickChip(
                    label: label,
                    selected: kind == _kind,
                    onTap: () => setState(() {
                      _kind = kind;
                      if (!_coloured) _styleId = _kindColours[kind]!;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            DayWheels(
              month: _month,
              day: _day,
              year: _year,
              onChanged: (month, day, year) => setState(() {
                _month = month;
                _day = day;
                _year = year;
              }),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                s.remindOnTheDay,
                style: TextStyle(color: p.text, fontSize: 15),
              ),
              value: _remind,
              onChanged: (v) => setState(() => _remind = v),
            ),
            const SizedBox(height: 8),
            ColourSelector(
              value: _styleId,
              sample: _name.text.trim().isEmpty
                  ? s.specialName
                  : _name.text.trim(),
              onChanged: (v) => setState(() {
                _styleId = v!;
                _coloured = true;
              }),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                SheetAction(
                  label: s.cancel,
                  onTap: () => Navigator.of(context).pop(),
                ),
                SheetAction(label: s.save, onTap: _save),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The name field in the special day's sheet.
const specialNameFieldKey = Key('special-name-field');

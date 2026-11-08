import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'date_time_pickers.dart';

/// One of the choices a sheet offers.
class Option<T> {
  final T value;
  final String label;
  final IconData? icon;

  const Option(this.value, this.label, {this.icon});
}

/// Offers [options] in a sheet from the foot of the screen, the one in force
/// ticked, and gives back the one tapped — or null if the sheet was put away.
/// Every choice of one thing from a few is made this way, in Settings and on
/// the task form alike: a dropdown beside the form's sheets, and a segmented
/// bar beside Settings' rows, were each a second way of choosing on a
/// screen that already had one.
Future<T?> choose<T>(
  BuildContext context, {
  required String title,
  required T selected,
  required List<Option<T>> options,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.7,
    ),
    builder: (_) => PickerSheet(
      child: _Choices<T>(title: title, selected: selected, options: options),
    ),
  );
}

class _Choices<T> extends StatefulWidget {
  final String title;
  final T selected;
  final List<Option<T>> options;

  const _Choices({
    required this.title,
    required this.selected,
    required this.options,
  });

  @override
  State<_Choices<T>> createState() => _ChoicesState<T>();
}

class _ChoicesState<T> extends State<_Choices<T>> {
  final _ticked = GlobalKey();

  @override
  void initState() {
    super.initState();
    // A long list opens on the choice in force rather than at its top: the
    // holiday countries run past the sheet, and the one ticked may be among
    // the last of them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ticked = _ticked.currentContext;
      if (ticked != null) Scrollable.ensureVisible(ticked, alignment: 0.5);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
            child: Text(
              widget.title,
              style: TextStyle(
                color: p.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final option in widget.options)
            _Choice(
              key: option.value == widget.selected ? _ticked : null,
              option: option,
              ticked: option.value == widget.selected,
            ),
        ],
      ),
    );
  }
}

class _Choice<T> extends StatelessWidget {
  final Option<T> option;
  final bool ticked;

  const _Choice({super.key, required this.option, required this.ticked});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return InkWell(
      onTap: () => Navigator.pop(context, option.value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 20, 14),
        child: Row(
          children: [
            if (option.icon != null) ...[
              Icon(option.icon, size: 21, color: ticked ? p.text : p.muted),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Text(
                option.label,
                style: TextStyle(
                  color: ticked ? p.text : p.muted,
                  fontSize: 15.5,
                  fontWeight: ticked ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (ticked) Icon(Icons.check_rounded, size: 22, color: p.text),
          ],
        ),
      ),
    );
  }
}

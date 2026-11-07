import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import 'date_time_pickers.dart' show PickerSheet;

/// Identifies the header button that narrows the screens to a tag.
const tagFilterKey = Key('tag-filter');

/// The header button that narrows Schedule and the calendar to one tag.
///
/// Not there at all until some task carries a tag: a filter with nothing to
/// filter by is one more icon to wonder about. While a tag is chosen, the
/// button is that tag written on a pill, so a screen with tasks missing from
/// it always says why.
class TagFilterButton extends StatelessWidget {
  const TagFilterButton({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final filter = context.select<TaskProvider, String?>((t) => t.filter);
    final any = context.select<TaskProvider, bool>((t) => t.tags.isNotEmpty);
    if (filter == null && !any) return const SizedBox.shrink();
    if (filter == null) {
      return IconButton(
        key: tagFilterKey,
        icon: Icon(Icons.tag, color: p.muted),
        tooltip: S.of(context).tags,
        onPressed: () => showTagFilter(context),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: p.field,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: tagFilterKey,
          onTap: () => showTagFilter(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  // A long tag gives way before the screen's title does.
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    '#$filter',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.expand_more, size: 18, color: p.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheet of tags to narrow the screens to: everything first, then each
/// tag with how many open tasks carry it, the most used at the top. A tap
/// picks one and the sheet goes.
Future<void> showTagFilter(BuildContext context) {
  final tasks = context.read<TaskProvider>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheet) {
      final p = AppTheme.of(sheet);
      final s = S.of(sheet);
      Widget row(String label, String? tag, {int? count}) {
        final chosen = tasks.filter == tag;
        return InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            tasks.setFilter(tag);
            Navigator.of(sheet).pop();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 16,
                      fontWeight: chosen ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (count != null)
                  Text(
                    '$count',
                    style: TextStyle(color: p.faint, fontSize: 14),
                  ),
                SizedBox(
                  width: 34,
                  child: chosen
                      ? Icon(Icons.check, size: 20, color: p.text)
                      : null,
                ),
              ],
            ),
          ),
        );
      }

      return PickerSheet(
        child: Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row(s.allTasks, null),
              for (final MapEntry(key: tag, value: open) in tasks.tags.entries)
                row('#$tag', tag, count: open),
            ],
          ),
        ),
      );
    },
  );
}

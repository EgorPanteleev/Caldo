import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/strings.dart';
import '../mcp/usage.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'date_time_pickers.dart';

/// One line under a chat's head: how full its context is, the account's
/// limits, what the chat has cost. A tap opens the whole of it
/// ([showChatUsage]).
class ChatUsageStrip extends StatelessWidget {
  final ChatUsage usage;
  final VoidCallback onTap;

  const ChatUsageStrip({super.key, required this.usage, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final filled = usage.filled;
    final parts = <InlineSpan>[];
    void part(String text, {Color? colour}) {
      if (parts.isNotEmpty) parts.add(const TextSpan(text: '  ·  '));
      parts.add(
        TextSpan(
          text: text,
          style: colour == null ? null : TextStyle(color: colour),
        ),
      );
    }

    if (filled != null) {
      part(s.usageContextShort(_percent(filled)), colour: _near(p, filled));
    } else if (usage.context case final context?) {
      part(s.usageContextShort(_tokens(context)));
    }
    for (final limit in usage.limits) {
      part(
        '${_limitShort(s, limit)} ${_percent(limit.used)}',
        colour: _near(p, limit.used),
      );
    }
    if (usage.cost case final cost? when cost > 0) part(_dollars(cost));
    if (parts.isEmpty) part(s.usageTurns(usage.turns));
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 2, 14, 6),
        child: Row(
          children: [
            if (filled != null) ...[
              SizedBox(width: 28, child: _Meter(filled, height: 3)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text.rich(
                TextSpan(children: parts),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.muted,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: p.faint),
          ],
        ),
      ),
    );
  }
}

/// A chat's figures in the list, so one can be read without opening it,
/// running or stopped: how full its context is and what it cost. The
/// account's limits are not the chat's own, and are left to the strip.
class ChatUsageBrief extends StatelessWidget {
  final ChatUsage usage;

  const ChatUsageBrief({super.key, required this.usage});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final filled = usage.filled;
    final context_ = usage.context;
    final cost = usage.cost;
    final text = [
      if (filled != null)
        s.usageContextShort(_percent(filled))
      else if (context_ != null)
        s.usageContextShort(_tokens(context_)),
      if (cost != null && cost > 0) _dollars(cost),
      if (usage.turns > 0) s.usageTurns(usage.turns),
    ].join('  ·  ');
    if (text.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        if (filled != null) ...[
          SizedBox(width: 22, child: _Meter(filled, height: 3)),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: filled == null ? p.faint : _near(p, filled) ?? p.faint,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// The whole of a chat's figures in a sheet, kept up while it is open:
/// [read] is asked again whenever [changes] says so.
Future<void> showChatUsage(
  BuildContext context, {
  required Listenable changes,
  required ChatUsage? Function() read,
}) => showAppSheet<void>(
  context,
  maxHeight: MediaQuery.sizeOf(context).height * 0.8,
  child: ListenableBuilder(
    listenable: changes,
    builder: (context, _) => _UsageSheet(usage: read() ?? const ChatUsage()),
  ),
);

class _UsageSheet extends StatelessWidget {
  final ChatUsage usage;

  const _UsageSheet({required this.usage});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final filled = usage.filled;
    final context_ = usage.context;
    final heading = TextStyle(
      color: p.faint,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
    );
    Widget head(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
      child: Text(text.toUpperCase(), style: heading),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
            child: Text(
              s.usageTitle,
              style: TextStyle(
                color: p.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (context_ != null) ...[
            head(s.usageContext),
            _Gauge(
              name: usage.window == null
                  ? s.usageTokensOnly(_tokens(context_))
                  : s.usageOf(_tokens(context_), _tokens(usage.window!)),
              figure: filled == null ? null : _percent(filled),
              share: filled,
            ),
          ],
          if (usage.limits.isNotEmpty) ...[
            head(s.usageLimits),
            for (final limit in usage.limits)
              _Gauge(
                name: _limitName(s, limit),
                figure: _percent(limit.used),
                share: limit.used,
                under: limit.resets == null
                    ? null
                    : s.usageResets(_when(limit.resets!.toLocal(), h24)),
              ),
            if (usage.limited case 'allowed_warning' || 'rejected')
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
                child: Text(
                  usage.limited == 'rejected'
                      ? s.usageLimitReached
                      : s.usageLimitNear,
                  style: TextStyle(
                    color: usage.limited == 'rejected'
                        ? AppColors.danger
                        : p.text,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
          head(s.usageThisChat),
          if (usage.model case final model?) _Figure(s.chatModel, model),
          _Figure(s.usageTurnsName, '${usage.turns}'),
          if (usage.working > Duration.zero)
            _Figure(s.usageWorking, _span(s, usage.working)),
          if (usage.tokens > 0) ...[
            _Figure(s.usageInput, _tokens(usage.input)),
            _Figure(s.usageOutput, _tokens(usage.output)),
            if (usage.cacheRead > 0)
              _Figure(s.usageCacheRead, _tokens(usage.cacheRead)),
            if (usage.cacheWrite > 0)
              _Figure(s.usageCacheWrite, _tokens(usage.cacheWrite)),
          ],
          if (usage.cost case final cost?) _Figure(s.usageCost, _dollars(cost)),
          if (usage.limitsAt case final at?)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
              child: Text(
                s.usageAsOf(_when(at, h24)),
                style: TextStyle(color: p.faint, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// A share of something: its name and figure on a line, a bar under it,
/// and a word under that.
class _Gauge extends StatelessWidget {
  final String name;
  final String? figure;
  final double? share;
  final String? under;

  const _Gauge({
    required this.name,
    required this.figure,
    required this.share,
    this.under,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(color: p.text, fontSize: 14),
                ),
              ),
              if (figure != null)
                Text(
                  figure!,
                  style: TextStyle(
                    color: _lit(p, share ?? 0),
                    fontSize: 14,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          if (share != null) ...[
            const SizedBox(height: 7),
            _Meter(share!, height: 5),
          ],
          if (under != null) ...[
            const SizedBox(height: 5),
            Text(under!, style: TextStyle(color: p.faint, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

/// One figure: its name on the left, the figure on the right.
class _Figure extends StatelessWidget {
  final String name;
  final String value;

  const _Figure(this.name, this.value);

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 5, 24, 5),
      // Both loose, pushed apart: the figure at the right edge, and a long
      // name or figure each cut at half the row, not run off it.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted, fontSize: 14),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A thin bar filled by [share]: grey, brighter from 80%, red at the end.
class _Meter extends StatelessWidget {
  final double share;
  final double height;

  const _Meter(this.share, {required this.height});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: p.panelHi),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: share.clamp(0.0, 1.0),
              child: ColoredBox(color: _lit(p, share)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A share at its end in red. Near it (80%), only brighter, in [_lit]:
/// red at 83% read as an alarm.
Color? _warn(double share) => share >= 0.95 ? AppColors.danger : null;

Color _lit(AppPalette p, double share) =>
    _warn(share) ?? (share >= 0.8 ? p.text : p.muted);

/// In the strip: [_lit], or nothing for the strip's own grey.
Color? _near(AppPalette p, double share) =>
    share >= 0.8 ? _lit(p, share) : null;

String _percent(double share) => '${(share * 100).round()}%';

/// "61K", "1.2M": tokens to the nearest figure that reads at a glance.
String _tokens(int n) => NumberFormat.compact().format(n);

String _dollars(double cost) => cost > 0 && cost < 0.01
    ? '<\$0.01'
    : '\$${cost.toStringAsFixed(cost < 100 ? 2 : 0)}';

String _span(S s, Duration d) {
  if (d.inMinutes < 1) return s.usageSeconds(d.inSeconds);
  if (d.inHours < 1) return s.usageMinutes(d.inMinutes);
  return s.usageHours(d.inHours, d.inMinutes % 60);
}

/// A time today alone; another day's with its day.
String _when(DateTime at, bool h24) {
  final time = Dates.time(at, h24: h24);
  final now = DateTime.now();
  return DateUtils.isSameDay(at, now) ? time : '${Dates.day(at)} $time';
}

String _limitName(S s, UsageLimit limit) {
  final span = limit.span;
  final name = span == 300
      ? s.usageFiveHours
      : span == 7 * 24 * 60
      ? s.usageWeekly
      : span != null && span % (24 * 60) == 0
      ? s.usageDays(span ~/ (24 * 60))
      : span != null && span % 60 == 0
      ? s.usageHoursLimit(span ~/ 60)
      : limit.name.replaceAll('_', ' ');
  final only = limit.only;
  return only == null ? name : '$name · ${_capital(only)}';
}

String _limitShort(S s, UsageLimit limit) {
  final span = limit.span;
  final name = span == 7 * 24 * 60
      ? s.usageWeekShort
      : span != null && span % 60 == 0 && span < 24 * 60
      ? '${span ~/ 60}h'
      : span != null && span % (24 * 60) == 0
      ? '${span ~/ (24 * 60)}d'
      : limit.name.replaceAll('_', ' ');
  final only = limit.only;
  return only == null ? name : '$name ${_capital(only)}';
}

String _capital(String word) =>
    word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);

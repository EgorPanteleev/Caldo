import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../services/agents.dart';
import '../theme/app_theme.dart';
import 'markdown_text.dart';

/// A chat with an agent as a chat: the user's words on the right, the
/// agent's answers across the width in Markdown, each tool it used as one
/// line that opens to what it did, questions of permission with their
/// buttons — the same for Claude and Codex, whatever their terminals look
/// like.
///
/// It stays at the foot while the newest words are being written, unless
/// the reader has scrolled up: then nothing moves under them, as what
/// comes is added below.
class TalkView extends StatefulWidget {
  final TalkFeed feed;

  /// Whether a turn is under way, for the line at the foot that says so.
  final bool working;
  final void Function(String item, String choice) onAnswer;

  /// Room left at the top and foot of the list.
  final EdgeInsets padding;

  const TalkView({
    super.key,
    required this.feed,
    required this.working,
    required this.onAnswer,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<TalkView> createState() => _TalkViewState();
}

class _TalkViewState extends State<TalkView> {
  final _scroll = ScrollController();
  final _open = <String>{};

  /// Whether the foot is in view, so what comes is followed.
  bool _atFoot = true;

  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_changed);
    widget.feed.pieces.addListener(_follow);
    _scroll.addListener(_scrolled);
    // Opened at the foot, where the newest words are.
    _follow();
  }

  @override
  void didUpdateWidget(TalkView old) {
    super.didUpdateWidget(old);
    if (old.feed != widget.feed) {
      old.feed.removeListener(_changed);
      old.feed.pieces.removeListener(_follow);
      widget.feed.addListener(_changed);
      widget.feed.pieces.addListener(_follow);
    }
    if (old.working != widget.working) _follow();
  }

  @override
  void dispose() {
    widget.feed.removeListener(_changed);
    widget.feed.pieces.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _follow();
  }

  void _scrolled() {
    if (!_scroll.hasClients) return;
    final at = _scroll.position;
    _atFoot = at.pixels >= at.maxScrollExtent - 24;
  }

  /// Kept at the foot as the list grows, if it was there: a few frames, as
  /// a lazy list only knows its true length once it has laid out its end.
  void _follow([int frames = 5]) {
    if (!_atFoot || frames == 0) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_atFoot) return;
      final at = _scroll.position;
      if (at.pixels < at.maxScrollExtent) {
        _scroll.jumpTo(at.maxScrollExtent);
        _follow(frames - 1);
      }
    });
  }

  void _toggle(String id) => setState(() {
    if (!_open.remove(id)) _open.add(id);
  });

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    final items = feed.items;
    if (feed.loaded && items.isEmpty && !widget.working) {
      final p = AppTheme.of(context);
      return Center(
        child: Text(
          S.of(context).chatEmpty,
          style: TextStyle(color: p.faint, fontSize: 14),
        ),
      );
    }
    return SelectionArea(
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(top: widget.padding.top + 8),
            sliver: SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => _tile(items, i),
            ),
          ),
          SliverToBoxAdapter(
            child: ValueListenableBuilder(
              valueListenable: feed.pieces,
              builder: (context, pieces, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final MapEntry(key: id, value: text) in pieces.entries)
                    _Spaced(
                      key: ValueKey('w$id'),
                      top: 14,
                      child: _Answer(text: text, writing: true),
                    ),
                  if (widget.working && pieces.isEmpty)
                    const _Spaced(top: 14, child: _Working()),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.only(bottom: widget.padding.bottom + 12),
          ),
        ],
      ),
    );
  }

  /// [list]'s item [i], spaced from the one above it: tools in a run sit
  /// close, as one block of work.
  Widget _tile(List<ChatItem> list, int i) {
    final item = list[i];
    final above = i > 0 ? list[i - 1] : null;
    final close = above != null && _small(above) && _small(item);
    return _Spaced(
      key: ValueKey(item.id),
      top: above == null ? 0 : (close ? 4 : 14),
      child: switch (item.kind) {
        'user' => _Said(text: item.text),
        'text' => _Answer(text: item.text),
        'thinking' => _Thinking(
          text: item.text,
          open: _open.contains(item.id),
          onTap: () => _toggle(item.id),
        ),
        'tool' => _Tool(
          body: item.body,
          open: _open.contains(item.id),
          onTap: () => _toggle(item.id),
        ),
        'ask' => _Ask(
          body: item.body,
          onAnswer: (choice) => widget.onAnswer(item.id, choice),
        ),
        _ => _Note(text: item.text, error: item.body['error'] == true),
      },
    );
  }

  static bool _small(ChatItem item) =>
      item.kind == 'tool' || item.kind == 'thinking';
}

class _Spaced extends StatelessWidget {
  final double top;
  final Widget child;

  const _Spaced({super.key, required this.top, required this.child});

  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(16, top, 16, 0), child: child);
}

/// The user's words, on the right in a raised bubble.
class _Said extends StatelessWidget {
  final String text;

  const _Said({required this.text});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 0.85,
        alignment: Alignment.centerRight,
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
            decoration: BoxDecoration(
              color: p.panelHi,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              text,
              style: TextStyle(color: p.text, fontSize: 15, height: 1.35),
            ),
          ),
        ),
      ),
    );
  }
}

/// The agent's words, across the width; [writing] while they come.
class _Answer extends StatelessWidget {
  final String text;
  final bool writing;

  const _Answer({required this.text, this.writing = false});

  @override
  Widget build(BuildContext context) =>
      MarkdownText(writing ? '$text ▍' : text);
}

class _Thinking extends StatelessWidget {
  final String text;
  final bool open;
  final VoidCallback onTap;

  const _Thinking({
    required this.text,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Line(
          icon: Icons.psychology_outlined,
          name: S.of(context).chatThinking,
          line: open ? '' : text.split('\n').first,
          onTap: onTap,
          open: open,
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 4, 0, 2),
            child: Text(
              text,
              style: TextStyle(
                color: p.muted,
                fontSize: 13.5,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}

/// A tool the agent used: its name and what it was asked to do on one
/// line, a mark for how it went, and under it, opened, the whole of it and
/// what came back.
class _Tool extends StatelessWidget {
  final Map<String, dynamic> body;
  final bool open;
  final VoidCallback onTap;

  const _Tool({required this.body, required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final done = body['done'] == true;
    final failed = body['failed'] == true;
    final detail = '${body['detail'] ?? ''}'.trim();
    final output = '${body['output'] ?? ''}'.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Line(
          icon: _iconOf('${body['name']}'),
          name: '${body['name']}',
          line: '${body['line'] ?? ''}',
          onTap: detail.isEmpty && output.isEmpty ? null : onTap,
          open: open,
          trailing: !done
              ? SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: p.muted,
                  ),
                )
              : failed
              ? Icon(
                  Icons.error_outline_rounded,
                  size: 15,
                  color: AppColors.danger,
                )
              : null,
        ),
        if (open && (detail.isNotEmpty || output.isNotEmpty))
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 6, 0, 2),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                color: p.panel,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    [
                      if (detail.isNotEmpty) detail,
                      if (output.isNotEmpty) output,
                    ].join('\n\n'),
                    style: TextStyle(
                      fontFamily: MarkdownText.mono,
                      fontSize: 11.5,
                      height: 1.4,
                      color: failed ? AppColors.danger : p.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static IconData _iconOf(String name) => switch (name) {
    'Bash' || 'Shell' => Icons.terminal_rounded,
    'Read' => Icons.description_outlined,
    'Write' || 'Edit' || 'NotebookEdit' => Icons.edit_outlined,
    'Glob' || 'Grep' => Icons.search_rounded,
    'WebFetch' || 'WebSearch' || 'Search' => Icons.public_rounded,
    'Task' || 'Agent' => Icons.call_split_rounded,
    'TodoWrite' => Icons.checklist_rounded,
    'Skill' => Icons.auto_awesome_outlined,
    _ => Icons.build_outlined,
  };
}

/// One line of work: an icon, a name, what it was about, cut to the width.
class _Line extends StatelessWidget {
  final IconData icon;
  final String name;
  final String line;
  final VoidCallback? onTap;
  final bool open;
  final Widget? trailing;

  const _Line({
    required this.icon,
    required this.name,
    required this.line,
    required this.onTap,
    required this.open,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: 16, color: p.faint),
            const SizedBox(width: 10),
            Text(
              name,
              style: TextStyle(
                color: p.muted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.faint,
                  fontSize: 12,
                  fontFamily: MarkdownText.mono,
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            if (onTap != null)
              Icon(
                open
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: p.faint,
              ),
          ],
        ),
      ),
    );
  }
}

/// A question of permission: what the agent wants to do, and the buttons
/// to say — until it is answered, then what was said.
class _Ask extends StatelessWidget {
  final Map<String, dynamic> body;
  final ValueChanged<String> onAnswer;

  const _Ask({required this.body, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final answer = body['answer'] as String?;
    final choices = [
      for (final c in body['choices'] as List? ?? const []) '$c',
    ];
    final detail = '${body['detail'] ?? ''}'.trim();
    void say(String choice) {
      HapticFeedback.selectionClick();
      onAnswer(choice);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: answer == null
              ? AppColors.overdue.withValues(alpha: 0.6)
              : p.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${body['tool']}',
            style: TextStyle(
              color: p.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if ('${body['line'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${body['line']}',
              style: TextStyle(
                color: p.muted,
                fontSize: 12.5,
                fontFamily: MarkdownText.mono,
                height: 1.4,
              ),
            ),
          ],
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Text(
                  detail,
                  style: TextStyle(
                    color: p.faint,
                    fontSize: 11.5,
                    fontFamily: MarkdownText.mono,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          if (answer != null)
            Text(switch (answer) {
              'allow' => s.chatAllowed,
              'always' => s.chatAlwaysAllowed,
              _ => s.chatDenied,
            }, style: TextStyle(color: p.faint, fontSize: 13))
          else
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: [
                if (choices.contains('deny'))
                  OutlinedButton(
                    onPressed: () => say('deny'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.text,
                      side: BorderSide(color: p.border),
                    ),
                    child: Text(s.chatDeny),
                  ),
                if (choices.contains('always'))
                  TextButton(
                    onPressed: () => say('always'),
                    style: TextButton.styleFrom(foregroundColor: p.muted),
                    child: Text(s.chatAlways),
                  ),
                FilledButton(
                  onPressed: () => say('allow'),
                  style: FilledButton.styleFrom(
                    backgroundColor: p.text,
                    foregroundColor: p.bg,
                  ),
                  child: Text(s.chatAllow),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final bool error;

  const _Note({required this.text, required this.error});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: error ? AppColors.danger : p.faint,
        fontSize: 12.5,
        height: 1.4,
      ),
    );
  }
}

/// While a turn is under way and nothing is being written: a small spinner
/// and the word.
class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Row(
      children: [
        SizedBox.square(
          dimension: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: p.muted),
        ),
        const SizedBox(width: 10),
        Text(
          S.of(context).chatWorking,
          style: TextStyle(color: p.faint, fontSize: 13),
        ),
      ],
    );
  }
}

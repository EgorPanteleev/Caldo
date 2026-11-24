import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../services/agents.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'markdown_text.dart';
import 'task_card.dart' show CheckMark;

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

  /// A question answered: [answers] by each question's words, for those
  /// asked of the user.
  final void Function(String item, String choice, Map<String, String> answers)
  onAnswer;

  /// Whether the chat is to carry on by itself after the usage limit, and
  /// the tick on the latest stop at it that asks for that or takes it
  /// back; null where its worker can't leave messages for later.
  final bool carrying;
  final ValueChanged<ChatItem>? onCarry;

  /// Room left at the top and foot of the list.
  final EdgeInsets padding;

  const TalkView({
    super.key,
    required this.feed,
    required this.working,
    required this.onAnswer,
    this.carrying = false,
    this.onCarry,
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
    // Only the latest stop at the limit can be ticked, and only until the
    // user writes again: what was said after it stands in for carrying on.
    var live = items.lastIndexWhere((item) => item.kind == 'limit');
    if (live >= 0 && items.skip(live + 1).any((item) => item.kind == 'user')) {
      live = -1;
    }
    return SelectionArea(
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(top: widget.padding.top + 8),
            sliver: SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => _tile(items, i, live),
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
  Widget _tile(List<ChatItem> list, int i, int live) {
    final item = list[i];
    final above = i > 0 ? list[i - 1] : null;
    final close = above != null && _small(above) && _small(item);
    return _Spaced(
      key: ValueKey(item.id),
      top: above == null ? 0 : (close ? 4 : 14),
      child: switch (item.kind) {
        'user' => _Said(
          text: item.text,
          files: item.body['files'],
          sender: item.body['sender'],
        ),
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
        'ask' when item.body['questions'] is List => _Questions(
          body: item.body,
          onAnswer: (choice, answers) =>
              widget.onAnswer(item.id, choice, answers),
        ),
        'ask' => _Ask(
          body: item.body,
          onAnswer: (choice) => widget.onAnswer(item.id, choice, const {}),
        ),
        'limit' => _Limit(
          resets: item.body['resets'] is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  (item.body['resets'] as num).round(),
                )
              : null,
          carrying: i == live && widget.carrying,
          onTap: i == live && widget.onCarry != null
              ? () => widget.onCarry!(item)
              : null,
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

/// The user's words, on the right in a raised bubble, and under them
/// what was sent with them, by name: the files are on the worker's
/// computer now, not here.
class _Said extends StatelessWidget {
  final String text;
  final Object? files;

  /// Who sent it if not the user: another chat's agent (`withSender`).
  final Object? sender;

  const _Said({required this.text, this.files, this.sender});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final said = _bubble(p);
    final from = sender;
    if (from is! Map) return said;
    final s = S.of(context);
    final title = '${from['title'] ?? ''}'.trim();
    // Told of what it is subscribed to (`chat_subscriptions`).
    final event = from['event'] != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                event ? Icons.call_merge : Icons.forum_outlined,
                size: 13,
                color: p.muted,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  event
                      ? s.chatFromEvent(title)
                      : from['chat'] == null || title.isEmpty
                      ? s.chatFromOutside
                      : s.chatFrom(title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.muted, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
        said,
      ],
    );
  }

  Widget _bubble(AppPalette p) {
    final sent = [
      for (final f in files is List ? files as List : const [])
        if (f is Map) f,
    ];
    final words = Text(
      text,
      style: TextStyle(color: p.text, fontSize: 15, height: 1.35),
    );
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
            child: sent.isEmpty
                ? words
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final f in sent)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                '${f['mime']}'.startsWith('image/')
                                    ? Icons.image_outlined
                                    : Icons.insert_drive_file_outlined,
                                size: 16,
                                color: p.muted,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  '${f['name']}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 13.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (text.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        words,
                      ],
                    ],
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

/// Questions the agent asks the user (Claude's AskUserQuestion): each
/// with its options to tap, one or any, and Other… for words of one's
/// own; Answer once every question has one. Answered, what was said.
class _Questions extends StatefulWidget {
  final Map<String, dynamic> body;
  final void Function(String choice, Map<String, String> answers) onAnswer;

  const _Questions({required this.body, required this.onAnswer});

  @override
  State<_Questions> createState() => _QuestionsState();
}

class _QuestionsState extends State<_Questions> {
  /// Options picked, and words typed, by each question's place.
  final _picked = <int, Set<String>>{};
  final _typed = <int, String>{};

  List<Map> get _questions => [
    for (final q in widget.body['questions'] as List? ?? const [])
      if (q is Map) q,
  ];

  static List<Map> _options(Map q) => [
    for (final o in q['options'] as List? ?? const [])
      if (o is Map) o,
  ];

  /// What is said to question [i]: the options picked in their own order,
  /// then the words typed; several joined as Claude's terminal joins them.
  String _answerOf(int i) {
    final picked = _picked[i] ?? const {};
    return [
      for (final o in _options(_questions[i]))
        if (picked.contains('${o['label']}')) '${o['label']}',
      if ((_typed[i] ?? '').trim().isNotEmpty) _typed[i]!.trim(),
    ].join(', ');
  }

  void _pick(int i, String label) {
    HapticFeedback.selectionClick();
    setState(() {
      final picked = _picked.putIfAbsent(i, () => {});
      if (_questions[i]['multiSelect'] == true) {
        if (!picked.remove(label)) picked.add(label);
      } else {
        // One answer: an option takes the place of words typed.
        _typed.remove(i);
        picked
          ..clear()
          ..add(label);
      }
    });
  }

  Future<void> _other(int i) async {
    final got = await showDialog<String>(
      context: context,
      builder: (ctx) => _OtherAnswer(
        question: '${_questions[i]['question']}',
        typed: _typed[i] ?? '',
      ),
    );
    if (got == null || !mounted) return;
    setState(() {
      if (got.trim().isEmpty) {
        _typed.remove(i);
      } else {
        _typed[i] = got.trim();
        // One answer: words typed take the place of an option.
        if (_questions[i]['multiSelect'] != true) _picked.remove(i);
      }
    });
  }

  void _say(String choice) {
    HapticFeedback.selectionClick();
    widget.onAnswer(choice, {
      if (choice == 'answer')
        for (var i = 0; i < _questions.length; i++)
          '${_questions[i]['question']}': _answerOf(i),
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final questions = _questions;
    final answer = widget.body['answer'] as String?;
    final answers = widget.body['answers'] as Map? ?? const {};
    final ready = [
      for (var i = 0; i < questions.length; i++) _answerOf(i),
    ].every((a) => a.isNotEmpty);

    Widget question(int i) {
      final q = questions[i];
      final header = '${q['header'] ?? ''}';
      final many = q['multiSelect'] == true;
      final picked = _picked[i] ?? const {};
      final typed = _typed[i];
      final said = answers['${q['question']}'];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header.isNotEmpty || (many && answer == null))
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                [
                  if (header.isNotEmpty) header.toUpperCase(),
                  if (many && answer == null) s.chatPickAny,
                ].join(' · '),
                style: TextStyle(
                  color: p.faint,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          Text(
            '${q['question']}',
            style: TextStyle(
              color: p.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          if (answer != null)
            Text(
              said == null || '$said'.isEmpty ? s.chatNotAnswered : '$said',
              style: TextStyle(
                color: said == null ? p.faint : p.muted,
                fontSize: 13.5,
                height: 1.35,
              ),
            )
          else ...[
            for (final o in _options(q))
              _Option(
                label: '${o['label']}',
                description: '${o['description'] ?? ''}',
                many: many,
                picked: picked.contains('${o['label']}'),
                onTap: () => _pick(i, '${o['label']}'),
              ),
            _Option(
              label: typed ?? s.chatOther,
              description: '',
              many: many,
              picked: typed != null,
              onTap: () => _other(i),
            ),
          ],
        ],
      );
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
          for (var i = 0; i < questions.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            question(i),
          ],
          if (answer == null) ...[
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton(
                  onPressed: () => _say('deny'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.text,
                    side: BorderSide(color: p.border),
                  ),
                  child: Text(s.chatSkip),
                ),
                FilledButton(
                  onPressed: ready ? () => _say('answer') : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: p.text,
                    foregroundColor: p.bg,
                    disabledBackgroundColor: p.border,
                    disabledForegroundColor: p.faint,
                  ),
                  child: Text(s.chatAnswer),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Words of one's own for a question; its field kept until the dialog
/// has gone, as it is drawn while it fades.
class _OtherAnswer extends StatefulWidget {
  final String question;
  final String typed;

  const _OtherAnswer({required this.question, required this.typed});

  @override
  State<_OtherAnswer> createState() => _OtherAnswerState();
}

class _OtherAnswerState extends State<_OtherAnswer> {
  late final _field = TextEditingController(text: widget.typed);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AlertDialog(
      title: Text(widget.question),
      content: TextField(
        controller: _field,
        autofocus: true,
        minLines: 1,
        maxLines: 5,
        decoration: InputDecoration(hintText: s.chatOtherHint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _field.text),
          child: Text(s.save),
        ),
      ],
    );
  }
}

/// One of a question's options: a round mark for one answer, a square
/// for any, filled when picked; its description under it.
class _Option extends StatelessWidget {
  final String label;
  final String description;
  final bool many;
  final bool picked;
  final VoidCallback onTap;

  const _Option({
    required this.label,
    required this.description,
    required this.many,
    required this.picked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: picked ? p.panelHi : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: picked ? p.muted : p.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    many
                        ? (picked
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded)
                        : (picked
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded),
                    size: 18,
                    color: picked ? p.text : p.faint,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 13.5,
                          height: 1.35,
                        ),
                      ),
                      if (description.isNotEmpty && description != label)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            description,
                            style: TextStyle(
                              color: p.faint,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ),
                    ],
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

/// A turn the account's limit refused: said as a note, and under the
/// latest a box to tick to have the chat carry on by itself once the limit
/// is lifted. Unticked unless the user asks.
class _Limit extends StatelessWidget {
  final DateTime? resets;
  final bool carrying;
  final VoidCallback? onTap;

  const _Limit({required this.resets, required this.carrying, this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final note = _Note(text: s.chatAtLimit, error: false);
    if (onTap == null) return note;
    final at = resets;
    String? when;
    if (at != null && at.isAfter(DateTime.now())) {
      final time = Dates.time(
        at,
        h24: MediaQuery.alwaysUse24HourFormatOf(context),
      );
      when = DateUtils.isSameDay(at, DateTime.now())
          ? time
          : '${Dates.dayWord(at) ?? Dates.shortDay(at)} $time';
    }
    return Column(
      children: [
        note,
        const SizedBox(height: 6),
        Center(
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: carrying ? p.text : Colors.transparent,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: carrying ? p.text : p.muted,
                        width: 1.5,
                      ),
                    ),
                    child: CustomPaint(
                      painter: CheckMark(
                        progress: carrying ? 1 : 0,
                        color: p.bg,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      when == null ? s.chatCarryOnSoon : s.chatCarryOnAt(when),
                      style: TextStyle(color: p.text, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
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

part of 'agents_screen.dart';

/// What a chat is subscribed to, listed in its settings (asked as "every
/// new PR, reviewer get an message", 2026-11-24): each a row opening it,
/// and a pick making a new one. Made and changed at once, not on the
/// settings' Save — they are rows of their own, not the chat's.
class _SubscriptionsList extends StatelessWidget {
  final List<Subscription> subs;

  /// Whether the chat's worker watches them: else they are shown, to be
  /// put away, but none is made.
  final bool watched;
  final void Function(Subscription? sub) onOpen;

  const _SubscriptionsList({
    required this.subs,
    required this.watched,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(s.chatSubscriptions),
        for (final sub in subs)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: p.field,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onOpen(sub),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                  child: Row(
                    children: [
                      Icon(Icons.call_merge, size: 18, color: p.muted),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sub.target ?? s.chatSubThisRepo,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.text, fontSize: 14.5),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              sub.error ?? _eventsLine(s, sub.events),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: sub.error == null
                                    ? p.faint
                                    : AppColors.danger,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 20, color: p.faint),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (watched)
          Align(
            alignment: Alignment.centerLeft,
            child: _Pick(
              label: s.chatSubscribe,
              icon: Icons.add,
              selected: false,
              onTap: () => onOpen(null),
            ),
          ),
      ],
    );
  }
}

String _eventName(S s, String event) => switch (event) {
  'pushed' => s.chatSubPushed,
  'closed' => s.chatSubClosed,
  _ => s.chatSubOpened,
};

String _eventsLine(S s, List<String> events) => [
  for (final e in Subscription.kinds)
    if (events.contains(e)) _eventName(s, e),
].join(' · ');

/// One subscription, made or changed: the repository (empty for the one
/// of the chat's folder), what is told, and what is said after.
class SubscriptionScreen extends StatefulWidget {
  final String chat;

  /// Null for a new one.
  final Subscription? sub;

  /// The chat's computer, named in the hint.
  final String worker;

  const SubscriptionScreen({
    super.key,
    required this.chat,
    this.sub,
    this.worker = '',
  });

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  late final _repo = TextEditingController(text: widget.sub?.target);
  late final _note = TextEditingController(text: widget.sub?.note);
  late final Set<String> _events = {
    ...widget.sub?.events ?? ['opened'],
  };
  bool _saving = false;
  bool _badRepo = false;

  @override
  void dispose() {
    _repo.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final given = _repo.text.trim();
    final repo = given.isEmpty ? null : Subscription.repoOf(given);
    if (given.isNotEmpty && repo == null) {
      setState(() => _badRepo = true);
      return;
    }
    setState(() {
      _badRepo = false;
      _saving = true;
    });
    try {
      await Agents.instance.subscribe(
        widget.chat,
        id: widget.sub?.id,
        repo: repo,
        events: [
          for (final e in Subscription.kinds)
            if (_events.contains(e)) e,
        ],
        note: _note.text,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete() async {
    await Agents.instance.unsubscribe(widget.sub!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final error = widget.sub?.error;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: s.chatSubscription,
                showBack: true,
                actions: [
                  if (widget.sub != null)
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: p.muted),
                      tooltip: s.delete,
                      onPressed: _delete,
                    ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
            Expanded(
              child: DeskGutter(
                builder: (context, gutter) => ListView(
                  padding: EdgeInsets.fromLTRB(
                    20 + gutter,
                    4,
                    20 + gutter,
                    24 + KeyboardGap.of(context),
                  ),
                  children: [
                    _Section(s.chatSubRepo),
                    _Field(controller: _repo, hint: s.chatSubRepoHint),
                    if (_badRepo || error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, left: 4),
                        child: Text(
                          _badRepo ? s.chatSubBadRepo : error!,
                          style: TextStyle(
                            color: AppColors.danger,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    _Section(s.chatSubWhen),
                    _Picks(
                      children: [
                        for (final e in Subscription.kinds)
                          _Pick(
                            label: _eventName(s, e),
                            selected: _events.contains(e),
                            onTap: () => setState(() {
                              // At least one, or it would tell nothing.
                              if (!_events.remove(e)) _events.add(e);
                              if (_events.isEmpty) _events.add(e);
                            }),
                          ),
                      ],
                    ),
                    _Section(s.chatSubNote),
                    _Field(
                      controller: _note,
                      hint: s.chatSubNoteHint,
                      lines: 4,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      s.chatSubHint(widget.worker),
                      style: TextStyle(color: p.faint, fontSize: 12.5),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: Text(s.save),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

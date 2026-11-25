part of 'agents_screen.dart';

/// Subscriptions are saved independently of the chat settings.
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
                              s.chatSubscription,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.text, fontSize: 14.5),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              sub.target ?? s.chatSubThisRepo,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.muted, fontSize: 12.5),
                            ),
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
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: Text(s.chatSubscribe),
              onPressed: () => onOpen(null),
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

  const SubscriptionScreen({super.key, required this.chat, this.sub});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  late bool _useChatRepo = widget.sub?.target == null;
  late final _repo = TextEditingController(text: widget.sub?.target);
  late final _note = TextEditingController(text: widget.sub?.note);
  late final Set<String> _events = {
    ...widget.sub?.events ?? ['opened'],
  };
  final _scroll = ScrollController();
  bool _saving = false;
  bool _badRepo = false;

  @override
  void dispose() {
    _scroll.dispose();
    _repo.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = _useChatRepo ? null : Subscription.repoOf(_repo.text);
    if (!_useChatRepo && repo == null) {
      setState(() => _badRepo = true);
      await _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
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
    setState(() => _saving = true);
    try {
      await Agents.instance.unsubscribe(widget.sub!.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
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
                title: widget.sub == null
                    ? s.chatSubscribe
                    : s.chatSubscription,
                showBack: true,
                actions: [
                  if (widget.sub != null)
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: p.muted),
                      tooltip: s.delete,
                      onPressed: _saving ? null : _delete,
                    ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
            Expanded(
              child: DeskGutter(
                builder: (context, gutter) => ListView(
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(
                    20 + gutter,
                    4,
                    20 + gutter,
                    24 + KeyboardGap.of(context),
                  ),
                  children: [
                    Text(
                      s.chatSubHint,
                      style: TextStyle(color: p.muted, fontSize: 13.5),
                    ),
                    _Section(s.chatSubRepo),
                    Material(
                      color: p.field,
                      borderRadius: BorderRadius.circular(12),
                      child: RadioGroup<bool>(
                        groupValue: _useChatRepo,
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _useChatRepo = value;
                            _badRepo = false;
                          });
                        },
                        child: Column(
                          children: [
                            RadioListTile<bool>(
                              value: true,
                              enabled: !_saving,
                              title: Text(s.chatSubThisRepo),
                            ),
                            RadioListTile<bool>(
                              value: false,
                              enabled: !_saving,
                              title: Text(s.chatSubOtherRepo),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!_useChatRepo) ...[
                      const SizedBox(height: 8),
                      _Field(controller: _repo, hint: s.chatSubRepoHint),
                    ],
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
                    Material(
                      color: p.field,
                      borderRadius: BorderRadius.circular(12),
                      child: Column(
                        children: [
                          for (final e in Subscription.kinds)
                            CheckboxListTile(
                              title: Text(_eventName(s, e)),
                              value: _events.contains(e),
                              controlAffinity: ListTileControlAffinity.leading,
                              onChanged: _saving
                                  ? null
                                  : (selected) => setState(() {
                                      if (selected == true) {
                                        _events.add(e);
                                      } else {
                                        _events.remove(e);
                                      }
                                    }),
                            ),
                        ],
                      ),
                    ),
                    _Section(s.chatSubNote),
                    _Field(
                      controller: _note,
                      hint: s.chatSubNoteHint,
                      lines: 4,
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: _saving || _events.isEmpty ? null : _save,
                        child: Text(
                          widget.sub == null ? s.chatSubCreate : s.save,
                        ),
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

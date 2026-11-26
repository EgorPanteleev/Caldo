part of 'agents_screen.dart';

/// A chat's settings, seen and changed after it began (asked as "wanna see
/// and edit the chat settings, model and etc", 2026-11-22): where it runs —
/// the computer, the agent, the folder, which stay — and what it runs
/// with, which can change: its title, model, effort, permissions, plugins,
/// skills and rules. Saved, the row is changed and the worker starts the
/// chat's program again with them on the same session, once the turn
/// under way is done.
class ChatSettingsScreen extends StatefulWidget {
  final String chat;

  const ChatSettingsScreen({super.key, required this.chat});

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  final _agents = Agents.instance;
  final _title = TextEditingController();

  /// The chat as it was opened: what is saved is told against it.
  late final Chat? _was = _agents.chat(widget.chat);

  String? _model;
  String? _effort;
  String? _permission;
  Set<String>? _plugins;
  final Set<String> _skills = {};

  /// The account it runs under; null for its worker's own.
  String? _account;

  /// Its rules as it keeps them, and which of those it still has: one
  /// dropped is gone; one of the kept rules chosen here is told in its
  /// words as they are now.
  final List<ChatRule> _kept = [];
  final Set<ChatRule> _keep = {};
  final Set<String> _added = {};
  bool _saving = false;

  /// What it is subscribed to, read when shown and after one is opened.
  List<Subscription> _subs = const [];

  Future<void> _readSubs() async {
    try {
      final subs = await _agents.subscriptionsOf(widget.chat);
      if (mounted) setState(() => _subs = subs);
    } catch (_) {
      // A server without the table yet: none.
    }
  }

  Future<void> _openSub(Subscription? sub) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SubscriptionScreen(chat: widget.chat, sub: sub),
      ),
    );
    await _readSubs();
  }

  @override
  void initState() {
    super.initState();
    _agents.addListener(_changed);
    _agents.watch();
    unawaited(_readSubs());
    final chat = _was;
    if (chat == null) return;
    _title
      ..text = chat.title
      ..addListener(_changed);
    _model = chat.model;
    _effort = chat.effort;
    _permission = chat.permission;
    _plugins = chat.plugins?.toSet();
    _skills.addAll(chat.skills);
    _account = chat.account;
    _kept.addAll(chat.rules);
    _keep.addAll(chat.rules);
  }

  @override
  void dispose() {
    _agents.removeListener(_changed);
    _agents.unwatch();
    _title.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  AgentWorker? get _w => _agents.worker(_was?.workerId);

  AgentKind? get _kind =>
      _w?.agents.where((a) => a.id == _was?.agent).firstOrNull;

  /// The kept rule that is [rule], by its name — or, unnamed, its words.
  ChatRule? _keptAs(AgentRule rule) => _kept
      .where(
        (r) =>
            r.name == rule.name &&
            (rule.name.trim().isNotEmpty || r.body == rule.body),
      )
      .firstOrNull;

  bool _chosen(AgentRule rule) {
    final kept = _keptAs(rule);
    return kept != null ? _keep.contains(kept) : _added.contains(rule.id);
  }

  void _toggle(AgentRule rule) {
    final kept = _keptAs(rule);
    if (kept != null) {
      _keep.contains(kept) ? _keep.remove(kept) : _keep.add(kept);
    } else {
      _added.contains(rule.id) ? _added.remove(rule.id) : _added.add(rule.id);
    }
  }

  /// The chat's kept rules no longer among those written here: renamed or
  /// deleted since, still shown so they can be dropped.
  List<ChatRule> get _orphans => [
    for (final r in _kept)
      if (!_agents.rules.any((rule) => _keptAs(rule) == r)) r,
  ];

  /// The rules it is to have: those kept, in their words, then the ones
  /// added, in theirs.
  List<ChatRule> get _rules => [
    for (final r in _kept)
      if (_keep.contains(r)) r,
    for (final rule in _agents.rules)
      if (_added.contains(rule.id) && _keptAs(rule) == null)
        (name: rule.name, body: rule.body),
  ];

  /// What differs from the chat as it was, as the row's fields.
  Map<String, Object?> get _fields {
    final was = _was;
    final kind = _kind;
    if (was == null) return const {};
    final rules = _rules;
    final plugins = _plugins;
    // Claude's own choice stays its own while it is what is chosen here.
    final pluginsOn = kind == null ? null : {...kind.pluginsOn};
    final pluginsNow =
        plugins == null || (pluginsOn != null && setEquals(plugins, pluginsOn))
        ? null
        : (plugins.toList()..sort());
    final pluginsWas = was.plugins == null
        ? null
        : pluginsOn != null && setEquals(was.plugins!.toSet(), pluginsOn)
        ? null
        : ([...was.plugins!]..sort());
    return {
      if (_title.text.trim() != was.title.trim()) 'title': _title.text.trim(),
      if (_model != was.model) 'model': _model,
      if (_effort != was.effort) 'effort': _effort,
      if (_permission != was.permission) 'permission': _permission,
      if (!listEquals(pluginsNow, pluginsWas)) 'plugins': pluginsNow,
      if (!setEquals(_skills, was.skills.toSet())) 'skills': _skills.toList(),
      if (_account != was.account) 'account': _account,
      if (!listEquals(rules, was.rules))
        'rules': [
          for (final r in rules) {'name': r.name, 'body': r.body},
        ],
    };
  }

  Future<void> _save() async {
    final fields = _fields;
    if (fields.isEmpty || _saving) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      await _agents.change(widget.chat, fields);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      } else if (mounted) {
        setState(() => _saving = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _cancel() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final chat = _agents.chat(widget.chat) ?? _was;
    final w = _w;
    final kind = _kind;
    // A worker from before this can't take them up: shown, not changed.
    final changes = kind?.settings ?? false;
    final dirty = _fields.isNotEmpty;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        backgroundColor: p.bg,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          maintainBottomViewPadding: true,
          child: Column(
            children: [
              DeskColumn(
                child: ScreenHeader(title: s.chatSettings, showBack: !dirty),
              ),
              Expanded(
                child: Stack(
                  children: [
                    DeskGutter(
                      builder: (context, gutter) => ListView(
                        padding: EdgeInsets.fromLTRB(
                          20 + gutter,
                          4,
                          20 + gutter,
                          0,
                        ),
                        children: [
                          if (chat != null) ...[
                            _Fact(
                              s.chatWorker,
                              w == null
                                  ? '—'
                                  : w.online
                                  ? w.name
                                  : '${w.name} · ${s.chatOffline}',
                            ),
                            _Fact(s.chatAgent, kind?.label ?? chat.agent),
                            if (_chatProjectName(chat) case final project?)
                              _Fact(s.chatProject, project),
                            _Fact(
                              s.chatFolder,
                              w == null
                                  ? chat.dir ?? '~'
                                  : _NewChatScreenState._short(
                                      w,
                                      chat.dir ?? '~',
                                    ),
                            ),
                          ],
                          _Section(s.chatTitle),
                          // Without one, it is called by its first message's first line.
                          _Field(
                            controller: _title,
                            hint: chat?.prompt.trim().split('\n').first,
                          ),
                          if (kind != null && !changes) ...[
                            const SizedBox(height: 20),
                            Text(
                              s.chatSettingsOld(w?.name ?? ''),
                              style: TextStyle(color: p.muted, fontSize: 13.5),
                            ),
                          ],
                          if (kind != null)
                            IgnorePointer(
                              ignoring: !changes,
                              child: Opacity(
                                opacity: changes ? 1 : 0.5,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: _choices(s, p, kind),
                                ),
                              ),
                            ),
                          if (changes) ...[
                            const SizedBox(height: 16),
                            Text(
                              s.chatSettingsHint(kind?.label ?? ''),
                              style: TextStyle(color: p.faint, fontSize: 12.5),
                            ),
                          ],
                          if ((kind?.events ?? false) || _subs.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _SubscriptionsList(
                              subs: _subs,
                              watched: kind?.events ?? false,
                              onOpen: _openSub,
                            ),
                          ],
                          SizedBox(height: dirty ? GroundFade.height : 24),
                          const KeyboardRoom(),
                        ],
                      ),
                    ),
                    if (dirty)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: KeyboardLift(child: GroundFade(ground: p.bg)),
                      ),
                  ],
                ),
              ),
              if (dirty)
                FormActions(
                  onCancel: _saving ? null : _cancel,
                  onSave: _saving ? null : _save,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// What it runs with, chosen as on the new chat's form.
  List<Widget> _choices(S s, AppPalette p, AgentKind kind) => [
    // Another account carries the same session on: one at its limit is
    // left for another.
    if (_w case final w?)
      ...accountPicks(
        context,
        worker: w,
        kind: kind,
        chosen: _account,
        onPick: (id) => setState(() => _account = id),
      ),
    _Section(s.chatModel),
    _ModelPicker(
      kind: kind,
      model: _model,
      onPick: (model) => setState(() => _model = model),
    ),
    if (kind.efforts.isNotEmpty) ...[
      _Section(s.chatEffort),
      _Picks(
        children: [
          _Pick(
            label: s.chatDefault,
            selected: _effort == null,
            onTap: () => setState(() => _effort = null),
          ),
          for (final e in kind.efforts)
            _Pick(
              label: e,
              selected: e == _effort,
              onTap: () => setState(() => _effort = e),
            ),
        ],
      ),
    ],
    if (kind.permissions.isNotEmpty) ...[
      _Section(s.chatPermission),
      _Picks(
        children: [
          for (final m in kind.permissions)
            _Pick(
              label: m,
              selected: m == _permission,
              onTap: () => setState(() => _permission = m),
            ),
        ],
      ),
    ],
    if (kind.plugins.isNotEmpty) ...[
      _Section(s.chatPlugins),
      for (final plugin in kind.plugins)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            plugin.split('@').first,
            style: TextStyle(color: p.text, fontSize: 14),
          ),
          subtitle: plugin.contains('@')
              ? Text(
                  plugin.split('@').last,
                  style: TextStyle(color: p.faint, fontSize: 12),
                )
              : null,
          value: _plugins?.contains(plugin) ?? kind.pluginsOn.contains(plugin),
          onChanged: (on) => setState(() {
            final chosen = _plugins ??= {...kind.pluginsOn};
            on ? chosen.add(plugin) : chosen.remove(plugin);
          }),
        ),
    ],
    // Those it has that the worker no longer offers are shown too, so
    // they can be dropped.
    if (kind.skills.isNotEmpty || _skills.isNotEmpty) ...[
      _Section(s.chatSkills),
      _Picks(
        children: [
          for (final skill in {...kind.skills, ..._skills})
            _Pick(
              label: skill,
              selected: _skills.contains(skill),
              onTap: () => setState(() {
                _skills.contains(skill)
                    ? _skills.remove(skill)
                    : _skills.add(skill);
              }),
            ),
        ],
      ),
    ],
    if (kind.rules || _kept.isNotEmpty) ...[
      _Section(s.agentRules),
      _Picks(
        children: [
          for (final rule in _agents.rules)
            _Pick(
              label: _ruleName(s, rule),
              selected: _chosen(rule),
              onTap: () => setState(() => _toggle(rule)),
            ),
          for (final r in _orphans)
            _Pick(
              label: _ruleName(
                s,
                AgentRule(id: '', name: r.name, body: r.body),
              ),
              selected: _keep.contains(r),
              onTap: () => setState(() {
                _keep.contains(r) ? _keep.remove(r) : _keep.add(r);
              }),
            ),
          _Pick(
            label: _agents.rules.isEmpty ? s.newRule : s.editRules,
            icon: _agents.rules.isEmpty ? Icons.add : Icons.edit_outlined,
            selected: false,
            onTap: () =>
                _agents.rules.isEmpty ? openRule(context) : openRules(context),
          ),
        ],
      ),
    ],
  ];
}

/// One of what a chat was started with that stays: its name over its
/// value.
class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: TextStyle(color: p.faint, fontSize: 13.5),
            ),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: p.text, fontSize: 14.5)),
          ),
        ],
      ),
    );
  }
}

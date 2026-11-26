part of 'agents_screen.dart';

Future<void> openChatContext(BuildContext context, Chat chat) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => ChatContextScreen(chat: chat)));

/// What a chat is told it knows, from the chat itself (asked for
/// 2026-11-26: "make ability to watch content from chats, not projects
/// tab"): the context of the chats it is part of, read only — changed in
/// that chat, a tap away — then its project's info and its own, each to
/// change in place. Nothing else: its agent reads no CLAUDE.md or memory
/// files (`quietEnv`), so no files are shown.
class ChatContextScreen extends StatefulWidget {
  final Chat chat;

  const ChatContextScreen({super.key, required this.chat});

  @override
  State<ChatContextScreen> createState() => _ChatContextScreenState();
}

class _ChatContextScreenState extends State<ChatContextScreen> {
  final _agents = Agents.instance;
  bool _importing = false;

  /// The chat as it is now: changed on this page, or from another.
  Chat get _chat => _agents.chat(widget.chat.id) ?? widget.chat;

  /// The chats it is part of, outermost first.
  List<Chat> get _parents {
    final out = <Chat>[];
    final seen = {_chat.id};
    var up = _agents.chat(_chat.parentId ?? '');
    while (up != null && seen.add(up.id)) {
      out.insert(0, up);
      up = _agents.chat(up.parentId ?? '');
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _agents.addListener(_changed);
    // Its file may have been edited on a computer since: read as it is.
    unawaited(_agents.loadProjects());
  }

  @override
  void dispose() {
    _agents.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _edit({
    required String title,
    required String where,
    required String text,
    required Future<void> Function(String text) save,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          _ContextEditor(title: title, where: where, text: text, save: save),
    ),
  );

  Future<void> _editProject(AgentProject project, {String? text}) async {
    final s = S.of(context);
    // Begun from the latest words, an agent's edit of a moment ago too.
    await _agents.loadProjects();
    if (!mounted) return;
    final now = _agents.project(project.id) ?? project;
    await _edit(
      title: s.contextProject,
      where: s.contextProjectHint(_projectName(s, now)),
      text: text ?? now.context,
      save: (text) => _agents.setProjectInfo(now, text),
    );
  }

  /// The project's info begun from the `CLAUDE.md` of each of its folders,
  /// as the chat's computer has them, after what is written already: put
  /// in the editor to look over before it is saved.
  Future<void> _import(AgentProject project) async {
    final s = S.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _importing = true);
    try {
      final files = await _agents.readContext(_chat.workerId!, project);
      final taken = [
        for (final f in files)
          if (f.kind == 'folder' &&
              f.source != null &&
              f.path.startsWith('${f.source}/') &&
              (f.body?.trim().isNotEmpty ?? false) &&
              // Caldo's own copy of the info, not words to take in.
              !ProjectSync.written(f.body))
            f.body!.trim(),
      ];
      if (!mounted) return;
      if (taken.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(s.contextImportNone)));
        return;
      }
      final text = [
        if (project.context.trim().isNotEmpty) project.context.trim(),
        ...taken,
      ].join('\n\n');
      await _editProject(project, text: text);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(e is TimeoutException ? s.contextNoAnswer : '$e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final chat = _chat;
    final parents = _parents;
    final project = _agents.project(chat.projectId);
    final online = _agents.worker(chat.workerId)?.online == true;
    Widget hint(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: TextStyle(color: p.faint, fontSize: 12.5)),
    );
    return AppScaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(title: s.chatContext, showBack: true),
            ),
            Expanded(
              child: DeskGutter(
                builder: (context, gutter) => ListView(
                  padding: EdgeInsets.fromLTRB(20 + gutter, 4, 20 + gutter, 24),
                  children: [
                    Text(
                      s.chatContextHint,
                      style: TextStyle(color: p.faint, fontSize: 12.5),
                    ),
                    if (parents.isNotEmpty) ...[
                      _Section(s.contextParents),
                      hint(s.contextParentHint),
                      for (final parent in parents)
                        _ContextTile(
                          title: parent.name.isEmpty
                              ? _lineOf(parent)
                              : parent.name,
                          icon: Icons.subdirectory_arrow_right,
                          trailing: Icons.chevron_right,
                          body: parent.context,
                          empty: s.contextNothing,
                          onTap: () => openChatContext(context, parent),
                        ),
                    ],
                    _Section(s.contextProject),
                    if (project == null)
                      hint(s.contextNoProject)
                    else ...[
                      hint(s.contextProjectHint(_projectName(s, project))),
                      _ContextTile(
                        title: _projectName(s, project),
                        dot: _projectColour(project),
                        body: project.context,
                        empty: s.contextNothing,
                        onTap: () => _editProject(project),
                      ),
                      Wrap(
                        children: [
                          TextButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    ProjectHistoryScreen(project: project),
                              ),
                            ),
                            icon: const Icon(Icons.history, size: 18),
                            label: Text(s.contextHistory),
                          ),
                          if (online && project.sources.isNotEmpty)
                            TextButton.icon(
                              onPressed: _importing
                                  ? null
                                  : () => _import(project),
                              icon: _importing
                                  ? const SizedBox.square(
                                      dimension: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.download_outlined,
                                      size: 18,
                                    ),
                              label: Text(s.contextImport),
                            ),
                        ],
                      ),
                    ],
                    _Section(s.contextOwn),
                    hint(s.contextOwnHint),
                    _ContextTile(
                      title: chat.name.isEmpty ? _lineOf(chat) : chat.name,
                      icon: Icons.chat_bubble_outline,
                      body: chat.context,
                      empty: s.contextNothing,
                      onTap: () => _edit(
                        title: s.contextOwn,
                        where: s.contextOwnHint,
                        text: chat.context,
                        save: (text) => _agents.setContext(chat, text),
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

/// A project's info as it was, its last versions the latest first (asked
/// 2026-11-26, with its file made two-way: "include history/restore, but
/// make history a bit smaller" — the server keeps 20): who made each, and
/// a tap to read one whole and restore it.
class ProjectHistoryScreen extends StatefulWidget {
  final AgentProject project;

  /// Given in tests, in place of the server's.
  final List<ProjectVersion>? versions;

  const ProjectHistoryScreen({
    super.key,
    required this.project,
    @visibleForTesting this.versions,
  });

  @override
  State<ProjectHistoryScreen> createState() => _ProjectHistoryScreenState();
}

class _ProjectHistoryScreenState extends State<ProjectHistoryScreen> {
  final _agents = Agents.instance;
  List<ProjectVersion>? _versions;
  Object? _failed;

  AgentProject get _project =>
      _agents.project(widget.project.id) ?? widget.project;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    if (widget.versions case final given?) {
      return setState(() => _versions = given);
    }
    try {
      final versions = await _agents.projectVersions(widget.project.id);
      if (mounted) setState(() => _versions = versions);
    } catch (e) {
      if (mounted) setState(() => _failed = e);
    }
  }

  /// The version that is the info now: the latest saved, not an edit kept
  /// aside.
  int? get _current => _versions?.where((v) => !v.unmerged).firstOrNull?.id;

  Future<void> _open(ProjectVersion version) async {
    final restored = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _VersionScreen(
          project: _project,
          version: version,
          current: version.id == _current,
        ),
      ),
    );
    if (restored != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(S.of(context).historyRestoredDone(version.version)),
      ),
    );
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final versions = _versions;
    return AppScaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(title: s.contextHistory, showBack: true),
            ),
            Expanded(
              child: versions == null
                  ? Center(
                      child: _failed != null
                          ? Text(
                              '$_failed',
                              style: TextStyle(color: p.muted, fontSize: 13),
                            )
                          : const CircularProgressIndicator(strokeWidth: 2),
                    )
                  : versions.isEmpty
                  ? Center(
                      child: Text(
                        s.historyEmpty,
                        style: TextStyle(color: p.faint, fontSize: 13.5),
                      ),
                    )
                  : DeskGutter(
                      builder: (context, gutter) => ListView(
                        padding: EdgeInsets.fromLTRB(
                          20 + gutter,
                          4,
                          20 + gutter,
                          24,
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              _projectName(s, _project),
                              style: TextStyle(color: p.faint, fontSize: 12.5),
                            ),
                          ),
                          for (final v in versions)
                            _ContextTile(
                              title: '${v.version} · ${_versionBy(s, v)}',
                              icon: v.unmerged
                                  ? Icons.call_split
                                  : Icons.history,
                              trailing: Icons.chevron_right,
                              body: [
                                [
                                  '${Dates.shortDay(v.at)} ${Dates.time(v.at)}',
                                  if (v.id == _current) s.historyNow,
                                  if (v.unmerged) s.historyUnmerged,
                                ].join(' · '),
                                v.context,
                              ].join('\n'),
                              empty: s.contextNothing,
                              onTap: () => _open(v),
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

/// Who made [v], as the history names them.
String _versionBy(S s, ProjectVersion v) {
  final by = v.by;
  if (by.startsWith('computer:')) {
    return s.historyByComputer(by.substring('computer:'.length));
  }
  if (by.startsWith('chat:')) {
    final id = by.substring('chat:'.length);
    final chat = Agents.instance.chat(id);
    final name = chat == null
        ? id.substring(0, id.length < 8 ? id.length : 8)
        : chat.name.isEmpty
        ? _lineOf(chat)
        : chat.name;
    return s.historyByChat(name);
  }
  return switch (by) {
    'restore' => s.historyRestored,
    'assistant' => s.historyByAssistant,
    _ => s.historyByApp,
  };
}

/// One version of a project's info, whole, with Restore unless it is the
/// info now. Pops true once restored.
class _VersionScreen extends StatefulWidget {
  final AgentProject project;
  final ProjectVersion version;
  final bool current;

  const _VersionScreen({
    required this.project,
    required this.version,
    required this.current,
  });

  @override
  State<_VersionScreen> createState() => _VersionScreenState();
}

class _VersionScreenState extends State<_VersionScreen> {
  bool _restoring = false;

  Future<void> _restore() async {
    setState(() => _restoring = true);
    try {
      await Agents.instance.restoreProject(widget.project, widget.version);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoring = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final v = widget.version;
    return AppScaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: '${s.contextHistory} · ${v.version}',
                showBack: true,
              ),
            ),
            Expanded(
              child: DeskGutter(
                builder: (context, gutter) => Padding(
                  padding: EdgeInsets.fromLTRB(20 + gutter, 0, 20 + gutter, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        [
                          _versionBy(s, v),
                          '${Dates.shortDay(v.at)} ${Dates.time(v.at)}',
                          if (widget.current) s.historyNow,
                          if (v.unmerged) s.historyUnmerged,
                        ].join(' · '),
                        style: TextStyle(color: p.faint, fontSize: 12.5),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: p.field,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(14),
                            child: SelectableText(
                              v.context.isEmpty ? s.contextNothing : v.context,
                              style: TextStyle(
                                color: p.text,
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (!widget.current) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 48,
                          child: FilledButton(
                            onPressed: _restoring ? null : _restore,
                            child: Text(s.historyRestore),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A part of a chat's context: whose it is, the start of its words, and a
/// tap to change them, or to go where they are changed.
class _ContextTile extends StatelessWidget {
  final String title;
  final String? body;

  /// Shown in place of the words when there are none.
  final String empty;
  final IconData? icon;
  final Color? dot;
  final IconData trailing;
  final VoidCallback onTap;

  const _ContextTile({
    required this.title,
    required this.body,
    required this.empty,
    required this.onTap,
    this.icon,
    this.dot,
    this.trailing = Icons.edit_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final words = body?.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (dot case final colour?) ...[
                      _Dot(colour: colour, size: 8),
                      const SizedBox(width: 8),
                    ] else if (icon case final icon?) ...[
                      Icon(icon, size: 15, color: p.muted),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(trailing, size: 15, color: p.faint),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  words.isEmpty ? empty : words,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: words.isEmpty ? p.faint : p.muted,
                    fontSize: 13,
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

/// One part of a chat's context written whole; pops once saved.
class _ContextEditor extends StatefulWidget {
  final String title;

  /// What the words are, and who is told them.
  final String where;
  final String text;
  final Future<void> Function(String text) save;

  const _ContextEditor({
    required this.title,
    required this.where,
    required this.text,
    required this.save,
  });

  @override
  State<_ContextEditor> createState() => _ContextEditorState();
}

class _ContextEditorState extends State<_ContextEditor> {
  late final _text = TextEditingController(text: widget.text);
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.save(_text.text);
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
    return AppScaffold(
      backgroundColor: p.bg,
      // The field ends above the keys by [KeyboardGap] alone.
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(title: widget.title, showBack: true),
            ),
            Expanded(
              child: DeskGutter(
                builder: (context, gutter) => Padding(
                  padding: EdgeInsets.fromLTRB(
                    20 + gutter,
                    0,
                    20 + gutter,
                    16 + KeyboardGap.of(context),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.where,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.faint, fontSize: 12.5),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: TextField(
                          controller: _text,
                          expands: true,
                          maxLines: null,
                          textAlignVertical: TextAlignVertical.top,
                          style: TextStyle(
                            color: p.text,
                            fontSize: 14,
                            height: 1.4,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            filled: true,
                            fillColor: p.field,
                            contentPadding: const EdgeInsets.all(14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 48,
                        child: FilledButton(
                          onPressed: _saving || _text.text == widget.text
                              ? null
                              : _save,
                          child: Text(s.save),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

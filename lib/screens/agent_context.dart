part of 'agents_screen.dart';

Future<void> openProjectContext(BuildContext context, AgentProject project) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProjectContextScreen(project: project),
      ),
    );

/// Everything a chat begun in a project is told, each part to read and
/// change: the words kept on it and on the projects above it, then what
/// Claude reads on a worker — the user's own `CLAUDE.md`, the project's
/// folders' and their memory ([ContextFiles], asked of the worker through
/// [Agents.readContext]).
class ProjectContextScreen extends StatefulWidget {
  final AgentProject project;

  const ProjectContextScreen({super.key, required this.project});

  @override
  State<ProjectContextScreen> createState() => _ProjectContextScreenState();
}

class _ProjectContextScreenState extends State<ProjectContextScreen> {
  final _agents = Agents.instance;

  /// The worker the files are read from; null until one is there.
  String? _worker;
  List<ContextFile>? _files;
  bool _reading = false;
  Object? _failed;

  /// The project as it is now: changed on this page, or from another.
  AgentProject get _project =>
      _agents.project(widget.project.id) ?? widget.project;

  List<AgentWorker> get _online => [
    for (final w in _agents.workers)
      if (w.online) w,
  ];

  @override
  void initState() {
    super.initState();
    _agents.addListener(_changed);
    unawaited(_read());
  }

  @override
  void dispose() {
    _agents.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // A worker come since: its files are read.
    if (_worker == null && _online.isNotEmpty) unawaited(_read());
  }

  Future<void> _read() async {
    final online = _online;
    if (!online.any((w) => w.id == _worker)) {
      _worker = online.firstOrNull?.id;
    }
    final worker = _worker;
    if (worker == null || _reading) return;
    setState(() {
      _reading = true;
      _failed = null;
    });
    try {
      final files = await _agents.readContext(worker, _project);
      if (!mounted || worker != _worker) return;
      setState(() => _files = files);
    } catch (e) {
      if (mounted) setState(() => _failed = e);
    } finally {
      if (mounted) {
        setState(() => _reading = false);
        // Another worker picked meanwhile: its files are read now.
        if (worker != _worker) unawaited(_read());
      }
    }
  }

  void _pickWorker(String id) {
    if (id == _worker) return;
    setState(() {
      _worker = id;
      _files = null;
    });
    unawaited(_read());
  }

  String get _workerName =>
      _agents.workers.where((w) => w.id == _worker).firstOrNull?.name ?? '';

  /// The words of [project] changed in place, the rest of it as it is.
  Future<void> _editWords(AgentProject project) => _openEditor(
    title: _projectName(S.of(context), project),
    where: S.of(context).contextWords,
    text: project.context,
    save: (text) => _agents.saveProject(
      id: project.id,
      parentId: project.parentId,
      name: project.name,
      colour: project.colour,
      context: text.trim(),
      sources: project.sources,
    ),
  );

  Future<void> _editFile(ContextFile file) {
    final worker = _worker!;
    Future<void> put(String? body) async {
      final written = await _agents.writeContext(worker, file, body);
      if (!mounted) return;
      setState(() {
        final files = _files ?? const <ContextFile>[];
        _files = [
          for (final f in files)
            if (f.path != file.path)
              f
            else if (written.body != null || !file.memory)
              written,
        ];
      });
    }

    return _openEditor(
      title: file.name,
      where: file.path,
      text: file.body ?? '',
      save: put,
      remove: file.memory && file.body != null ? () => put(null) : null,
    );
  }

  Future<void> _openEditor({
    required String title,
    required String where,
    required String text,
    required Future<void> Function(String text) save,
    Future<void> Function()? remove,
  }) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ContextEditor(
          title: title,
          where: where,
          text: text,
          save: save,
          remove: remove,
        ),
      ),
    );
    // Written over on the computer meanwhile: read as it is now.
    if (changed == false) await _read();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final project = _project;
    final online = _online;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: s.projectAllContext,
                showBack: true,
                actions: [
                  if (_worker != null)
                    IconButton(
                      icon: Icon(Icons.refresh, color: p.muted),
                      tooltip: s.contextReadAgain,
                      onPressed: _reading ? null : _read,
                    ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
            Expanded(
              child: DeskGutter(
                builder: (context, gutter) => ListView(
                  padding: EdgeInsets.fromLTRB(20 + gutter, 4, 20 + gutter, 24),
                  children: [
                    Text(
                      s.projectAllContextHint(_agents.pathOf(project)),
                      style: TextStyle(color: p.faint, fontSize: 12.5),
                    ),
                    _Section(s.contextInCaldo),
                    for (final above in _agents.lineOf(project))
                      _ContextTile(
                        title: _projectName(s, above),
                        dot: _projectColour(above),
                        body: above.context,
                        empty: s.contextNothing,
                        onTap: () => _editWords(above),
                      ),
                    if (online.length > 1) ...[
                      const SizedBox(height: 12),
                      _Picks(
                        children: [
                          for (final w in online)
                            _Pick(
                              label: w.name,
                              icon: Icons.computer_outlined,
                              selected: w.id == _worker,
                              onTap: () => _pickWorker(w.id),
                            ),
                        ],
                      ),
                    ],
                    _Section(
                      _worker == null
                          ? s.contextOnComputer
                          : s.contextOnWorker(_workerName),
                    ),
                    ..._fileTiles(s, p),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// [file]'s path under its folder, which heads it; whole if above it.
  static String _within(ContextFile file) {
    final source = file.source;
    return source != null && file.path.startsWith('$source/')
        ? file.path.substring(source.length + 1)
        : file.path;
  }

  /// What a memory file says: its description and words, without the
  /// frontmatter they are filed under.
  static String? _gist(String? body) {
    if (body == null || !body.startsWith('---\n')) return body;
    final end = body.indexOf('\n---', 4);
    if (end < 0) return body;
    final description = RegExp(
      r'^description:\s*(.*)$',
      multiLine: true,
    ).firstMatch(body.substring(4, end))?.group(1)?.trim();
    final rest = body.substring(end + 4).trim();
    return [
      if (description != null && description.isNotEmpty)
        description.replaceAll(RegExp(r'''^["']|["']$'''), ''),
      if (rest.isNotEmpty) rest,
    ].join('\n');
  }

  static String _why(S s, Object e) =>
      e is TimeoutException ? s.contextNoAnswer : '$e';

  List<Widget> _fileTiles(S s, AppPalette p) {
    Widget note(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text, style: TextStyle(color: p.muted, fontSize: 13.5)),
    );
    if (_worker == null) return [note(s.contextNoWorker)];
    final files = _files;
    if (files == null) {
      if (_failed case final failed?) return [note(_why(s, failed))];
      return [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ];
    }
    ContextFile? user;
    final bySource = <String, List<ContextFile>>{};
    for (final f in files) {
      if (f.kind == 'user') {
        user = f;
      } else {
        (bySource[f.source ?? ''] ??= []).add(f);
      }
    }
    Widget tile(ContextFile f, {String? title}) => _ContextTile(
      title: title ?? _within(f),
      icon: f.memory ? Icons.lightbulb_outline : Icons.description_outlined,
      body: f.memory ? _gist(f.body) : f.body,
      empty: f.body == null ? s.contextMissing : s.contextNothing,
      badge: f.uncommitted ? s.contextUncommitted : null,
      onTap: () => _editFile(f),
    );
    return [
      if (user != null) tile(user, title: s.contextUserFile),
      for (final MapEntry(key: source, value: here) in bySource.entries) ...[
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 15, color: p.faint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final f in here)
          if (!f.memory) tile(f),
        if (here.any((f) => f.memory)) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Text(
              s.contextMemory,
              style: TextStyle(color: p.faint, fontSize: 12.5),
            ),
          ),
          for (final f in here)
            if (f.memory) tile(f, title: f.name),
        ],
      ],
      if (_reading)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(minHeight: 2),
        ),
      if (_failed case final failed?) note(_why(s, failed)),
    ];
  }
}

/// A part of a project's context: its name, the start of its words, and a
/// tap to change them.
class _ContextTile extends StatelessWidget {
  final String title;
  final String? body;

  /// Shown in place of the words when there are none.
  final String empty;
  final IconData? icon;
  final Color? dot;
  final String? badge;
  final VoidCallback onTap;

  const _ContextTile({
    required this.title,
    required this.body,
    required this.empty,
    required this.onTap,
    this.icon,
    this.dot,
    this.badge,
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
                    Icon(Icons.edit_outlined, size: 15, color: p.faint),
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
                if (badge != null) ...[
                  const SizedBox(height: 6),
                  Text(badge!, style: TextStyle(color: p.faint, fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One part of a project's context written whole. Pops true once saved,
/// false if it was changed elsewhere meanwhile and is left as it was.
class _ContextEditor extends StatefulWidget {
  final String title;

  /// Where it is kept: a file's path, or what the words are.
  final String where;
  final String text;
  final Future<void> Function(String text) save;

  /// Takes it away; null for one that can't be.
  final Future<void> Function()? remove;

  const _ContextEditor({
    required this.title,
    required this.where,
    required this.text,
    required this.save,
    this.remove,
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

  Future<void> _do(Future<void> Function() body) async {
    setState(() => _saving = true);
    try {
      await body();
      if (mounted) Navigator.of(context).pop(true);
    } on ContextChanged {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.of(context).contextChanged)));
      Navigator.of(context).pop(false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final s = S.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is TimeoutException ? s.contextNoAnswer : '$e'),
        ),
      );
    }
  }

  Future<void> _remove() async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.contextDeleteQuestion),
        content: Text(widget.where),
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
    if (ok == true) await _do(widget.remove!);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      // The field ends above the keys by [KeyboardGap] alone.
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: widget.title,
                showBack: true,
                actions: [
                  if (widget.remove != null)
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: p.muted),
                      tooltip: s.delete,
                      onPressed: _saving ? null : _remove,
                    ),
                  const SizedBox(width: 6),
                ],
              ),
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
                              : () => _do(() => widget.save(_text.text)),
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

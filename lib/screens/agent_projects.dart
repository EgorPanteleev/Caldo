part of 'agents_screen.dart';

/// The colour [project] wears: its own, else its nearest parent's.
Color _projectColour(AgentProject project) =>
    ListStyle.byId(Agents.instance.colourOf(project)).color;

/// The colour [chat] wears in the list: its project's as it is now, else
/// as it was when the chat began; null for a chat in none.
Color? _chatColour(Chat chat) {
  final project = Agents.instance.project(chat.projectId);
  if (project != null) return _projectColour(project);
  if (chat.projectName == null && chat.projectColour == null) return null;
  return ListStyle.byId(chat.projectColour).color;
}

/// [chat]'s project's name: as it is now, else as it was.
String? _chatProjectName(Chat chat) {
  final agents = Agents.instance;
  final project = agents.project(chat.projectId);
  return project != null ? agents.pathOf(project) : chat.projectName;
}

class _Dot extends StatelessWidget {
  final Color colour;
  final double size;

  const _Dot({required this.colour, required this.size});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
    ),
  );
}

/// The projects chats are begun in, each under its parent: what a chat is
/// about, told to its agent, and the folders it works on. Asked for in
/// place of choosing a chat's folder by hand, each chat working in a
/// folder of its own ([Workspace] on the worker).
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  final _agents = Agents.instance;

  @override
  void initState() {
    super.initState();
    _agents.addListener(_changed);
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

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final projects = _agents.projects;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: s.agentProjects,
                showBack: true,
                actions: [
                  IconButton(
                    icon: Icon(Icons.add, color: p.muted),
                    tooltip: s.newProject,
                    onPressed: () => openProject(context),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
            Expanded(
              child: projects.isEmpty
                  ? EmptyState(
                      icon: Icons.workspaces_outlined,
                      title: s.noProjects,
                      message: s.noProjectsHint,
                    )
                  : DeskGutter(
                      builder: (context, gutter) => ListView.separated(
                        padding: EdgeInsets.fromLTRB(
                          16 + gutter,
                          4,
                          16 + gutter,
                          24,
                        ),
                        itemCount: projects.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) =>
                            _ProjectRow(project: projects[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> openProjects(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const ProjectsScreen()));

/// Project [project] to change, or a new one, under [parent] if given.
Future<void> openProject(
  BuildContext context, {
  AgentProject? project,
  AgentProject? parent,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ProjectScreen(project: project, parent: parent),
  ),
);

/// A project's name, or a word for one without.
String _projectName(S s, AgentProject project) =>
    project.name.trim().isEmpty ? s.untitledProject : project.name.trim();

/// A project in the list, set in under its parent, in its colour.
class _ProjectRow extends StatelessWidget {
  final AgentProject project;

  const _ProjectRow({required this.project});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final colour = _projectColour(project);
    final depth = Agents.instance.depthOf(project);
    final about = project.context.trim().isNotEmpty
        ? project.context.trim()
        : project.sources.join('  ');
    return Padding(
      padding: EdgeInsets.only(left: 18.0 * depth.clamp(0, 6)),
      child: Material(
        color: Color.alphaBlend(colour.withValues(alpha: 0.16), p.panel),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openProject(context, project: project),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: _Dot(colour: colour, size: 10),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _projectName(s, project),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (about.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          about,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 13),
                        ),
                      ],
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

/// One project written or changed: its name, colour, context and folders,
/// with what it takes from the projects above it shown, and the projects
/// under it.
class ProjectScreen extends StatefulWidget {
  /// Null for a new one.
  final AgentProject? project;

  /// What a new one is made under; null for one under none.
  final AgentProject? parent;

  const ProjectScreen({super.key, this.project, this.parent});

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  final _agents = Agents.instance;
  late final _name = TextEditingController(text: widget.project?.name);
  late final _context = TextEditingController(text: widget.project?.context);
  late final _sources = TextEditingController(
    text: widget.project?.sources.join('\n'),
  );

  /// Null takes the parent's.
  String? _colour;
  bool _saving = false;

  AgentProject? get _parent =>
      widget.parent ?? _agents.project(widget.project?.parentId);

  @override
  void initState() {
    super.initState();
    _agents.addListener(_changed);
    _name.addListener(_changed);
    _sources.addListener(_changed);
    _colour = widget.project?.colour;
    if (widget.project == null && _parent == null) _colour = _freeColour();
  }

  @override
  void dispose() {
    _agents.removeListener(_changed);
    _name.dispose();
    _context.dispose();
    _sources.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The first colour of the palette no project at the top wears yet, so
  /// projects are told apart without choosing.
  String _freeColour() {
    final worn = {
      for (final p in _agents.childrenOf(null))
        if (p.colour != null) p.colour,
    };
    final free = ListStyle.presets.where((s) => !worn.contains(s.id));
    final pick = free.isNotEmpty
        ? free.first
        : ListStyle.presets[worn.length % ListStyle.presets.length];
    return pick.id;
  }

  List<String> get _sourceLines => [
    for (final line in _sources.text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  /// [dir] put among the folders, or taken out if it is there.
  void _toggleSource(String dir) {
    final lines = _sourceLines;
    lines.contains(dir) ? lines.remove(dir) : lines.add(dir);
    _sources.text = lines.join('\n');
  }

  /// Folders the workers have used Claude in, from `~`, offered to tap.
  List<String> get _offered {
    final out = <String>{};
    for (final w in _agents.workers) {
      for (final d in w.dirs) {
        final short = _NewChatScreenState._short(w, d);
        if (short != '~') out.add(short);
      }
    }
    return out.take(16).toList();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _agents.saveProject(
        id: widget.project?.id,
        parentId: _parent?.id,
        name: _name.text.trim(),
        colour: _colour,
        context: _context.text.trim(),
        sources: _sourceLines,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Everything its chats are told, to read and change; its words changed
  /// there are taken in here, so saving here doesn't put them back.
  Future<void> _allContext() async {
    final project = widget.project!;
    final before = _agents.project(project.id)?.context ?? project.context;
    await openProjectContext(context, project);
    final now = _agents.project(project.id)?.context;
    if (mounted && now != null && now != before) _context.text = now;
  }

  Future<void> _delete() async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteProjectQuestion),
        content: Text(s.deleteProjectHint),
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
    if (ok != true) return;
    await _agents.removeProject(widget.project!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final project = widget.project;
    final parent = _parent;
    final above = parent == null
        ? const <AgentProject>[]
        : _agents.lineOf(parent);
    final children = project == null
        ? const <AgentProject>[]
        : _agents.childrenOf(project.id);
    final lines = _sourceLines;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: project != null
                    ? s.editProject
                    : parent != null
                    ? s.newSubproject
                    : s.newProject,
                showBack: true,
                actions: [
                  if (project != null)
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
                    if (parent != null) ...[
                      _Section(s.projectFrom(_agents.pathOf(parent))),
                      _Inherited(line: above),
                    ],
                    _Section(s.projectName),
                    _Field(controller: _name),
                    _Section(s.projectColour),
                    ColourSelector(
                      value: _colour,
                      // A subproject may wear its parent's colour.
                      groupColour: parent == null
                          ? null
                          : _projectColour(parent),
                      sample: _name.text.trim().isEmpty
                          ? s.newProject
                          : _name.text.trim(),
                      onChanged: (id) => setState(() => _colour = id),
                    ),
                    _Section(s.projectContext),
                    _Field(
                      controller: _context,
                      hint: s.projectContextHint,
                      lines: 14,
                    ),
                    if (project != null) ...[
                      const SizedBox(height: 8),
                      _Picks(
                        children: [
                          _Pick(
                            label: s.projectAllContext,
                            icon: Icons.layers_outlined,
                            selected: false,
                            onTap: _allContext,
                          ),
                        ],
                      ),
                    ],
                    _Section(s.projectSources),
                    _Field(
                      controller: _sources,
                      hint: '~/dev/src/Caldo',
                      lines: 4,
                    ),
                    if (_offered case final offered
                        when offered.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _Picks(
                        children: [
                          for (final d in offered)
                            _Pick(
                              label: d,
                              icon: Icons.folder_outlined,
                              selected: lines.contains(d),
                              onTap: () => _toggleSource(d),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      s.projectSourcesHint,
                      style: TextStyle(color: p.faint, fontSize: 12.5),
                    ),
                    if (project != null) ...[
                      _Section(s.projectSubprojects),
                      _Picks(
                        children: [
                          for (final c in children)
                            _Pick(
                              label: _projectName(s, c),
                              dot: _projectColour(c),
                              selected: false,
                              onTap: () => openProject(context, project: c),
                            ),
                          _Pick(
                            label: s.newSubproject,
                            icon: Icons.add,
                            selected: false,
                            onTap: () => openProject(context, parent: project),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: _saving || _name.text.trim().isEmpty
                            ? null
                            : _save,
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

/// What a subproject takes from the projects above it: their words, the
/// whole project's first, and their folders.
class _Inherited extends StatelessWidget {
  final List<AgentProject> line;

  const _Inherited({required this.line});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final sources = {for (final project in line) ...project.sources};
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final project in line)
            if (project.context.trim().isNotEmpty) ...[
              Row(
                children: [
                  _Dot(colour: _projectColour(project), size: 8),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _projectName(s, project),
                      style: TextStyle(
                        color: p.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                project.context.trim(),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
              const SizedBox(height: 10),
            ],
          for (final dir in sources)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined, size: 14, color: p.faint),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      dir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          if (sources.isEmpty &&
              line.every((project) => project.context.trim().isEmpty))
            Text('—', style: TextStyle(color: p.faint, fontSize: 13)),
        ],
      ),
    );
  }
}

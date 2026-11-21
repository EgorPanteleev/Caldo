part of 'agents_screen.dart';

/// The rules kept for agents: standing instructions written once and
/// chosen for each chat on the new chat's form. Each is a name, to pick it
/// by, and its words, which the agent is told as they stood when the chat
/// began (`lib/mcp/agents.dart`, `rulesText`).
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  final _agents = Agents.instance;

  @override
  void initState() {
    super.initState();
    _agents.addListener(_changed);
    unawaited(_agents.loadRules());
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
    final rules = _agents.rules;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: s.agentRules,
                showBack: true,
                actions: [
                  IconButton(
                    icon: Icon(Icons.add, color: p.muted),
                    tooltip: s.newRule,
                    onPressed: () => openRule(context),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
            Expanded(
              child: rules.isEmpty
                  ? EmptyState(
                      icon: Icons.rule_rounded,
                      title: s.noRules,
                      message: s.noRulesHint,
                    )
                  : DeskGutter(
                      builder: (context, gutter) => ListView.separated(
                        padding: EdgeInsets.fromLTRB(
                          16 + gutter,
                          4,
                          16 + gutter,
                          24,
                        ),
                        itemCount: rules.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => _RuleRow(rule: rules[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> openRules(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const RulesScreen()));

Future<void> openRule(BuildContext context, [AgentRule? rule]) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => RuleScreen(rule: rule)));

class _RuleRow extends StatelessWidget {
  final AgentRule rule;

  const _RuleRow({required this.rule});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: p.panel,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openRule(context, rule),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _ruleName(S.of(context), rule),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                rule.body.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rule's name, or its first line where it has none.
String _ruleName(S s, AgentRule rule) {
  if (rule.name.trim().isNotEmpty) return rule.name.trim();
  final first = rule.body.trim().split('\n').first;
  return first.isEmpty ? s.untitledRule : first;
}

/// One rule written or changed: its name and its words.
class RuleScreen extends StatefulWidget {
  /// Null for a new one.
  final AgentRule? rule;

  const RuleScreen({super.key, this.rule});

  @override
  State<RuleScreen> createState() => _RuleScreenState();
}

class _RuleScreenState extends State<RuleScreen> {
  late final _name = TextEditingController(text: widget.rule?.name);
  late final _body = TextEditingController(text: widget.rule?.body);
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _body.addListener(_changed);
  }

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Agents.instance.saveRule(
        id: widget.rule?.id,
        name: _name.text.trim(),
        body: _body.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete() async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteRuleQuestion),
        content: Text(s.deleteRuleHint),
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
    await Agents.instance.removeRule(widget.rule!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: widget.rule == null ? s.newRule : s.editRule,
                showBack: true,
                actions: [
                  if (widget.rule != null)
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
                    _Section(s.ruleName),
                    _Field(controller: _name),
                    _Section(s.ruleBody),
                    _Field(controller: _body, hint: s.ruleBodyHint, lines: 16),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: _saving || _body.text.trim().isEmpty
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

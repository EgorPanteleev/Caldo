part of 'agents_screen.dart';

/// A new account asked for: [worker] and [agent] chosen first, if given.
Future<String?> openNewAccount(
  BuildContext context, {
  String? worker,
  String? agent,
}) => Navigator.of(context).push(
  MaterialPageRoute<String>(
    builder: (_) => NewAccountScreen(worker: worker, agent: agent),
  ),
);

/// The workers that sign in to accounts asked for here: reinstalled since
/// accounts came.
List<AgentWorker> _accountWorkers(Agents agents) => [
  for (final w in agents.workers)
    if (w.agents.any((a) => a.accounts)) w,
];

/// Prefer the account's chosen name, then its email, then the agent name.
String accountTitle(AgentAccount a) {
  if (a.name.trim().isNotEmpty) return a.name.trim();
  if (a.email case final email? when email.isNotEmpty) return email;
  return _agentLabel(a.agent);
}

String? _filled(String? s) => s == null || s.isEmpty ? null : s;

String _agentLabel(String agent) => switch (agent) {
  'claude' => 'Claude',
  'codex' => 'Codex',
  _ => agent,
};

String _accountState(S s, AccountState state) => switch (state) {
  AccountState.asked => s.accountStarting,
  AccountState.signingIn => s.accountSigningIn,
  AccountState.ready => s.accountReady,
  AccountState.signedOut => s.accountSignedOut,
  AccountState.failed => s.accountFailed,
};

class _AccountCard extends StatelessWidget {
  final AgentAccount account;
  final AgentWorker worker;

  const _AccountCard({required this.account, required this.worker});

  Future<void> _rename(BuildContext context) async {
    final s = S.of(context);
    final name = TextEditingController(text: account.name);
    final got = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.accountRename),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: InputDecoration(
            hintText: _filled(account.email) ?? _agentLabel(account.agent),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, name.text),
            child: Text(s.save),
          ),
        ],
      ),
    );
    name.dispose();
    if (got != null) await Agents.instance.renameAccount(account.id, got);
  }

  Future<void> _remove(BuildContext context) async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.accountRemoveQuestion(accountTitle(account))),
        content: Text(s.accountRemoveHint(worker.name)),
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
    if (ok == true) await Agents.instance.removeAccount(account.id);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final a = account;
    final usage = a.usage;
    final title = accountTitle(a);
    final agentLabel = _agentLabel(a.agent);
    final icon = switch (a.agent) {
      'claude' => 'assets/icon/claude.png',
      'codex' => 'assets/icon/codex.png',
      _ => null,
    };
    final line = [
      if (title != agentLabel) agentLabel,
      ?_filled(a.plan),
      if (a.name.trim().isNotEmpty && (a.email ?? '').isNotEmpty) a.email!,
      if (!a.ready) _accountState(s, a.state),
    ].join(' · ');
    final age = usage == null ? null : limitsAge(context, usage);
    return Material(
      color: p.panel,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Image.asset(
                    icon,
                    width: 28,
                    height: 28,
                    excludeFromSemantics: true,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (line.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 12.5),
                        ),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, color: p.muted, size: 20),
                  onSelected: (v) => switch (v) {
                    'rename' => _rename(context),
                    'again' => Agents.instance.signInAgain(a.id),
                    'remove' => _remove(context),
                    _ => null,
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(s.accountRename),
                    ),
                    if (a.state != AccountState.signingIn)
                      PopupMenuItem(
                        value: 'again',
                        child: Text(s.accountSignInAgain),
                      ),
                    if (!a.main)
                      PopupMenuItem(value: 'remove', child: Text(s.delete)),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: switch (a.state) {
                AccountState.ready =>
                  usage == null || usage.limits.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            s.accountNoLimits,
                            style: TextStyle(color: p.faint, fontSize: 12.5),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 6),
                            AccountLimits(usage: usage),
                            if (age != null)
                              Text(
                                age,
                                style: TextStyle(color: p.faint, fontSize: 12),
                              ),
                          ],
                        ),
                AccountState.asked ||
                AccountState.signingIn => _SignIn(account: a),
                AccountState.signedOut || AccountState.failed => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (a.note case final note? when note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          note,
                          style: TextStyle(
                            color: a.state == AccountState.failed
                                ? AppColors.danger
                                : p.muted,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => Agents.instance.signInAgain(a.id),
                      child: Text(s.accountSignIn),
                    ),
                  ],
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A sign-in under way on the worker: the page to sign in on, as soon as
/// the worker has it; then, for Claude, the code that page gives, to send
/// back; for Codex, the code to type on the page.
class _SignIn extends StatefulWidget {
  final AgentAccount account;

  const _SignIn({required this.account});

  @override
  State<_SignIn> createState() => _SignInState();
}

class _SignInState extends State<_SignIn> {
  final _code = TextEditingController();

  /// The code sent, until the worker says how it went.
  bool _sent = false;

  @override
  void didUpdateWidget(_SignIn old) {
    super.didUpdateWidget(old);
    // A new page: the code sent was for the last.
    if (old.account.loginUrl != widget.account.loginUrl) _sent = false;
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _open(String url) async {
    if (await openPage(url) || !mounted) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(S.of(context).accountLinkCopied)));
  }

  Future<void> _send() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() => _sent = true);
    try {
      await Agents.instance.loginCode(widget.account.id, code);
      _code.clear();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sent = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final a = widget.account;
    final url = a.loginUrl;
    Widget waiting(String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: p.muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: p.muted, fontSize: 13)),
          ),
        ],
      ),
    );
    if (url == null) return waiting(s.accountWaitingPage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          a.agent == 'claude' ? s.accountClaudeSteps : s.accountCodexSteps,
          style: TextStyle(color: p.muted, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Flexible(
              child: FilledButton.tonal(
                onPressed: () => _open(url),
                child: Text(
                  s.accountOpenPage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.copy_rounded, size: 18, color: p.muted),
              tooltip: s.accountCopyLink,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(s.accountLinkCopied)));
              },
            ),
          ],
        ),
        if (a.loginHint case final hint?) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: SelectableText(
                  hint,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.copy_rounded, size: 18, color: p.muted),
                tooltip: s.accountCopyLink,
                onPressed: () => Clipboard.setData(ClipboardData(text: hint)),
              ),
            ],
          ),
        ],
        if (a.agent != 'claude')
          waiting(s.accountWaitingCodex)
        else if (_sent)
          waiting(s.accountSigningIn)
        else ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _Field(controller: _code, hint: s.accountCode),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _send, child: Text(s.accountSend)),
            ],
          ),
        ],
      ],
    );
  }
}

/// An account asked for: the computer it is kept on, the agent, a name if
/// wanted. Its worker begins signing in at once; the list shows where.
class NewAccountScreen extends StatefulWidget {
  final String? worker;
  final String? agent;

  const NewAccountScreen({super.key, this.worker, this.agent});

  @override
  State<NewAccountScreen> createState() => _NewAccountScreenState();
}

class _NewAccountScreenState extends State<NewAccountScreen> {
  final _agents = Agents.instance;
  final _name = TextEditingController();
  late String? _worker = widget.worker;
  late String? _agent = widget.agent;
  bool _adding = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<AgentKind> _kindsOf(AgentWorker? w) => [
    for (final a in w?.agents ?? const <AgentKind>[])
      if (a.accounts) a,
  ];

  Future<void> _add() async {
    final worker = _worker, agent = _agent;
    if (worker == null || agent == null) return;
    setState(() => _adding = true);
    try {
      final account = await _agents.addAccount(
        worker: worker,
        agent: agent,
        name: _name.text,
      );
      if (!mounted) return;
      final navigator = Navigator.of(context);
      // From the list, back to it; from a chat's form, on to the list,
      // where the sign-in is shown.
      if (widget.worker == null) {
        navigator.pop(account.id);
      } else {
        await navigator.pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => WorkersScreen(accountId: account.id),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _adding = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final workers = _accountWorkers(_agents);
    final w =
        workers.where((w) => w.id == _worker).firstOrNull ??
        workers.where((w) => w.online).firstOrNull ??
        workers.firstOrNull;
    _worker = w?.id;
    final kinds = _kindsOf(w);
    if (!kinds.any((k) => k.id == _agent)) _agent = kinds.firstOrNull?.id;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(title: s.addAccount, showBack: true),
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
                    if (workers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Text(
                          s.accountsReinstall,
                          style: TextStyle(color: p.muted, fontSize: 14),
                        ),
                      ),
                    if (workers.length > 1) ...[
                      _Section(s.chatWorker),
                      _Picks(
                        children: [
                          for (final worker in workers)
                            _Pick(
                              label: worker.online
                                  ? worker.name
                                  : '${worker.name} · ${s.chatOffline}',
                              icon: Icons.computer_outlined,
                              selected: worker.id == _worker,
                              onTap: () => setState(() => _worker = worker.id),
                            ),
                        ],
                      ),
                    ],
                    if (kinds.isNotEmpty) ...[
                      _Section(s.chatAgent),
                      _Picks(
                        children: [
                          for (final k in kinds)
                            _Pick(
                              label: k.label,
                              selected: k.id == _agent,
                              onTap: () => setState(() => _agent = k.id),
                            ),
                        ],
                      ),
                      _Section(s.accountName),
                      _Field(controller: _name, hint: s.accountNameHint),
                      const SizedBox(height: 16),
                      Text(
                        s.accountAddHint(w?.name ?? ''),
                        style: TextStyle(color: p.faint, fontSize: 12.5),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 48,
                        child: FilledButton(
                          onPressed: _adding || _agent == null ? null : _add,
                          child: Text(s.accountSignIn),
                        ),
                      ),
                    ],
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

/// The accounts to choose a chat's among, for [worker]'s [kind]: those
/// signed in, a line each with its limits, and one to add another. Empty
/// for an agent its worker signs into no accounts for.
List<Widget> accountPicks(
  BuildContext context, {
  required AgentWorker worker,
  required AgentKind kind,
  required String? chosen,
  required ValueChanged<String?> onPick,
}) {
  if (!kind.accounts) return const [];
  final s = S.of(context);
  final agents = Agents.instance;
  final all = agents.accountsOf(worker.id, kind.id);
  final main = all.where((a) => a.main).firstOrNull;
  String label(AgentAccount a) {
    final limits = a.usage == null ? '' : limitsLine(s, a.usage!);
    return limits.isEmpty ? accountTitle(a) : '${accountTitle(a)} · $limits';
  }

  return [
    _Section(s.chatAccount),
    _Picks(
      children: [
        for (final a in all)
          if (a.ready)
            _Pick(
              label: label(a),
              icon: Icons.account_circle_outlined,
              // None chosen is the worker's own.
              selected: chosen == a.id || (chosen == null && a == main),
              onTap: () => onPick(a.main ? null : a.id),
            ),
        _Pick(
          label: s.addAccount,
          icon: Icons.add,
          selected: false,
          onTap: () =>
              openNewAccount(context, worker: worker.id, agent: kind.id),
        ),
      ],
    ),
  ];
}

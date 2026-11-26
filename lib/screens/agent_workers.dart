part of 'agents_screen.dart';

class WorkersScreen extends StatefulWidget {
  const WorkersScreen({super.key, this.accountId});

  /// A newly added account whose sign-in should be brought into view.
  final String? accountId;

  @override
  State<WorkersScreen> createState() => _WorkersScreenState();
}

class _WorkersScreenState extends State<WorkersScreen> {
  final _agents = Agents.instance;
  final _accountAnchors = <String, GlobalKey>{};
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _agents.addListener(_changed);
    _agents.watch();
    // An account limit can reset without a new reading.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _changed());
    if (widget.accountId case final id?) _revealAccount(id);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _agents.removeListener(_changed);
    _agents.unwatch();
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _addAccount() async {
    final id = await openNewAccount(context);
    if (mounted && id != null) setState(() => _revealAccount(id));
  }

  void _revealAccount(String id) {
    final anchor = _accountAnchors.putIfAbsent(id, GlobalKey.new);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (anchor.currentContext case final target?) {
        Scrollable.ensureVisible(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final canAdd = _accountWorkers(_agents).isNotEmpty;
    final accountsByWorker = <String, List<AgentAccount>>{};
    for (final account in _agents.accounts) {
      (accountsByWorker[account.workerId] ??= []).add(account);
    }

    return AppScaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: s.agentAccounts,
                showBack: true,
                actions: [
                  if (canAdd)
                    IconButton(
                      icon: Icon(Icons.add, color: p.muted),
                      tooltip: s.addAccount,
                      onPressed: _addAccount,
                    ),
                ],
              ),
            ),
            Expanded(
              child: _agents.workers.isEmpty
                  ? EmptyState(
                      icon: Icons.computer_outlined,
                      title: s.agentsNoWorker,
                      message: s.agentsNoWorkerHint,
                    )
                  : DeskGutter(
                      builder: (context, gutter) => SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          16 + gutter,
                          8,
                          16 + gutter,
                          8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final worker in _agents.workers)
                              Padding(
                                key: ValueKey(worker.id),
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _WorkerCard(worker: worker),
                                    for (final account
                                        in accountsByWorker[worker.id] ??
                                            const <AgentAccount>[])
                                      Padding(
                                        key:
                                            _accountAnchors[account.id] ??
                                            ValueKey(account.id),
                                        padding: const EdgeInsets.only(top: 6),
                                        child: _AccountCard(
                                          account: account,
                                          worker: worker,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            if (!canAdd && accountsByWorker.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Text(
                                  s.accountsReinstall,
                                  style: TextStyle(
                                    color: p.muted,
                                    fontSize: 13,
                                  ),
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

class _WorkerCard extends StatelessWidget {
  const _WorkerCard({required this.worker});

  final AgentWorker worker;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final reading = worker.resources;
    final percent = NumberFormat.percentPattern(s.code);
    String usage(int? value) =>
        value == null ? '—' : percent.format(value / 100);
    final gib = NumberFormat.decimalPatternDigits(
      locale: s.code,
      decimalDigits: 1,
    );
    const bytesPerGib = 1024 * 1024 * 1024;
    final used = reading?.ramUsedBytes;
    final total = reading?.ramTotalBytes;
    final ram = used == null || total == null
        ? '—'
        : '${gib.format(used / bytesPerGib)} / '
              '${gib.format(total / bytesPerGib)} GiB';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              worker.online ? worker.name : '${worker.name} · ${s.chatOffline}',
              style: TextStyle(
                color: p.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                _ResourceValue(label: 'CPU', value: usage(reading?.cpuPercent)),
                _ResourceValue(label: 'RAM', value: ram),
                _ResourceValue(label: 'GPU', value: usage(reading?.gpuPercent)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResourceValue extends StatelessWidget {
  const _ResourceValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: p.muted, fontSize: 12)),
        Text(value, style: TextStyle(color: p.text, fontSize: 14)),
      ],
    );
  }
}

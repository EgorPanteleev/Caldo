part of 'agents_screen.dart';

class _WorkersScreen extends StatefulWidget {
  const _WorkersScreen();

  @override
  State<_WorkersScreen> createState() => _WorkersScreenState();
}

class _WorkersScreenState extends State<_WorkersScreen> {
  final _agents = Agents.instance;

  @override
  void initState() {
    super.initState();
    _agents.watch();
  }

  @override
  void dispose() {
    _agents.unwatch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(title: s.agentWorkers, showBack: true),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: _agents,
                builder: (context, _) => _agents.workers.isEmpty
                    ? EmptyState(
                        icon: Icons.computer_outlined,
                        title: s.agentsNoWorker,
                        message: s.agentsNoWorkerHint,
                      )
                    : DeskGutter(
                        builder: (context, gutter) => ListView.separated(
                          padding: EdgeInsets.fromLTRB(
                            16 + gutter,
                            8,
                            16 + gutter,
                            24,
                          ),
                          itemCount: _agents.workers.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) =>
                              _WorkerCard(worker: _agents.workers[i]),
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

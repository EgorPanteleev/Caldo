import 'dart:io';

/// Agent tools inherit the chat's cgroup, even if they daemonize. The
/// systemd installer gives those groups a shared memory budget apart from
/// the watcher. A manually launched worker needs no user manager.
List<String> agentScope(List<String> argv, {String? errors}) {
  if (Platform.environment['CALDO_AGENT_SLICE'] case final slice?) {
    return ['sh', '-c', _run, 'sh', slice, errors ?? '', ...argv];
  }
  return argv;
}

// Keep the command in the foreground for tmux. The wrapper is outside
// the scope so it can wait for cleanup and return the command's status.
// Each launch gets its own unit, including restarts of the same chat.
const _run = r'''
slice=$1; errors=$2; shift 2
if [ -n "$errors" ]; then exec 2>>"$errors"; fi
unit=caldo-agent-$$.scope
trap 'systemctl --user stop "$unit" >/dev/null 2>&1 || :' EXIT
trap 'exit 129' HUP
trap ':' INT QUIT
trap 'exit 143' TERM
systemd-run --user --scope --quiet --collect --expand-environment=no \
  --description='Caldo agent and its tools' \
  --slice="$slice" --unit="$unit" --property=OOMPolicy=stop -- "$@"
''';

/// The freezer covers the agent and tools in its scope, including jobs
/// started in a separate process group by a terminal shell.
class AgentScope {
  final String unit;

  const AgentScope._(this.unit);

  static bool get canFreeze =>
      Platform.isLinux &&
      Platform.environment.containsKey('CALDO_AGENT_SLICE') &&
      File('/sys/fs/cgroup/cgroup.controllers').existsSync();

  /// A kept chat's waiting shell is inside the scope.
  static AgentScope? ofProcess(int pid) {
    try {
      final group = File('/proc/$pid/cgroup').readAsStringSync().trim();
      final unit = group.split('/').last;
      if (RegExp(r'^caldo-agent-[0-9]+\.scope$').hasMatch(unit)) {
        return AgentScope._(unit);
      }
    } on FileSystemException {
      // The process can exit while it is being looked up.
    }
    return null;
  }

  /// A terminal's pane runs the wrapper outside the scope it created.
  static AgentScope? ofTerminal(int pid, String chat) {
    try {
      final process = File('/proc/$pid/cmdline').readAsStringSync();
      final environment = File('/proc/$pid/environ').readAsStringSync();
      if (process.contains(r'unit=caldo-agent-$$.scope') &&
          environment.split('\u0000').contains('CALDO_CHAT=$chat')) {
        return AgentScope._('caldo-agent-$pid.scope');
      }
    } on FileSystemException {
      // The pane can close meanwhile.
    }
    return null;
  }

  Future<bool> isFrozen() async {
    final result = await Process.run('systemctl', [
      '--user',
      'show',
      '-p',
      'FreezerState',
      '--value',
      unit,
    ]);
    return result.exitCode == 0 &&
        const {'freezing', 'frozen'}.contains('${result.stdout}'.trim());
  }

  Future<void> freeze(bool paused) => _control(paused ? 'freeze' : 'thaw');

  Future<void> stop() => _control('stop');

  Future<void> _control(String verb) async {
    final result = await Process.run('systemctl', ['--user', verb, unit]);
    if (result.exitCode != 0) throw StateError('${result.stderr}'.trim());
  }
}

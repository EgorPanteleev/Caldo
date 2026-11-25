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

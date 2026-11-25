import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../db/database.dart';
import '../l10n/strings.dart';
import '../mcp/agents.dart' show sizeWord;
import '../mcp/subscriptions.dart' show Subscription;
import '../mcp/usage.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../services/account.dart';
import '../services/agents.dart';
import '../services/push.dart';
import '../services/attachments.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../utils/platform.dart';
import '../widgets/chat_usage.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/colour_selector.dart';
import '../widgets/date_time_pickers.dart';
import '../widgets/desk.dart';
import '../widgets/glass.dart';
import '../widgets/quick_add_bar.dart' show BarRoom, KeyboardGap;
import '../widgets/screen_header.dart';
import '../widgets/selection.dart' show Selection;
import '../widgets/talk_view.dart';

part 'agent_accounts.dart';
part 'agent_projects.dart';
part 'agent_rules.dart';
part 'chat_settings.dart';
part 'chat_subscriptions.dart';

/// Chats with agents — Claude, Codex, a model of the user's own, a shell —
/// each run in a terminal on one of the user's computers (a worker,
/// `caldo-mcp watch`) and watched and typed into here.
///
/// Asked for as "a separate tab, like chats": a list of chats, a form to
/// start one choosing the computer, the agent, its model, effort, folder,
/// plugins and skills, and the terminal itself to write in. A task handed
/// to a Claude model is done as one of these chats, and listed here too.
class AgentsScreen extends StatefulWidget {
  /// Whether this is the screen on show: the chats are read, and heard
  /// changing, only while it is.
  final ValueListenable<bool>? shown;

  const AgentsScreen({super.key, this.shown});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  final _agents = Agents.instance;
  bool _watching = false;

  /// The chats picked out to be pinned, stopped or deleted together, in the
  /// order they were picked. A long press picks the first; while any are,
  /// a tap picks or puts back, and the head gives its place to what can be
  /// done with them.
  final _picked = <String>{};

  bool _picking() => _picked.isNotEmpty;

  /// The project whose chats alone are listed, its subprojects' with
  /// them; null for every chat.
  String? _only;

  /// The chats listed: all, or those of the project chosen.
  List<Chat> get _shown {
    final only = _agents.project(_only);
    if (only == null) return _agents.chats;
    final family = _agents.familyOf(only.id);
    return [
      for (final c in _agents.chats)
        if (family.contains(c.projectId)) c,
    ];
  }

  /// One project's chats listed, or all again; or the projects opened to
  /// change, from the same sheet, or at once while there are none.
  Future<void> _chooseProject() async {
    final s = S.of(context);
    if (_agents.projects.isEmpty) return openProjects(context);
    const all = '', edit = '/edit';
    final got = await choose<String>(
      context,
      title: s.agentProjects,
      selected: _agents.project(_only)?.id ?? all,
      options: [
        Option(all, s.allProjects),
        for (final p in _agents.projects)
          Option(p.id, '${'   ' * _agents.depthOf(p)}${p.name.trim()}'),
        Option(edit, s.editProjects, icon: Icons.edit_outlined),
      ],
    );
    if (got == null || !mounted) return;
    if (got == edit) return openProjects(context);
    setState(() {
      _only = got == all ? null : got;
      _picked.clear();
    });
  }

  @override
  void initState() {
    super.initState();
    widget.shown?.addListener(_follow);
    Account.instance.email.addListener(_signedInOrOut);
    _agents.addListener(_changed);
    Selection.elsewhere.add(_picking);
    _follow();
  }

  @override
  void dispose() {
    widget.shown?.removeListener(_follow);
    Account.instance.email.removeListener(_signedInOrOut);
    _agents.removeListener(_changed);
    Selection.elsewhere.remove(_picking);
    if (_watching) _agents.unwatch();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // A chat deleted elsewhere, or by its worker, is no longer picked.
    final there = {for (final c in _agents.chats) c.id};
    setState(() => _picked.retainAll(there));
  }

  void _follow() {
    final shown = widget.shown?.value ?? true;
    if (shown == _watching) return;
    _watching = shown;
    // Off the tab, what was picked is put down, as tasks' are.
    if (!shown && _picked.isNotEmpty) setState(_picked.clear);
    shown ? _agents.watch() : _agents.unwatch();
  }

  void _pick(Chat chat) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_picked.remove(chat.id)) _picked.add(chat.id);
    });
  }

  void _drop() => setState(_picked.clear);

  List<Chat> get _pickedChats => [
    for (final c in _agents.chats)
      if (_picked.contains(c.id)) c,
  ];

  /// Something the server refused, said rather than lost: a server
  /// without the pins' column, say, or no connection.
  void _failed(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('$e')));
  }

  /// Pinned all, unless all are already, which lets them go.
  Future<void> _pinPicked() async {
    final chats = _pickedChats;
    final pinned = !chats.every((c) => c.pinned);
    _drop();
    try {
      await _agents.pin([for (final c in chats) c.id], pinned: pinned);
    } catch (e) {
      _failed(e);
    }
  }

  /// Muted all, unless all are already, which lets them be heard again.
  Future<void> _mutePicked() async {
    final chats = _pickedChats;
    final muted = !chats.every((c) => c.muted);
    _drop();
    try {
      await _agents.mute([for (final c in chats) c.id], muted: muted);
    } catch (e) {
      _failed(e);
    }
  }

  Future<void> _stopPicked() async {
    final ids = [..._picked];
    _drop();
    try {
      await _agents.stopAll(ids);
    } catch (e) {
      _failed(e);
    }
  }

  Future<void> _deletePicked() async {
    final s = S.of(context);
    final ids = [..._picked];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          ids.length == 1
              ? s.deleteChatQuestion
              : s.deleteChatsQuestion(ids.length),
        ),
        content: Text(s.cannotBeUndone),
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
    if (ok != true || !mounted) return;
    _drop();
    try {
      await _agents.removeAll(ids);
    } catch (e) {
      _failed(e);
    }
  }

  /// Signed in or out while on show: watched again with the new client.
  void _signedInOrOut() {
    if (!_watching) return setState(() {});
    _agents
      ..unwatch()
      ..watch();
  }

  void _new() {
    if (!_agents.signedIn || _agents.workers.isEmpty) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const NewChatScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final chats = _shown;
    final only = _agents.project(_only);
    final Widget body;
    if (!_agents.signedIn) {
      body = _empty(
        Icons.cloud_off_outlined,
        s.agentsSignIn,
        s.agentsSignInHint,
      );
    } else if (!_agents.loaded) {
      body = const SizedBox.shrink();
    } else if (_agents.workers.isEmpty) {
      body = _empty(
        Icons.computer_outlined,
        s.agentsNoWorker,
        s.agentsNoWorkerHint,
      );
    } else if (chats.isEmpty) {
      body = only != null
          ? _empty(Icons.workspaces_outlined, s.noChats, s.chatOwnFolderHint)
          : _empty(Icons.terminal_rounded, s.noChats, s.noChatsHint);
    } else {
      body = DeskGutter(
        builder: (context, gutter) => ListView.separated(
          padding: EdgeInsets.fromLTRB(
            16 + gutter,
            HeadRoom.of(context),
            16 + gutter,
            BarRoom.of(context) + 16,
          ),
          itemCount: chats.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final chat = chats[i];
            return _ChatRow(
              chat: chat,
              picking: _picked.isNotEmpty,
              picked: _picked.contains(chat.id),
              onPick: () => _pick(chat),
            );
          },
        ),
      );
    }
    final picked = _pickedChats;
    final head = picked.isNotEmpty
        ? ScreenHeader(
            title: s.selectedCount(picked.length),
            // Its back arrow is Back's, which puts the picks down.
            showBack: true,
            actions: [
              if (picked.length < chats.length)
                IconButton(
                  icon: Icon(Icons.select_all_rounded, color: p.muted),
                  tooltip: s.chatSelectAll,
                  onPressed: () => setState(
                    () => _picked.addAll([for (final c in chats) c.id]),
                  ),
                ),
              if (picked.every((c) => c.pinned))
                IconButton(
                  icon: Icon(Icons.push_pin, color: p.muted),
                  tooltip: s.chatUnpin,
                  onPressed: _pinPicked,
                )
              else
                IconButton(
                  icon: Icon(Icons.push_pin_outlined, color: p.muted),
                  tooltip: s.chatPin,
                  onPressed: _pinPicked,
                ),
              if (picked.every((c) => c.muted))
                IconButton(
                  icon: Icon(
                    Icons.notifications_active_outlined,
                    color: p.muted,
                  ),
                  tooltip: s.chatUnmute,
                  onPressed: _mutePicked,
                )
              else
                IconButton(
                  icon: Icon(Icons.notifications_off_outlined, color: p.muted),
                  tooltip: s.chatMute,
                  onPressed: _mutePicked,
                ),
              if (picked.any((c) => c.live))
                IconButton(
                  icon: Icon(Icons.stop_circle_outlined, color: p.muted),
                  tooltip: s.chatStop,
                  onPressed: _stopPicked,
                ),
              IconButton(
                icon: Icon(Icons.delete_outline_rounded, color: p.muted),
                tooltip: s.delete,
                onPressed: _deletePicked,
              ),
              const SizedBox(width: 6),
            ],
          )
        : ScreenHeader(
            title: only != null ? _agents.pathOf(only) : s.agents,
            actions: [
              if (_agents.signedIn)
                IconButton(
                  icon: Icon(
                    Icons.workspaces_outlined,
                    // In the project's own colour while only its chats
                    // are listed.
                    color: only != null ? _projectColour(only) : p.muted,
                  ),
                  tooltip: s.agentProjects,
                  onPressed: _chooseProject,
                ),
              if (_agents.signedIn && _agents.workers.isNotEmpty)
                IconButton(
                  icon: Icon(Icons.account_circle_outlined, color: p.muted),
                  tooltip: s.agentAccounts,
                  onPressed: () => openAccounts(context),
                ),
              if (_agents.signedIn)
                IconButton(
                  icon: Icon(Icons.rule_rounded, color: p.muted),
                  tooltip: s.agentRules,
                  onPressed: () => openRules(context),
                ),
              if (_agents.signedIn && _agents.workers.isNotEmpty)
                IconButton(
                  icon: Icon(Icons.add, color: p.muted),
                  tooltip: s.newChat,
                  onPressed: _new,
                ),
              const SizedBox(width: 6),
            ],
          );
    return PopScope(
      canPop: picked.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        // Put down a moment later: the shell hears this Back too, and
        // must still see something picked, or it goes to the start screen.
        if (!didPop) scheduleMicrotask(() => mounted ? _drop() : null);
      },
      child: Scaffold(
        body: GlassTop(
          head: DeskColumn(child: head),
          body: Builder(builder: (context) => body),
        ),
      ),
    );
  }

  Widget _empty(IconData icon, String title, String message) => Builder(
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        top: HeadRoom.of(context),
        bottom: BarRoom.of(context),
      ),
      child: EmptyState(icon: icon, title: title, message: message),
    ),
  );
}

/// The colour a chat's state is shown in, as quiet as the rest of the
/// app's signals, the one asking for the user the loudest.
Color _stateColour(AppPalette p, ChatState state) => switch (state) {
  ChatState.asked => p.muted,
  ChatState.waiting => p.faint,
  ChatState.running => AppColors.holiday,
  ChatState.asking => AppColors.overdue,
  ChatState.idle => p.muted,
  ChatState.finished => p.text,
  ChatState.yourTurn => AppColors.overdue,
  ChatState.limited => p.text,
  ChatState.ended => p.faint,
  ChatState.failed => AppColors.danger,
};

/// A chat's state at a glance, [size] across: a dot; a ring while it is
/// ready and has done nothing yet, a tick once a turn has finished, and
/// an hourglass once the usage limit stopped one — told by shape, not a
/// shade of grey.
class _StateMark extends StatelessWidget {
  final ChatState state;
  final double size;

  const _StateMark({required this.state, required this.size});

  @override
  Widget build(BuildContext context) {
    final colour = _stateColour(AppTheme.of(context), state);
    return SizedBox.square(
      dimension: size,
      child: state == ChatState.finished || state == ChatState.limited
          // Drawn larger than the dot, as an icon's strokes are thin; it
          // overflows its square so the row doesn't move.
          ? OverflowBox(
              maxWidth: size * 1.8,
              maxHeight: size * 1.8,
              child: Icon(
                state == ChatState.limited
                    ? Icons.hourglass_bottom_rounded
                    : Icons.check_rounded,
                size: size * 1.8,
                color: colour,
              ),
            )
          : DecoratedBox(
              decoration: BoxDecoration(
                color: _ring(state) ? null : colour,
                border: _ring(state)
                    ? Border.all(color: colour, width: 1.4)
                    : null,
                shape: BoxShape.circle,
              ),
            ),
    );
  }
}

/// A chat that has done nothing yet, ready or waiting for its task: a
/// ring, not a dot.
bool _ring(ChatState state) =>
    state == ChatState.idle || state == ChatState.waiting;

/// [chat]'s state in words; one waiting with no task waits for the user.
String _stateName(S s, Chat chat) => switch (chat.state) {
  ChatState.asked => s.chatAsked,
  ChatState.waiting => chat.taskUuid == null ? s.chatHeld : s.chatWaiting,
  ChatState.running => s.chatRunning,
  ChatState.asking => s.chatAsking,
  ChatState.idle => s.chatIdle,
  ChatState.finished => s.chatFinished,
  ChatState.yourTurn => s.chatAsking,
  ChatState.limited => s.chatLimited,
  ChatState.ended => s.chatEnded,
  ChatState.failed => s.chatFailed,
};

/// "Claude · opus · desk": what runs it, and where.
String _lineOf(Chat chat) {
  final agents = Agents.instance;
  final worker = agents.worker(chat.workerId);
  final kind = worker?.agents.where((a) => a.id == chat.agent).firstOrNull;
  return [
    kind?.label ?? chat.agent,
    ?chat.model,
    ?chat.effort,
    ?worker?.name,
  ].join(' · ');
}

class _ChatRow extends StatelessWidget {
  final Chat chat;

  /// Whether any chat is picked out, so a tap picks rather than opens.
  final bool picking;
  final bool picked;
  final VoidCallback onPick;

  const _ChatRow({
    required this.chat,
    required this.picking,
    required this.picked,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final now = DateTime.now();
    final at = chat.updatedAt;
    final when = DateUtils.isSameDay(at, now)
        ? Dates.time(at)
        : Dates.shortDay(at);
    // A chat of a project wears its colour, so projects' chats are told
    // apart in the list at a glance.
    final colour = _chatColour(chat);
    final project = _chatProjectName(chat);
    final ground = picked ? p.panelHi : p.panel;
    // Stopped at the limit: which, and when it resets, in the app's words
    // rather than the worker's.
    final note = chat.state == ChatState.limited
        ? limitBrief(context, chat.usage)
        : chat.note;
    return Material(
      color: colour == null
          ? ground
          : Color.alphaBlend(colour.withValues(alpha: 0.16), ground),
      // Picked, a rim in the text's colour: no accent, as the task cards'
      // picks have none either.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: picked
            ? BorderSide(color: p.text.withValues(alpha: 0.7), width: 1.5)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: picking ? onPick : () => openChat(context, chat.id),
        onLongPress: onPick,
        onSecondaryTap: onPick,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              if (picking)
                Icon(
                  picked
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: picked ? p.text : p.faint,
                )
              else
                _StateMark(state: chat.state, size: 9),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (chat.taskUuid != null) ...[
                          Icon(
                            Icons.check_box_outlined,
                            size: 14,
                            color: p.muted,
                            semanticLabel: s.chatFromTask,
                          ),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                          child: Text(
                            chat.name.isEmpty ? _lineOf(chat) : chat.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (chat.muted) ...[
                          Icon(
                            Icons.notifications_off_outlined,
                            size: 13,
                            color: p.faint,
                            semanticLabel: s.chatMuted,
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (chat.pinned) ...[
                          Icon(
                            Icons.push_pin,
                            size: 13,
                            color: p.faint,
                            semanticLabel: s.chatPinned,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          when,
                          style: TextStyle(color: p.faint, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text.rich(
                      TextSpan(
                        children: [
                          if (project != null)
                            TextSpan(
                              text: '$project · ',
                              style: TextStyle(
                                color: Color.lerp(colour, p.text, 0.35),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          TextSpan(
                            text: '${_stateName(s, chat)} · ${_lineOf(chat)}',
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 12.5),
                    ),
                    if (chat.usage case final usage? when !usage.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: ChatUsageBrief(usage: usage),
                      ),
                    if (note case final note? when note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          note,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: chat.state == ChatState.failed
                                ? AppColors.danger
                                : p.faint,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> openChat(BuildContext context, String chat) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(chat: chat)));

/// How big the terminal's text is, kept per device: the phone and the desk
/// want different sizes.
class _TermFont {
  static const _key = 'terminal_font';
  static double get standard => onDesktop ? 13 : 11;

  static Future<double> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_key) ?? standard;
    } catch (_) {
      return standard;
    }
  }

  static Future<void> write(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, size);
  }

  /// Room either side of the text.
  static const side = 10.0;

  /// JetBrains Mono, bundled: Android's own monospace is wide-set and thin.
  /// What it hasn't got comes from Term Symbols (Claude's ⏵ and ⎿ are in
  /// no font Android has), then the system's.
  ///
  /// The same one while the size is: xterm tells styles apart by identity,
  /// and a new one throws away every letter it has laid out.
  static TerminalStyle style(double size) => _style?.fontSize == size
      ? _style!
      : _style = TerminalStyle(
          fontSize: size,
          fontFamily: 'JetBrains Mono',
          fontFamilyFallback: _fallback,
        );

  static TerminalStyle? _style;

  static final _fallback = [
    'Term Symbols',
    ...const TerminalStyle().fontFamilyFallback,
  ];

  /// About how many columns and rows a terminal of [size] gets on [screen],
  /// for a chat started before its terminal has been laid out.
  static (int, int) fit(Size screen, double size) => (
    ((screen.width - 2 * side) / (size * 0.6)).floor(),
    ((screen.height - 220) / (size * 1.2)).floor(),
  );
}

/// The form that sends [tasks] to agents, a chat each; true once they are
/// sent. What a card's swipe, its menu, the form and the picked-out cards'
/// bar all open.
Future<bool> sendToAgents(BuildContext context, List<Task> tasks) async {
  final sent = await Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute(builder: (_) => NewChatScreen(tasks: tasks)));
  return sent ?? false;
}

/// The choices for a new chat, and the last ones made, which the next
/// starts from. Given [tasks], it starts one chat for each of them instead,
/// all on the same computer with the same agent, model and effort, each
/// told its own task as its first message and kept as that task's chat.
class NewChatScreen extends StatefulWidget {
  /// Tasks picked out on Schedule or the calendar to be sent on; empty for
  /// a chat of one's own.
  final List<Task> tasks;

  const NewChatScreen({super.key, this.tasks = const []});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  static const _lastKey = 'agents_last';

  final _agents = Agents.instance;
  final _title = TextEditingController();
  final _prompt = TextEditingController();

  /// The project it is begun in, by id; null for none. Every chat works in
  /// a folder of its own on its worker, with its project's folders in it.
  String? _project;

  String? _worker;
  String? _agent;
  String? _model;
  String? _effort;
  String? _permission;
  Set<String>? _plugins;
  final Set<String> _skills = {};

  /// The account it runs under; null for its worker's own.
  String? _account;

  /// Chosen rules, by id: kept across agents, since a rule is the user's,
  /// not the agent's.
  final Set<String> _rules = {};
  bool _starting = false;

  /// The last form's choices, until there is a worker to apply them to:
  /// opened from a task, the workers may not have been read yet.
  Map? _last;

  bool get _forTasks => widget.tasks.isNotEmpty;

  /// The tasks whose chats have started, by id: a second Start after one
  /// failed goes on with the rest rather than starting these again.
  final Set<int> _sent = {};

  /// Whether the tasks not due yet wait for their day or time, each its
  /// chat made now and started by its worker then; or all start now.
  bool _whenDue = false;

  /// Whether a new chat (not a task's) is only made, left for the user
  /// to start from its screen.
  bool _picksByHand = false;

  /// Whether the chat is left for the user, and its worker would.
  bool get _byHand => _picksByHand && _canHold;

  bool get _canHold => !_forTasks && (_kind?.held ?? false);

  /// Whether "When due" means anything for these tasks, and the worker
  /// chosen can keep a chat waiting.
  bool get _canWait =>
      _forTasks &&
      (_kind?.tasks ?? false) &&
      widget.tasks.any((t) => !t.isDueBy(DateTime.now()));

  @override
  void initState() {
    super.initState();
    _agents.addListener(_changed);
    _agents.watch();
    _pickWorker(null);
    _restore();
  }

  @override
  void dispose() {
    _agents.removeListener(_changed);
    _agents.unwatch();
    _title.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (_worker == null || _agents.worker(_worker) == null) {
        _pickWorker(null);
      }
      _applyLast();
    });
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _last = jsonDecode(prefs.getString(_lastKey) ?? '{}') as Map;
    } catch (_) {
      return;
    }
    if (mounted) setState(_applyLast);
  }

  void _applyLast() {
    final last = _last;
    if (last == null || _agents.workers.isEmpty) return;
    _last = null;
    if (_agents.worker(last['worker'] as String?) != null) {
      _pickWorker(last['worker'] as String);
    }
    final kind = _kinds.where((a) => a.id == last['agent']).firstOrNull;
    if (kind != null) _pickAgent(kind);
    if (_kind?.id == last['agent']) {
      _model = last['model'] as String?;
      _effort = last['effort'] as String?;
      _permission = last['permission'] as String?;
    }
    if (_agents.project(last['project'] as String?) != null) {
      _project = last['project'] as String;
    }
    if (_ready(last['account'] as String?)) {
      _account = last['account'] as String;
    }
    _rules.addAll([for (final id in last['rules'] as List? ?? const []) '$id']);
  }

  Future<void> _remember() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _lastKey,
        jsonEncode({
          'worker': _worker,
          'agent': _agent,
          'model': _model,
          'effort': _effort,
          'permission': _permission,
          'project': _project,
          'account': _account,
          'rules': _rules.toList(),
        }),
      );
    } catch (_) {}
  }

  AgentWorker? get _w => _agents.worker(_worker);

  /// What the worker runs; for tasks, only what takes a first message —
  /// and not the shell, which would run a task's words as commands.
  List<AgentKind> get _kinds => [
    for (final a in _w?.agents ?? const <AgentKind>[])
      if (!_forTasks || (a.prompt != 'none' && a.id != 'shell')) a,
  ];
  AgentKind? get _kind => _kinds.where((a) => a.id == _agent).firstOrNull;

  /// The worker [id], or the first one there, and its first agent.
  void _pickWorker(String? id) {
    final workers = _agents.workers;
    final online = workers.where((w) => w.online);
    final w = _agents.worker(id) ?? online.firstOrNull ?? workers.firstOrNull;
    _worker = w?.id;
    if (!_ready(_account)) _account = null;
    if (w == null) return;
    final keep = _kinds.where((a) => a.id == _agent).firstOrNull;
    final first = keep ?? _kinds.firstOrNull;
    if (first != null) _pickAgent(first);
  }

  /// Whether [account] is one to run the chosen agent under on the chosen
  /// worker: signed in, and of both.
  bool _ready(String? account) {
    final a = _agents.account(account);
    return a != null && a.ready && a.workerId == _worker && a.agent == _agent;
  }

  void _pickAgent(AgentKind kind) {
    _agent = kind.id;
    if (!_ready(_account)) _account = null;
    if (!kind.models.contains(_model)) _model = null;
    if (!kind.efforts.contains(_effort)) _effort = null;
    _permission = kind.permissions.contains('auto') ? 'auto' : null;
    _plugins = kind.plugins.isEmpty ? null : {...kind.pluginsOn};
    _skills.retainAll(kind.skills);
  }

  /// A folder under the worker's home written from `~`.
  static String _short(AgentWorker w, String dir) {
    final home = w.home;
    if (home == null || home.isEmpty) return dir;
    if (dir == home) return '~';
    return dir.startsWith('$home/') ? '~${dir.substring(home.length)}' : dir;
  }

  Future<void> _otherModel() async {
    final got = await _askModel(context, _model);
    if (got == null || !mounted) return;
    setState(() => _model = got.isEmpty ? null : got);
  }

  Future<void> _start() async {
    final kind = _kind;
    final worker = _worker;
    if (kind == null || worker == null || _starting) return;
    setState(() => _starting = true);
    final font = await _TermFont.read();
    if (!mounted) return;
    final (cols, rows) = _TermFont.fit(MediaQuery.sizeOf(context), font);
    if (_forTasks) return _startEach(kind, worker, cols, rows);
    final plugins = _plugins;
    final rules = _picked;
    try {
      final chat = await _agents.start(
        worker: worker,
        agent: kind.id,
        title: _title.text.trim(),
        model: _model,
        effort: _effort,
        project: _agents.project(_project),
        ownFolder: true,
        permission: _permission,
        // Sent only if changed from what Claude has on, so a plugin turned
        // on there later is not turned off here by a choice never made.
        plugins: plugins == null || setEquals(plugins, {...kind.pluginsOn})
            ? null
            : plugins.toList(),
        skills: _skills.toList(),
        rules: rules,
        prompt: kind.prompt == 'none' ? '' : firstMessage(_prompt.text, rules),
        account: _ready(_account) ? _account : null,
        cols: cols,
        rows: rows,
        inChat: kind.talks,
        waiting: _byHand,
      );
      unawaited(_remember());
      if (!mounted) return;
      // One left for later has nothing to show yet: back to the list,
      // where it waits.
      if (_byHand) return Navigator.of(context).pop();
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => ChatScreen(chat: chat.id)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _starting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// A chat for each task, one after another, each with the form's
  /// choices: told what is written here (or the rules' openings), then its
  /// task. One task opens its chat; more go back to where they were sent
  /// from, the chats under Agents.
  Future<void> _startEach(
    AgentKind kind,
    String worker,
    int cols,
    int rows,
  ) async {
    final s = S.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final plugins = _plugins;
    final rules = _picked;
    final said = firstMessage(_prompt.text, rules);
    final provider = context.read<TaskProvider>();
    final mark = agentMark(kind, _model);
    final whenDue = _whenDue && _canWait;
    final now = DateTime.now();
    // Each task as it is now, not as it was picked out; and those left to
    // wait for their day.
    final marked = <Task, String>{};
    final later = <Task>{};
    Chat? last;
    try {
      for (final task in widget.tasks) {
        if (_sent.contains(task.id)) continue;
        final uuid = await AppDatabase.instance.taskUuid(task.id!);
        final waits = whenDue && !task.isDueBy(now);
        last = await _agents.start(
          worker: worker,
          agent: kind.id,
          title: task.title.trim(),
          model: _model,
          effort: _effort,
          project: _agents.project(_project),
          ownFolder: true,
          permission: _permission,
          plugins: plugins == null || setEquals(plugins, {...kind.pluginsOn})
              ? null
              : plugins.toList(),
          skills: _skills.toList(),
          rules: rules,
          prompt: taskMessage(task, said),
          task: uuid,
          account: _ready(_account) ? _account : null,
          cols: cols,
          rows: rows,
          inChat: kind.talks,
          waiting: waits,
          // Told the task as it is once due, after these words.
          preface: waits ? said : null,
        );
        _sent.add(task.id!);
        final read = provider.taskById(task.id!) ?? task;
        marked[read] = mark;
        if (waits) later.add(read);
      }
    } catch (e) {
      unawaited(provider.sentToAgents(marked, later: later));
      // Those started stay started; Start again goes on with the rest.
      if (!mounted) return;
      setState(() => _starting = false);
      messenger.showSnackBar(
        SnackBar(content: Text('${s.chatsStarted(_sent.length)} · $e')),
      );
      return;
    }
    unawaited(provider.sentToAgents(marked, later: later));
    unawaited(_remember());
    if (!mounted) return;
    // One left waiting has nothing to show yet: back to its card, which
    // says it waits.
    if (widget.tasks.length == 1 && last != null && later.isEmpty) {
      final id = last.id;
      await navigator.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => ChatScreen(chat: id)),
        result: true,
      );
      return;
    }
    navigator.pop(true);
    messenger.showSnackBar(
      SnackBar(content: Text(s.chatsStarted(_sent.length))),
    );
  }

  bool _chosen(AgentRule rule) => _rules.contains(rule.id);

  /// The chosen rules, if the agent takes rules at all.
  List<AgentRule> get _picked =>
      _kind?.rules ?? false ? [..._agents.rules.where(_chosen)] : const [];

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final w = _w;
    final kind = _kind;
    final otherModel =
        _model != null && !(kind?.models.contains(_model) ?? false);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            DeskColumn(
              child: ScreenHeader(
                title: _forTasks ? s.sendToAgents : s.newChat,
                showBack: true,
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
                    if (_forTasks) ...[
                      _Section(s.tasks),
                      _TaskLines(tasks: widget.tasks),
                    ],
                    if (_canWait) ...[
                      _Section(s.chatStarts),
                      _Picks(
                        children: [
                          _Pick(
                            label: s.chatStartsNow,
                            icon: Icons.play_arrow_rounded,
                            selected: !_whenDue,
                            onTap: () => setState(() => _whenDue = false),
                          ),
                          _Pick(
                            label: s.chatStartsWhenDue,
                            icon: Icons.schedule_rounded,
                            selected: _whenDue,
                            onTap: () => setState(() => _whenDue = true),
                          ),
                        ],
                      ),
                      if (_whenDue) ...[
                        const SizedBox(height: 8),
                        Text(
                          s.chatStartsWhenDueHint,
                          style: TextStyle(color: p.muted, fontSize: 13),
                        ),
                      ],
                    ],
                    if (_canHold) ...[
                      _Section(s.chatStarts),
                      _Picks(
                        children: [
                          _Pick(
                            label: s.chatStartsNow,
                            icon: Icons.play_arrow_rounded,
                            selected: !_byHand,
                            onTap: () => setState(() => _picksByHand = false),
                          ),
                          _Pick(
                            label: s.chatStartsByHand,
                            icon: Icons.pause_rounded,
                            selected: _byHand,
                            onTap: () => setState(() => _picksByHand = true),
                          ),
                        ],
                      ),
                      if (_byHand) ...[
                        const SizedBox(height: 8),
                        Text(
                          s.chatStartsByHandHint,
                          style: TextStyle(color: p.muted, fontSize: 13),
                        ),
                      ],
                    ],
                    if (_agents.loaded && _agents.workers.isEmpty) ...[
                      _Section(s.agentsNoWorker),
                      Text(
                        s.agentsNoWorkerHint,
                        style: TextStyle(color: p.muted, fontSize: 14),
                      ),
                    ],
                    if (_agents.workers.isNotEmpty) _Section(s.chatWorker),
                    _Picks(
                      children: [
                        for (final worker in _agents.workers)
                          _Pick(
                            label: worker.online
                                ? worker.name
                                : '${worker.name} · ${s.chatOffline}',
                            icon: Icons.computer_outlined,
                            selected: worker.id == _worker,
                            onTap: () => setState(() => _pickWorker(worker.id)),
                          ),
                      ],
                    ),
                    if (w != null) ...[
                      _Section(s.chatAgent),
                      _Picks(
                        children: [
                          for (final a in _kinds)
                            _Pick(
                              label: a.label,
                              selected: a.id == _agent,
                              onTap: () => setState(() => _pickAgent(a)),
                            ),
                        ],
                      ),
                    ],
                    if (w != null && kind != null)
                      ...accountPicks(
                        context,
                        worker: w,
                        kind: kind,
                        chosen: _ready(_account) ? _account : null,
                        onPick: (id) => setState(() => _account = id),
                      ),
                    if (kind != null) ...[
                      _Section(s.chatModel),
                      _Picks(
                        children: [
                          _Pick(
                            label: s.chatDefault,
                            selected: _model == null,
                            onTap: () => setState(() => _model = null),
                          ),
                          for (final m in kind.models)
                            _Pick(
                              label: m,
                              selected: m == _model,
                              onTap: () => setState(() => _model = m),
                            ),
                          _Pick(
                            label: otherModel ? _model! : s.chatOther,
                            selected: otherModel,
                            onTap: _otherModel,
                          ),
                        ],
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
                      _Section(s.chatProject),
                      _Picks(
                        children: [
                          _Pick(
                            label: s.chatNoProject,
                            selected: _agents.project(_project) == null,
                            onTap: () => setState(() => _project = null),
                          ),
                          for (final project in _agents.projects)
                            _Pick(
                              label: _agents.pathOf(project),
                              dot: _projectColour(project),
                              selected: project.id == _project,
                              onTap: () =>
                                  setState(() => _project = project.id),
                            ),
                          _Pick(
                            label: _agents.projects.isEmpty
                                ? s.newProject
                                : s.editProjects,
                            icon: _agents.projects.isEmpty
                                ? Icons.add
                                : Icons.edit_outlined,
                            selected: false,
                            onTap: () => _agents.projects.isEmpty
                                ? openProject(context)
                                : openProjects(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        s.chatOwnFolderHint,
                        style: TextStyle(color: p.faint, fontSize: 12.5),
                      ),
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
                                    style: TextStyle(
                                      color: p.faint,
                                      fontSize: 12,
                                    ),
                                  )
                                : null,
                            value: _plugins?.contains(plugin) ?? false,
                            onChanged: (on) => setState(() {
                              final chosen = _plugins ??= {};
                              on ? chosen.add(plugin) : chosen.remove(plugin);
                            }),
                          ),
                      ],
                      if (kind.skills.isNotEmpty) ...[
                        _Section(s.chatSkills),
                        _Picks(
                          children: [
                            for (final skill in kind.skills)
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
                      if (kind.rules) ...[
                        _Section(s.agentRules),
                        _Picks(
                          children: [
                            for (final rule in _agents.rules)
                              _Pick(
                                label: _ruleName(s, rule),
                                selected: _chosen(rule),
                                onTap: () => setState(() {
                                  _chosen(rule)
                                      ? _rules.remove(rule.id)
                                      : _rules.add(rule.id);
                                }),
                              ),
                            _Pick(
                              label: _agents.rules.isEmpty
                                  ? s.newRule
                                  : s.editRules,
                              icon: _agents.rules.isEmpty
                                  ? Icons.add
                                  : Icons.edit_outlined,
                              selected: false,
                              onTap: () => _agents.rules.isEmpty
                                  ? openRule(context)
                                  : openRules(context),
                            ),
                          ],
                        ),
                      ],
                      // Each chat is titled by its task.
                      if (!_forTasks) ...[
                        _Section(s.chatTitle),
                        _Field(controller: _title),
                      ],
                      if (kind.prompt != 'none') ...[
                        _Section(_forTasks ? s.chatForEach : s.chatPrompt),
                        // What the chosen rules begin with, if nothing is
                        // written here.
                        _Field(
                          controller: _prompt,
                          hint: firstMessage('', _picked).isNotEmpty
                              ? firstMessage('', _picked)
                              : _forTasks
                              ? s.chatForEachHint
                              : null,
                          lines: 6,
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        child: FilledButton(
                          onPressed: _starting ? null : _start,
                          child: Text(
                            _forTasks
                                ? s.chatStartEach(
                                    widget.tasks.length - _sent.length,
                                  )
                                : _byHand
                                ? s.chatCreate
                                : s.chatStart,
                          ),
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

/// What a task sent to [kind] is marked with on its card: the model as
/// the watcher's tasks name it for Claude, else the agent and its model.
String agentMark(AgentKind kind, String? model) => switch ((kind.id, model)) {
  ('claude', final m?) => ClaudeModels.name(m),
  (_, final m?) => '${kind.label} · $m',
  _ => kind.label,
};

/// The tasks a form is sending on, a line each in their own colour, as
/// the day sheet's dense cards name them.
class _TaskLines extends StatelessWidget {
  final List<Task> tasks;

  const _TaskLines({required this.tasks});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final provider = context.read<TaskProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final task in tasks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colorOfTask(
                      task,
                      provider.listById(task.listId),
                      fallback: AppTheme.accentOf(context).color,
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.text, fontSize: 14.5),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String text;

  const _Section(this.text);

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: p.faint,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _Picks extends StatelessWidget {
  final List<Widget> children;

  const _Picks({required this.children});

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 6, runSpacing: 6, children: children);
}

/// One choice among a few: neutral, as the app's controls are — the one
/// chosen in the field's grey, the rest the ground with a hairline, as
/// the group chips are.
class _Pick extends StatelessWidget {
  final String label;
  final IconData? icon;

  /// A project's colour, a dot before the label in place of an icon.
  final Color? dot;
  final bool selected;
  final VoidCallback onTap;

  const _Pick({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.dot,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: selected ? p.field : p.bg,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? p.muted.withValues(alpha: 0.5) : p.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: selected ? p.text : p.muted),
                const SizedBox(width: 6),
              ],
              if (dot != null) ...[
                _Dot(colour: dot!, size: 9),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? p.text : p.muted,
                    fontSize: 13.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  final int lines;

  const _Field({required this.controller, this.hint, this.lines = 1});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return TextField(
      controller: controller,
      minLines: lines == 1 ? 1 : 3,
      maxLines: lines,
      style: TextStyle(color: p.text, fontSize: 14.5),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: p.field,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// One chat: Claude's or Codex's as a chat ([TalkView]), and beside it its
/// terminal, where the agent's own screen runs; any other agent's terminal
/// alone. One program at a time has the session, so moving between the
/// two moves the chat — the side not holding it says so, with a button.
///
/// In the terminal, on the phone a line is written in the field under it
/// and sent whole (pasted, then Enter), with a row of the keys a phone's
/// keyboard lacks; tapping the terminal does not bring up the keyboard,
/// which would type a key at a time over the network. On a desktop the
/// terminal takes the keys itself as well.
class ChatScreen extends StatefulWidget {
  final String chat;

  const ChatScreen({super.key, required this.chat});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _agents = Agents.instance;
  final _terminal = Terminal(maxLines: 10000);
  final _controller = TerminalController();
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  ChatFeed? _feed;
  TalkFeed? _talk;
  double _font = _TermFont.standard;

  /// Which side is on show, once chosen: else the side holding the chat.
  bool? _asChat;

  Chat? get _chat => _agents.chat(widget.chat);

  @override
  void initState() {
    super.initState();
    _agents.addListener(_changed);
    _agents.watch();
    Push.looking(widget.chat);
    _terminal.onOutput = _typed;
    _terminal.onResize = (cols, rows, _, _) => _sized(cols, rows);
    _follow();
    unawaited(_readLater());
    _TermFont.read().then((size) {
      if (mounted) setState(() => _font = size);
    });
  }

  /// Muted, or heard again; a refusal said, not lost.
  Future<void> _mute() async {
    final chat = _chat;
    if (chat == null) return;
    try {
      await _agents.mute([chat.id], muted: !chat.muted);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  void dispose() {
    Push.left(widget.chat);
    _agents.removeListener(_changed);
    _agents.unwatch();
    _feed?.close();
    _talk?.dispose();
    _sizing?.cancel();
    _flushing?.cancel();
    _laterCheck?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  ChatState? _lastState;
  String? _lastNote;

  void _changed() {
    if (!mounted) return;
    // The row has caught up with what was broadcast, or gone past it.
    final now = _chat?.state;
    if (now != _lastState) {
      _lastState = now;
      _talk?.state.value = null;
    }
    // A new note may say the worker left something for later itself: a
    // chat stopped at the usage limit, to carry on when it is lifted.
    final note = _chat?.note;
    if (note != _lastNote) {
      _lastNote = note;
      if (note != null) unawaited(_readLater());
    }
    _follow();
    // Started again: it takes the size it is shown at.
    final view = _viewSize;
    if ((_chat?.live ?? false) && view != null && _toldSize != view) {
      _sized(view.$1, view.$2);
    }
    setState(() {});
  }

  /// The size the view lays the terminal out at, while it does.
  (int, int)? _viewSize;
  bool _forcing = false;

  /// Starts reading the chat once it is known whether it has ended: opened
  /// from a task's form, the list may not have been read yet.
  ///
  /// What it wrote is drawn at the size it was last written at: drawn at
  /// another, xterm loses the alternate screen Claude draws in as it
  /// resizes, and only the bits redrawn since show. A live chat is then
  /// told the view's size, and redraws whole at it.
  void _follow() {
    final chat = _chat;
    if (chat == null) return;
    if (chat.talks && _talk == null) {
      try {
        _talk = _agents.talk(widget.chat);
      } catch (_) {
        // Signed out meanwhile.
      }
    }
    // A chat in its chat has no terminal to read until it is moved there.
    if (_feed != null || (chat.talks && chat.inChat)) return;
    if (!chat.live || _viewSize == null) {
      _forcing = true;
      _terminal.resize(chat.cols, chat.rows);
      _forcing = false;
    }
    try {
      _feed = _agents.feed(widget.chat, _show);
    } catch (_) {
      // Signed out meanwhile: nothing to show.
    }
  }

  /// An ended chat keeps the last of its alternate screen: Claude draws
  /// there, and leaving it as it exits would leave nothing to read back.
  late final _clean = TermCleaner(keepAlternate: () => !(_chat?.live ?? true));

  /// While what the agent wrote is being drawn: whatever the terminal
  /// says then is its answer to a question in it (what terminal is this,
  /// where is the cursor), which tmux on the worker has answered already.
  /// Sent on, it would be typed into the agent — and again each time the
  /// chat's past is read back.
  bool _drawing = false;

  void _show(String data) {
    _drawing = true;
    try {
      _terminal.write(_clean.add(data));
    } finally {
      _drawing = false;
    }
  }

  /// Keys typed into the terminal itself, a few at a time: one row each
  /// would be a round trip a letter.
  final _keys = StringBuffer();
  Timer? _flushing;

  void _typed(String data) {
    if (_drawing) return;
    _keys.write(TermSwipe.wheelFixed(data));
    _flushing ??= Timer(const Duration(milliseconds: 30), () {
      _flushing = null;
      final keys = _keys.toString();
      _keys.clear();
      if (keys.isNotEmpty) unawaited(_agents.keys(widget.chat, keys));
    });
  }

  /// The terminal laid out at a new size: told to the worker once it has
  /// settled, not on every frame of the keyboard sliding.
  Timer? _sizing;
  (int, int)? _toldSize;

  void _sized(int cols, int rows) {
    if (_forcing) return;
    _viewSize = (cols, rows);
    // An ended chat is shown at its own size; sent, it would be drawn at
    // the wrong one next time.
    if (!(_chat?.live ?? false)) return;
    _sizing?.cancel();
    _sizing = Timer(const Duration(milliseconds: 400), () {
      final chat = _chat;
      if (_toldSize == (cols, rows) || chat == null || !chat.live) return;
      _toldSize = (cols, rows);
      if (chat.cols == cols && chat.rows == rows) return;
      unawaited(_agents.resize(widget.chat, cols, rows));
    });
  }

  void _send() {
    if (_files.isNotEmpty) {
      unawaited(_sendWithFiles());
      return;
    }
    final text = _input.text;
    if (text.trim().isEmpty && (_chat?.inChat ?? false)) return;
    _input.clear();
    final chat = _chat;
    // As in Claude's own: in its terminal the program reads it itself.
    if (text.trim() == '/clear' && chat != null && chat.inChat && _canClear) {
      unawaited(_agents.clear(widget.chat));
      return;
    }
    unawaited(
      _agents.line(
        widget.chat,
        text.trimRight(),
        over: chat != null && chat.inChat ? _talk : null,
      ),
    );
  }

  /// Photos and files to go with the next message, copies on this device.
  List<Attachment> _files = const [];

  /// While they go up: the message goes once they are there.
  bool _sending = false;

  /// Whether the chat's worker takes files: one not reinstalled since
  /// would say the words and leave the files on the server.
  bool get _canAttach => _kindOf(_chat)?.files ?? false;

  /// Whether the chat's worker clears its context when asked.
  bool get _canClear => _kindOf(_chat)?.clears ?? false;

  AgentKind? _kindOf(Chat? chat) => chat == null
      ? null
      : _agents
            .worker(chat.workerId)
            ?.agents
            .where((a) => a.id == chat.agent)
            .firstOrNull;

  Future<void> _attach() async {
    final s = S.of(context);
    final from = await choose<AttachFrom>(
      context,
      title: s.chatAttachFiles,
      selected: null,
      options: [
        Option(AttachFrom.photos, s.attachPhoto, icon: Icons.photo_outlined),
        // A desktop has no camera app to hand a file to.
        if (!onDesktop)
          Option(
            AttachFrom.camera,
            s.attachCamera,
            icon: Icons.photo_camera_outlined,
          ),
        Option(AttachFrom.files, s.attachFile, icon: Icons.attach_file),
      ],
    );
    if (from == null || !mounted) return;
    final picked = await Attachments.instance.pick(from);
    if (!mounted) return;
    final fits = [
      for (final a in picked.attached)
        if (a.size <= Agents.largestFile) a,
    ];
    final tooBig = [
      ...picked.tooBig,
      for (final a in picked.attached)
        if (a.size > Agents.largestFile) a.name,
    ];
    for (final a in picked.attached) {
      if (a.size > Agents.largestFile) _letGo(a);
    }
    setState(() => _files = [..._files, ...fits]);
    if (tooBig.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(s.chatFileTooBig(tooBig.join(', ')))),
      );
    }
  }

  void _unattach(Attachment a) {
    setState(() => _files = [..._files]..remove(a));
    _letGo(a);
  }

  /// [a]'s copy deleted, with the folder it was made in: it was the
  /// chat's to send, not a task's to keep.
  void _letGo(Attachment a) {
    final folder = Attachments.instance.fileOf(a)?.parent;
    if (folder == null) return;
    unawaited(
      folder.delete(recursive: true).then((_) {}, onError: (Object _) {}),
    );
  }

  /// The message and its files: the files up first, the words and files
  /// kept where they are until they have gone.
  Future<void> _sendWithFiles() async {
    if (_sending) return;
    final files = _files;
    final text = _input.text.trimRight();
    final chat = _chat;
    setState(() => _sending = true);
    try {
      await _agents.line(
        widget.chat,
        text,
        over: chat != null && chat.inChat ? _talk : null,
        files: files,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(S.of(context).chatFilesFailed)));
      }
      return;
    }
    files.forEach(_letGo);
    if (!mounted) return;
    // Only what was sent is cleared: words typed meanwhile stay.
    if (_input.text.trimRight() == text) _input.clear();
    setState(() {
      _sending = false;
      _files = [
        for (final a in _files)
          if (!files.contains(a)) a,
      ];
    });
  }

  /// Messages left for later and not yet said, soonest first.
  List<LaterLine> _later = const [];
  Timer? _laterCheck;

  /// Whether the chat's worker says messages left for later: one not
  /// reinstalled since would leave them unsaid.
  bool get _canLater => _kindOf(_chat)?.later ?? false;

  /// Read again a little after the next is due, when its worker has said
  /// it — and every so often after, while one due is still waiting (its
  /// worker away, or the chat not running).
  Future<void> _readLater() async {
    _laterCheck?.cancel();
    List<LaterLine> later;
    try {
      later = await _agents.laterOf(widget.chat);
    } catch (_) {
      // Signed out, or offline: what is shown stays.
      later = _later;
    }
    if (!mounted) return;
    setState(() => _later = later);
    if (later.isEmpty) return;
    final wait = later.first.at.difference(DateTime.now());
    _laterCheck = Timer(
      wait.isNegative
          ? const Duration(seconds: 15)
          : wait + const Duration(seconds: 3),
      _readLater,
    );
  }

  /// What is written, left to be said later: when is asked first.
  Future<void> _sendLater() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final at = await _whenLater();
    if (at == null || !mounted) return;
    _input.clear();
    try {
      final line = await _agents.later(widget.chat, text, at);
      if (!mounted) return;
      setState(
        () => _later = [..._later, line]..sort((a, b) => a.at.compareTo(b.at)),
      );
      unawaited(_readLater());
    } catch (_) {
      // Not kept: the words go back where they were written.
      if (mounted && _input.text.isEmpty) _input.text = text;
    }
  }

  Future<DateTime?> _whenLater() async {
    final s = S.of(context);
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final now = DateTime.now();
    final morning = DateTime(now.year, now.month, now.day + 1, 9);
    final minutes = await choose<int>(
      context,
      title: s.chatLater,
      selected: null,
      options: [
        Option(30, s.chatLater30, icon: Icons.schedule_rounded),
        Option(60, s.chatLater60, icon: Icons.schedule_rounded),
        Option(180, s.chatLater180, icon: Icons.schedule_rounded),
        Option(
          -1,
          s.chatLaterTomorrow(Dates.time(morning, h24: h24)),
          icon: Icons.wb_twilight_rounded,
        ),
        Option(-2, s.chatLaterPick, icon: Icons.event_rounded),
      ],
    );
    if (minutes == null || !mounted) return null;
    if (minutes == -1) return morning;
    if (minutes > 0) return DateTime.now().add(Duration(minutes: minutes));
    final day = await showAppDatePicker(
      context: context,
      initial: now,
      firstDate: DateTime(now.year, now.month, now.day),
    );
    if (day == null || !mounted) return null;
    final soon = now.add(const Duration(hours: 1));
    final time = await showAppTimePicker(
      context: context,
      initial: TimeOfDay(hour: soon.hour, minute: 0),
    );
    if (time == null) return null;
    // A time already past is said at once.
    return DateTime(day.year, day.month, day.day, time.hour, time.minute);
  }

  /// Whether a tick on the stop at the limit is still being written.
  bool _carrying = false;

  /// The stop at the usage limit [item], ticked: the chat is left to carry
  /// on by itself once the limit is lifted — or, ticked again, not. Never
  /// asked for unless ticked.
  Future<void> _carry(ChatItem item) async {
    if (_carrying) return;
    _carrying = true;
    try {
      final left = _later.where((line) => line.carriesOn).toList();
      if (left.isNotEmpty) {
        for (final line in left) {
          await _takeBack(line);
        }
        return;
      }
      final resets = item.body['resets'];
      final at = CarryOn.at(
        resets is num
            ? DateTime.fromMillisecondsSinceEpoch(resets.round())
            : null,
        DateTime.now(),
      );
      final line = await _agents.later(
        widget.chat,
        CarryOn.words,
        at,
        carryOn: true,
      );
      if (!mounted) return;
      setState(
        () => _later = [..._later, line]..sort((a, b) => a.at.compareTo(b.at)),
      );
      unawaited(_readLater());
    } catch (_) {
      // Not kept: the box stays as it was.
      unawaited(_readLater());
    } finally {
      _carrying = false;
    }
  }

  /// A message left for later, tapped: said now, written again, or put
  /// away. Unless its worker has said it meanwhile.
  Future<void> _laterTapped(LaterLine line) async {
    final s = S.of(context);
    final what = await choose<String>(
      context,
      title: line.text.split('\n').first,
      selected: null,
      options: [
        Option('now', s.chatSendNow, icon: Icons.arrow_upward_rounded),
        Option('edit', s.chatLaterEdit, icon: Icons.edit_outlined),
        Option('delete', s.delete, icon: Icons.delete_outline_rounded),
      ],
    );
    if (what == null || !mounted) return;
    await _takeBack(line, then: what);
  }

  Future<void> _takeBack(LaterLine line, {String then = 'delete'}) async {
    setState(() => _later = [..._later]..remove(line));
    bool back;
    try {
      back = await _agents.takeBack(line);
    } catch (_) {
      unawaited(_readLater());
      return;
    }
    if (!back || !mounted) return;
    switch (then) {
      case 'now':
        final chat = _chat;
        unawaited(
          _agents.line(
            widget.chat,
            line.text,
            over: chat != null && chat.inChat ? _talk : null,
          ),
        );
      case 'edit':
        final was = _input.text.trim();
        _input.text = was.isEmpty ? line.text : '$was\n${line.text}';
        _inputFocus.requestFocus();
    }
  }

  Future<void> _toTerminal() async {
    final s = S.of(context);
    if (_chat?.state == ChatState.running) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(s.chatMoveStops),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(s.chatToTerminal),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _asChat = false);
    await _agents.move(widget.chat, toChat: false);
  }

  Future<void> _toChat() async {
    setState(() => _asChat = true);
    await _agents.move(widget.chat, toChat: true);
  }

  void _key(TerminalKey key, {bool shift = false, bool ctrl = false}) {
    HapticFeedback.selectionClick();
    _terminal.keyInput(key, shift: shift, ctrl: ctrl);
  }

  Future<void> _setFont(double size) async {
    setState(() => _font = size.clamp(7, 24));
    await _TermFont.write(_font);
  }

  void _settings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatSettingsScreen(chat: widget.chat),
    ),
  );

  Future<void> _delete() async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteChatQuestion),
        content: Text(s.cannotBeUndone),
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
    if (ok != true || !mounted) return;
    await _agents.remove(widget.chat);
    if (mounted) Navigator.of(context).pop();
  }

  /// The text size at which [cols] columns fill [width], no bigger than
  /// the chosen one. A monospace cell is about 0.6 of its size wide.
  double _fitted(double width, int cols) =>
      (width / (cols * 0.6)).clamp(5.0, _font);

  /// Made again only for another palette: xterm tells themes apart by
  /// identity, and a new one throws away every letter it has laid out —
  /// on every rebuild, which the keyboard's slide makes each frame.
  TerminalTheme _theme(AppPalette p) {
    if (!identical(p, _themedFor)) {
      _themedFor = p;
      _themed = _themeOf(p);
    }
    return _themed!;
  }

  AppPalette? _themedFor;
  TerminalTheme? _themed;

  static TerminalTheme _themeOf(AppPalette p) => TerminalTheme(
    cursor: p.text.withValues(alpha: 0.75),
    selection: p.muted.withValues(alpha: 0.4),
    foreground: p.text,
    background: p.bg,
    black: const Color(0xFF000000),
    red: const Color(0xFFE06C6C),
    green: const Color(0xFF7CC67C),
    yellow: const Color(0xFFE0C068),
    blue: const Color(0xFF6C9BE0),
    magenta: const Color(0xFFC08CE0),
    cyan: const Color(0xFF68C0D0),
    white: const Color(0xFFD8D8D8),
    brightBlack: const Color(0xFF6E6E70),
    brightRed: const Color(0xFFF08080),
    brightGreen: const Color(0xFF98DC98),
    brightYellow: const Color(0xFFF0D890),
    brightBlue: const Color(0xFF90B8F0),
    brightMagenta: const Color(0xFFD8A8F0),
    brightCyan: const Color(0xFF90D8E8),
    brightWhite: const Color(0xFFFFFFFF),
    searchHitBackground: const Color(0xFFFFFF2B),
    searchHitBackgroundCurrent: const Color(0xFF31FF26),
    searchHitForeground: const Color(0xFF000000),
  );

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final chat = _chat;
    final live = chat?.live ?? false;
    final talks = chat != null && chat.talks;
    final asChat = talks && (_asChat ?? chat.inChat);
    final talk = _talk;
    final waits = chat?.state == ChatState.waiting;
    final again = chat != null && !live && chat.state != ChatState.asked
        ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton.tonal(
                onPressed: () => waits
                    ? _agents.startNow(widget.chat)
                    : _agents.again(widget.chat),
                child: Text(waits ? s.chatStartNow : s.chatAgain),
              ),
            ),
          )
        : null;
    return Scaffold(
      backgroundColor: p.bg,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        // The gesture bar's strip stays reserved under the keys, as it
        // does in the shell; `KeyboardGap` takes the lift from there.
        maintainBottomViewPadding: true,
        child: Column(
          children: [
            _Head(
              chat: chat,
              font: _font,
              onFont: _setFont,
              onStop: () => _agents.stop(widget.chat),
              onAgain: () => _agents.again(widget.chat),
              onClear: chat != null && chat.inChat && chat.live && _canClear
                  ? () => _agents.clear(widget.chat)
                  : null,
              onDelete: _delete,
              onSettings: _settings,
              onMute: _mute,
              asChat: talks ? asChat : null,
              onView: (chat) => setState(() => _asChat = chat),
            ),
            // On either side, and once it has stopped: what a chat spent
            // is still worth reading in its terminal, or after it ended.
            if (chat != null) _usage(chat, talk),
            Expanded(
              child: asChat && talk != null
                  ? ValueListenableBuilder(
                      valueListenable: talk.state,
                      builder: (context, heard, _) => TalkView(
                        feed: talk,
                        working:
                            chat.inChat &&
                            (heard ?? chat.state.name) == 'running',
                        onAnswer: (item, choice, answers) => _agents.answer(
                          widget.chat,
                          item,
                          choice,
                          answers: answers,
                        ),
                        carrying: _later.any((line) => line.carriesOn),
                        onCarry: _canLater ? _carry : null,
                        // The chat's own: the account's, newer, would
                        // no longer show the limit spent once it resets.
                        usage: talk.usage.value ?? chat.usage,
                      ),
                    )
                  : talks && chat.inChat
                  ? _Elsewhere(
                      text: s.chatInChatNow(_agentName(chat)),
                      action: live ? s.chatToTerminal : null,
                      onTap: _toTerminal,
                    )
                  : asChat
                  ? const SizedBox.shrink()
                  : _terminalView(chat, live, p),
            ),
            // Carrying on after the limit is the switch on its card, not
            // a message of the user's left for later.
            if (_later.where((line) => !line.carriesOn).toList()
                case final later when later.isNotEmpty)
              LaterList(lines: later, onTap: _laterTapped, onDelete: _takeBack),
            if (asChat) ...[
              if (!chat.inChat)
                _MoveBar(
                  text: s.chatInTerminalNow,
                  action: s.chatToChat,
                  onTap: _toChat,
                )
              else if (live && talk != null)
                ValueListenableBuilder(
                  valueListenable: talk.state,
                  builder: (context, heard, _) {
                    final at = heard ?? chat.state.name;
                    return _InputRow(
                      controller: _input,
                      focus: _inputFocus,
                      hint: s.chatMessage,
                      onSend: _send,
                      // Its files could not be put back to edit it.
                      onLater: _canLater && _files.isEmpty ? _sendLater : null,
                      onStop: at == 'running' || at == 'asking'
                          ? () => _agents.interrupt(widget.chat)
                          : null,
                      onAttach: _canAttach ? _attach : null,
                      files: _files,
                      sending: _sending,
                      onUnattach: _unattach,
                    );
                  },
                )
              else
                ?again,
            ] else if (!(talks && chat.inChat)) ...[
              if (live) ...[
                _KeyRow(onKey: _key),
                _InputRow(
                  controller: _input,
                  focus: _inputFocus,
                  hint: s.chatMessage,
                  onSend: _send,
                  onLater: _canLater && _files.isEmpty ? _sendLater : null,
                  onAttach: _canAttach ? _attach : null,
                  files: _files,
                  sending: _sending,
                  onUnattach: _unattach,
                ),
              ] else
                ?again,
            ],
            SizedBox(height: KeyboardGap.of(context)),
          ],
        ),
      ),
    );
  }

  /// The chat's figures as last heard: broadcast while it runs, else as
  /// its row keeps them. Nothing for a chat that has none (a shell).
  /// The chat's figures under its head, with its account's limits as
  /// the worker last read them: the chat's own copy is as old as its last
  /// turn, which for a chat left a while is old indeed.
  Widget _usage(Chat chat, TalkFeed? talk) {
    ChatUsage? withAccount(ChatUsage? own) {
      final current = _chat ?? chat;
      final account = _agents.accountOf(current)?.usage;
      if (own == null && account == null) return null;
      return (own ?? const ChatUsage()).withLimitsOf(account);
    }

    String? accountName() {
      final account = _agents.accountOf(_chat ?? chat);
      return account == null ? null : accountTitle(account);
    }

    Widget strip(ChatUsage? usage) => usage == null || usage.isEmpty
        ? const SizedBox.shrink()
        : ChatUsageStrip(
            usage: usage,
            onTap: () => showChatUsage(
              context,
              changes: talk == null
                  ? _agents
                  : Listenable.merge([_agents, talk.usage]),
              read: () => withAccount(talk?.usage.value ?? _chat?.usage),
              account: accountName,
            ),
          );
    if (talk == null) return strip(withAccount(chat.usage));
    return ValueListenableBuilder(
      valueListenable: talk.usage,
      builder: (context, heard, _) => strip(withAccount(heard ?? chat.usage)),
    );
  }

  String _agentName(Chat chat) =>
      _agents
          .worker(chat.workerId)
          ?.agents
          .where((a) => a.id == chat.agent)
          .firstOrNull
          ?.label ??
      chat.agent;

  Widget _terminalView(Chat? chat, bool live, AppPalette p) => LayoutBuilder(
    builder: (context, box) => TermSwipe(
      terminal: _terminal,
      lineHeight: _font * 1.2,
      cellWidth: _font * 0.6,
      padding: const Offset(_TermFont.side, 4),
      enabled: live,
      child: TerminalView(
        _terminal,
        controller: _controller,
        theme: _theme(p),
        // An ended chat's text is made small enough for the width it was
        // written at to fit; the view's size is only told to a live one.
        textStyle: _TermFont.style(
          live || chat == null
              ? _font
              : _fitted(box.maxWidth - 2 * _TermFont.side, chat.cols),
        ),
        padding: const EdgeInsets.fromLTRB(
          _TermFont.side,
          4,
          _TermFont.side,
          4,
        ),
        // A key a time over the network is no way to type on a phone; the
        // field below is. A desktop's keys go straight in.
        readOnly: !onDesktop || !live,
        hardwareKeyboardOnly: onDesktop,
        autofocus: onDesktop,
        keyboardAppearance: Brightness.dark,
      ),
    ),
  );
}

/// The side of a chat not holding it: what is going on, and a button to
/// bring the chat here.
class _Elsewhere extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback onTap;

  const _Elsewhere({
    required this.text,
    required this.action,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_rounded, size: 36, color: p.faint),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: 14, height: 1.4),
            ),
            if (action != null) ...[
              const SizedBox(height: 18),
              FilledButton.tonal(onPressed: onTap, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Under the chat while the chat is in its terminal: where it is, and the
/// way back.
class _MoveBar extends StatelessWidget {
  final String text;
  final String action;
  final VoidCallback onTap;

  const _MoveBar({
    required this.text,
    required this.action,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: TextStyle(color: p.muted, fontSize: 13)),
          ),
          FilledButton.tonal(onPressed: onTap, child: Text(action)),
        ],
      ),
    );
  }
}

class _Head extends StatelessWidget {
  final Chat? chat;
  final double font;
  final ValueChanged<double> onFont;
  final VoidCallback onStop;
  final VoidCallback onAgain;

  /// Its context cleared; null where it can't be (a terminal, a worker
  /// from before).
  final VoidCallback? onClear;
  final VoidCallback onDelete;
  final VoidCallback onSettings;
  final VoidCallback onMute;

  /// Which side is on show, for a chat with both; null for a terminal only.
  final bool? asChat;
  final ValueChanged<bool> onView;

  const _Head({
    required this.chat,
    required this.font,
    required this.onFont,
    required this.onStop,
    required this.onAgain,
    required this.onClear,
    required this.onDelete,
    required this.onSettings,
    required this.onMute,
    required this.asChat,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final chat = this.chat;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: p.muted),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          if (chat != null) ...[
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _StateMark(state: chat.state, size: 8),
            ),
            Expanded(
              // Its name and what it runs with: a tap opens its settings.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onSettings,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chat.name.isEmpty ? _lineOf(chat) : chat.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${_stateName(s, chat)} · ${_lineOf(chat)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ] else
            const Spacer(),
          if (asChat case final asChat?)
            _SideSwitch(asChat: asChat, onView: onView),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: p.muted),
            onSelected: (choice) {
              switch (choice) {
                case 'bigger':
                  onFont(font + 1);
                case 'smaller':
                  onFont(font - 1);
                case 'stop':
                  onStop();
                case 'again':
                  onAgain();
                case 'clear':
                  onClear?.call();
                case 'settings':
                  onSettings();
                case 'mute':
                  onMute();
                case 'attach':
                  Clipboard.setData(
                    ClipboardData(
                      text:
                          'tmux -L caldo attach -t c${chat!.id.replaceAll('-', '')}',
                    ),
                  );
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (context) => [
              if (asChat != true) ...[
                PopupMenuItem(value: 'bigger', child: Text(s.chatBigger)),
                PopupMenuItem(value: 'smaller', child: Text(s.chatSmaller)),
              ],
              if (chat != null) ...[
                PopupMenuItem(value: 'settings', child: Text(s.chatSettings)),
                PopupMenuItem(
                  value: 'mute',
                  child: Text(chat.muted ? s.chatUnmute : s.chatMute),
                ),
              ],
              if (onClear != null)
                PopupMenuItem(value: 'clear', child: Text(s.chatClear)),
              if (chat != null && chat.live)
                PopupMenuItem(value: 'stop', child: Text(s.chatStop))
              else if (chat != null &&
                  chat.state != ChatState.asked &&
                  chat.state != ChatState.waiting)
                PopupMenuItem(value: 'again', child: Text(s.chatAgain)),
              if (chat != null && chat.live && !chat.inChat)
                PopupMenuItem(
                  value: 'attach',
                  child: Text(
                    s.chatAttach('c${chat.id.substring(0, 8)}…'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              PopupMenuItem(
                value: 'delete',
                child: Text(
                  s.chatDelete,
                  style: TextStyle(color: AppColors.danger),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Chat or terminal: two icons in a pill, the one on show lit.
class _SideSwitch extends StatelessWidget {
  final bool asChat;
  final ValueChanged<bool> onView;

  const _SideSwitch({required this.asChat, required this.onView});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    Widget side(bool chat, IconData icon, String name) {
      final lit = chat == asChat;
      return Tooltip(
        message: name,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: lit
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onView(chat);
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 40,
            height: 28,
            decoration: BoxDecoration(
              color: lit ? p.panelHi : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 17, color: lit ? p.text : p.faint),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          side(true, Icons.chat_bubble_outline_rounded, s.chatAsChat),
          side(false, Icons.terminal_rounded, s.chatAsTerminal),
        ],
      ),
    );
  }
}

/// The keys a phone's keyboard has not got, that an agent's terminal
/// wants: Escape to interrupt Claude, Shift+Tab to change its mode, the
/// arrows for its menus, Ctrl+C. All in one row the width of the screen,
/// none scrolled out of reach.
class _KeyRow extends StatelessWidget {
  final void Function(TerminalKey key, {bool shift, bool ctrl}) onKey;

  const _KeyRow({required this.onKey});

  @override
  Widget build(BuildContext context) {
    final keys = <(String?, IconData?, VoidCallback)>[
      ('esc', null, () => onKey(TerminalKey.escape)),
      ('tab', null, () => onKey(TerminalKey.tab)),
      ('⇧tab', null, () => onKey(TerminalKey.tab, shift: true)),
      (null, Icons.keyboard_arrow_up_rounded, () => onKey(TerminalKey.arrowUp)),
      (
        null,
        Icons.keyboard_arrow_down_rounded,
        () => onKey(TerminalKey.arrowDown),
      ),
      (
        null,
        Icons.keyboard_arrow_left_rounded,
        () => onKey(TerminalKey.arrowLeft),
      ),
      (
        null,
        Icons.keyboard_arrow_right_rounded,
        () => onKey(TerminalKey.arrowRight),
      ),
      ('^C', null, () => onKey(TerminalKey.keyC, ctrl: true)),
      (null, Icons.keyboard_return_rounded, () => onKey(TerminalKey.enter)),
    ];
    return Align(
      alignment: Alignment.centerLeft,
      // On a desk the row would stretch into slabs.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: SizedBox(
            height: 34,
            child: Row(
              children: [
                for (final (i, (label, icon, tap)) in keys.indexed) ...[
                  if (i > 0) const SizedBox(width: 5),
                  Expanded(
                    child: _TermKey(label: label, icon: icon, onTap: tap),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TermKey extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;

  const _TermKey({required this.onTap, this.label, this.icon});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: p.panel,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Center(
          child: icon != null
              ? Icon(icon, size: 20, color: p.muted)
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label!,
                    maxLines: 1,
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 12.5,
                      fontFamily: 'JetBrains Mono',
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _InputRow extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final String hint;
  final VoidCallback onSend;

  /// While a turn is under way: the button, with nothing written, stops it.
  final VoidCallback? onStop;

  /// The button held (or right-clicked) with something written: it is
  /// left to be said later.
  final VoidCallback? onLater;

  /// A plus before the field, offering a photo, the camera or a file;
  /// none where the worker would not take them.
  final VoidCallback? onAttach;

  /// What goes with the next message, over the field; [sending] while it
  /// goes up.
  final List<Attachment> files;
  final bool sending;
  final ValueChanged<Attachment>? onUnattach;

  const _InputRow({
    required this.controller,
    required this.focus,
    required this.hint,
    required this.onSend,
    this.onStop,
    this.onLater,
    this.onAttach,
    this.files = const [],
    this.sending = false,
    this.onUnattach,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (onAttach != null) ...[
            _RoundButton(
              icon: Icons.add_rounded,
              tooltip: S.of(context).chatAttachFiles,
              onTap: sending ? null : onAttach,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: CallbackShortcuts(
              // Enter sends on a desktop; Shift+Enter is a new line.
              bindings: {
                if (onDesktop)
                  const SingleActivator(LogicalKeyboardKey.enter): onSend,
              },
              child: TextField(
                controller: controller,
                focusNode: focus,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                keyboardAppearance: Brightness.dark,
                style: TextStyle(color: p.text, fontSize: 15),
                decoration: InputDecoration(
                  hintText: hint,
                  isDense: true,
                  filled: true,
                  fillColor: p.field,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(
                      color: BarRoom.rim(p),
                      width: BarRoom.rimWidth,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(
                      color: BarRoom.rim(p),
                      width: BarRoom.rimWidth,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(
                      color: BarRoom.rim(p),
                      width: BarRoom.rimWidth,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final stop =
                  onStop != null &&
                  controller.text.trim().isEmpty &&
                  files.isEmpty;
              final later = onLater != null && controller.text.trim().isNotEmpty
                  ? () {
                      HapticFeedback.mediumImpact();
                      onLater!();
                    }
                  : null;
              return Material(
                color: p.field,
                shape: CircleBorder(
                  side: BorderSide(
                    color: BarRoom.rim(p),
                    width: BarRoom.rimWidth,
                  ),
                ),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: sending
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          stop ? onStop!() : onSend();
                        },
                  onLongPress: sending ? null : later,
                  onSecondaryTap: sending ? null : later,
                  child: SizedBox.square(
                    dimension: 44,
                    child: sending
                        ? Center(
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: p.muted,
                              ),
                            ),
                          )
                        : stop
                        ? Tooltip(
                            message: S.of(context).chatInterrupt,
                            child: Icon(Icons.stop_rounded, color: p.text),
                          )
                        : Icon(Icons.arrow_upward_rounded, color: p.text),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
    if (files.isEmpty) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
            children: [
              for (final a in files)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _FileChip(
                    file: a,
                    onRemove: sending || onUnattach == null
                        ? null
                        : () => onUnattach!(a),
                  ),
                ),
            ],
          ),
        ),
        row,
      ],
    );
  }
}

/// A round button beside the field, drawn as the send button is.
class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _RoundButton({required this.icon, required this.tooltip, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: p.field,
      shape: CircleBorder(
        side: BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: Tooltip(
          message: tooltip,
          child: SizedBox.square(
            dimension: 44,
            child: Icon(icon, color: onTap == null ? p.muted : p.text),
          ),
        ),
      ),
    );
  }
}

/// A photo or file waiting to go with the message: a photo's own picture,
/// else an icon; its name and size; × to leave it out.
class _FileChip extends StatelessWidget {
  final Attachment file;
  final VoidCallback? onRemove;

  const _FileChip({required this.file, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final copy = Attachments.instance.fileOf(file);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 2, 4),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BarRoom.rim(p), width: BarRoom.rimWidth),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.square(
              dimension: 32,
              child: file.isImage && copy != null
                  ? Image.file(
                      copy,
                      fit: BoxFit.cover,
                      // A photo of several megabytes is drawn the size of
                      // the chip, not decoded whole.
                      cacheWidth: (32 * dpr).round(),
                      errorBuilder: (_, _, _) => _icon(p),
                    )
                  : _icon(p),
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.text, fontSize: 13),
                ),
                Text(
                  sizeWord(file.size),
                  maxLines: 1,
                  style: TextStyle(color: p.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          SizedBox.square(
            dimension: 32,
            child: onRemove == null
                ? null
                : IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    tooltip: S.of(context).delete,
                    onPressed: onRemove,
                    icon: Icon(Icons.close_rounded, color: p.muted),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _icon(AppPalette p) => ColoredBox(
    color: p.panelHi,
    child: Icon(
      file.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined,
      size: 18,
      color: p.muted,
    ),
  );
}

/// The messages left for later, over the field: when each goes and its
/// first line. A tap offers it now, to write again, or to put away.
class LaterList extends StatelessWidget {
  final List<LaterLine> lines;
  final ValueChanged<LaterLine> onTap;
  final ValueChanged<LaterLine> onDelete;

  const LaterList({
    super.key,
    required this.lines,
    required this.onTap,
    required this.onDelete,
  });

  /// "17:30" today, else "Tomorrow 9:00", "Nov 26 9:00".
  static String whenOf(DateTime at, {required bool h24}) {
    final time = Dates.time(at, h24: h24);
    return DateUtils.isSameDay(at, DateTime.now())
        ? time
        : '${Dates.dayWord(at) ?? Dates.shortDay(at)} $time';
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    return ConstrainedBox(
      // Three show; more scroll.
      constraints: const BoxConstraints(maxHeight: 3 * 40 + 4),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: p.field,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: BarRoom.rim(p),
                    width: BarRoom.rimWidth,
                  ),
                ),
                child: InkWell(
                  customBorder: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  onTap: () => onTap(line),
                  child: SizedBox(
                    height: 36,
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        Icon(Icons.schedule_rounded, size: 16, color: p.muted),
                        const SizedBox(width: 6),
                        // The words get the most of the row.
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width * 0.4,
                          ),
                          child: Text(
                            whenOf(line.at, h24: h24),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            line.text.split('\n').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: p.text, fontSize: 14),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          tooltip: S.of(context).delete,
                          onPressed: () => onDelete(line),
                          icon: Icon(Icons.close_rounded, color: p.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A finger's swipe over a program that draws its own screen — Claude,
/// Codex, anything in the alternate screen — sent to it as the mouse's
/// wheel, a notch a line, as a terminal on a computer would: xterm.dart
/// drops a swipe there, so the user could not scroll the chat at all. A
/// program that has not asked for the mouse gets the arrow keys instead.
///
/// It only listens, taking no part in the gestures, so xterm's own
/// scrolling of the ordinary screen's history and a mouse's selection on
/// a desk are left as they are.
class TermSwipe extends StatefulWidget {
  final Terminal terminal;
  final double lineHeight;
  final double cellWidth;

  /// Where the terminal's first cell starts inside [child].
  final Offset padding;
  final bool enabled;
  final Widget child;

  const TermSwipe({
    super.key,
    required this.terminal,
    required this.lineHeight,
    required this.cellWidth,
    required this.padding,
    required this.enabled,
    required this.child,
  });

  /// [data] with xterm.dart's wheel set right: it numbers the wheel's
  /// buttons 68–71 where terminals use 64–67, which reads as the wheel
  /// with Shift held, and Claude does not scroll for that.
  static String wheelFixed(String data) => data
      .replaceAllMapped(
        RegExp(r'\x1b\[<(6[89]|7[01]);'),
        (m) => '\x1b[<${int.parse(m[1]!) - 4};',
      )
      .replaceAllMapped(
        RegExp('\x1b\\[M([\x64-\x67])'),
        (m) => '\x1b[M${String.fromCharCode(m[1]!.codeUnitAt(0) - 4)}',
      );

  @override
  State<TermSwipe> createState() => _TermSwipeState();
}

class _TermSwipeState extends State<TermSwipe> {
  int? _finger;
  double _moved = 0;

  void _down(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch &&
        e.kind != PointerDeviceKind.stylus) {
      return;
    }
    _finger = e.pointer;
    _moved = 0;
  }

  void _move(PointerMoveEvent e) {
    final t = widget.terminal;
    if (e.pointer != _finger || !widget.enabled || !t.isUsingAltBuffer) return;
    _moved += e.delta.dy;
    final cell = CellOffset(
      ((e.localPosition.dx - widget.padding.dx) / widget.cellWidth)
          .floor()
          .clamp(0, t.viewWidth - 1),
      ((e.localPosition.dy - widget.padding.dy) / widget.lineHeight)
          .floor()
          .clamp(0, t.viewHeight - 1),
    );
    while (_moved.abs() >= widget.lineHeight) {
      // A finger drawn down brings what is above into view: the wheel up.
      final up = _moved > 0;
      _moved -= up ? widget.lineHeight : -widget.lineHeight;
      if (t.mouseMode.reportScroll) {
        t.mouseInput(
          up ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
          TerminalMouseButtonState.down,
          cell,
        );
      } else {
        t.keyInput(up ? TerminalKey.arrowUp : TerminalKey.arrowDown);
      }
    }
  }

  void _up(PointerEvent e) {
    if (e.pointer == _finger) _finger = null;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _up,
    onPointerCancel: _up,
    child: widget.child,
  );
}

/// What the agent wrote, less what xterm.dart would read wrongly: requests
/// with a private prefix (`ESC [ > 4 ; 2 m`, Claude asking for a keyboard
/// mode) reach its SGR as if plain, and underlined everything after.
/// A sequence cut across two pieces is held until the rest comes.
class TermCleaner {
  /// Whether leaving the alternate screen is dropped.
  final bool Function() keepAlternate;

  TermCleaner({bool Function()? keepAlternate})
    : keepAlternate = keepAlternate ?? (() => false);

  String _held = '';

  static final _private = RegExp(r'\x1b\[[<>=][0-9;:]*[@-~]');
  static final _leaveAlternate = RegExp(r'\x1b\[\?(?:1049|1047|47)l');

  /// An escape sequence not yet ended at the end of a piece.
  static final _open = RegExp(r'\x1b(\[[0-9;:<>=?]*)?$');

  String add(String data) {
    var text = _held + data;
    _held = '';
    final open = _open.firstMatch(text);
    if (open != null) {
      _held = text.substring(open.start);
      text = text.substring(0, open.start);
    }
    text = text.replaceAll(_private, '');
    return keepAlternate() ? text.replaceAll(_leaveAlternate, '') : text;
  }
}

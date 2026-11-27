import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../mcp/usage.dart' show CarryOn, ChatUsage;
import '../services/agents.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'chat_usage.dart' show limitBrief;
import 'markdown_text.dart';
import 'photo_viewer.dart';

/// A chat with an agent as a chat: the user's words on the right, the
/// agent's answers across the width in Markdown, each tool it used as one
/// line that opens to what it did, questions of permission with their
/// buttons — the same for Claude and Codex, whatever their terminals look
/// like.
///
/// It stays at the foot while the newest words are being written, unless
/// the reader has scrolled up: then nothing moves under them, as what
/// comes is added below.
class TalkView extends StatefulWidget {
  final TalkFeed feed;

  /// Whether a turn is under way, for the line at the foot that says so.
  final bool working;

  /// A question answered: [answers] by each question's words, for those
  /// asked of the user.
  final void Function(String item, String choice, Map<String, String> answers)
  onAnswer;

  /// When the saved retry is due, and the switch that schedules or cancels it.
  /// The switch is offered only where the worker can leave messages for later.
  final DateTime? carryOnAt;
  final bool savingCarryOn;
  final ValueChanged<ChatItem>? onCarry;

  /// What the chat has spent, for which limit stopped it.
  final ChatUsage? usage;

  /// Room left at the top and foot of the list.
  final EdgeInsets padding;

  /// Extra viewport behind the glass composer, also reserved in the scroll
  /// extent so the latest message can still settle above it.
  final double bottomOverlap;

  const TalkView({
    super.key,
    required this.feed,
    required this.working,
    required this.onAnswer,
    this.carryOnAt,
    this.savingCarryOn = false,
    this.onCarry,
    this.usage,
    this.padding = EdgeInsets.zero,
    this.bottomOverlap = 0,
  });

  @override
  State<TalkView> createState() => _TalkViewState();
}

class _TalkViewState extends State<TalkView> {
  late final _scroll = _TalkScrollController(() => _atFoot);
  final _open = <String>{};
  static const _liveStart = ValueKey('live start');
  int? _historyEnd;

  /// Whether the foot is in view, so what comes is followed.
  bool _atFoot = true;

  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_changed);
    _scroll.addListener(_scrolled);
  }

  @override
  void didUpdateWidget(TalkView old) {
    super.didUpdateWidget(old);
    if (old.feed != widget.feed) {
      old.feed.removeListener(_changed);
      widget.feed.addListener(_changed);
      _historyEnd = null;
      _atFoot = true;
    }
  }

  @override
  void dispose() {
    widget.feed.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    // History that does not yet fill the screen leaves nothing to scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nearTop();
    });
  }

  void _scrolled() {
    if (!_scroll.hasClients) return;
    final at = _scroll.position;
    _atFoot = at.pixels >= at.maxScrollExtent - 24;
    _nearTop();
  }

  /// Within a screen and a half of the earliest item read, the page before
  /// it is asked for.
  void _nearTop() {
    if (!_scroll.hasClients || widget.feed.historyComplete) return;
    final at = _scroll.position;
    if (!at.hasContentDimensions) return;
    if (at.pixels - at.minScrollExtent < at.viewportDimension * 1.5) {
      widget.feed.wantOlder();
    }
  }

  void _toggle(String id) => setState(() {
    if (!_open.remove(id)) _open.add(id);
  });

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    final items = feed.items;
    if (!feed.loaded) return const Center(child: CircularProgressIndicator());
    final end = _historyEnd ??= feed.latestConfirmedSeq;
    if (items.isEmpty && !widget.working) {
      final p = AppTheme.of(context);
      return Center(
        child: Text(
          S.of(context).chatEmpty,
          style: TextStyle(color: p.faint, fontSize: 14),
        ),
      );
    }
    // Hold the opening boundary fixed. History grows up from it while
    // live messages grow down, keeping scroll offsets on both sides stable.
    final firstLive = items.indexWhere((item) => item.seq > end);
    final split = firstLive < 0 ? items.length : firstLive;
    final indices = {
      for (var i = 0; i < items.length; i++) ValueKey(items[i].id): i,
    };
    // Only the latest stop at the limit can be ticked, and only until the
    // user writes again: what was said after it stands in for carrying on.
    var live = items.lastIndexWhere(
      (item) => CarryOn.stops(item.kind, item.body),
    );
    if (live >= 0 && items.skip(live + 1).any((item) => item.kind == 'user')) {
      live = -1;
    }
    // Times under the user's words and under the agent's last answer to
    // them, not under every answer between its tools; the last turn's only
    // once it has ended, or the time would hop down as it went on.
    final stamped = <int>{};
    var answered = !widget.working;
    for (var i = items.length - 1; i >= 0; i--) {
      final kind = items[i].kind;
      if (kind == 'user') {
        stamped.add(i);
        answered = true;
      } else if (kind == 'text' && answered) {
        stamped.add(i);
        answered = false;
      }
    }
    final scroll = SelectionArea(
      child: CustomScrollView(
        key: ObjectKey(feed),
        controller: _scroll,
        center: _liveStart,
        anchor: 1,
        slivers: [
          SliverPadding(padding: EdgeInsets.only(top: widget.padding.top + 8)),
          SliverList.builder(
            itemCount: split,
            findChildIndexCallback: (key) {
              final i = indices[key];
              return i != null && i < split ? split - 1 - i : null;
            },
            itemBuilder: (context, i) {
              final index = split - 1 - i;
              return _tile(items, index, live, stamped.contains(index));
            },
          ),
          SliverList.builder(
            key: _liveStart,
            itemCount: items.length - split,
            findChildIndexCallback: (key) {
              final i = indices[key];
              return i != null && i >= split ? i - split : null;
            },
            itemBuilder: (context, i) {
              final index = split + i;
              return _tile(items, index, live, stamped.contains(index));
            },
          ),
          SliverToBoxAdapter(
            child: ValueListenableBuilder(
              valueListenable: feed.pieces,
              builder: (context, pieces, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final MapEntry(key: id, value: text) in pieces.entries)
                    _Spaced(
                      key: ValueKey('w$id'),
                      top: 14,
                      child: _Answer(text: text, writing: true),
                    ),
                  if (widget.working && pieces.isEmpty)
                    const _Spaced(top: 14, child: _Working()),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: widget.padding.bottom + widget.bottomOverlap + 12,
            ),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, box) {
        final height = box.maxHeight + widget.bottomOverlap;
        return OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: height,
          maxHeight: height,
          child: scroll,
        );
      },
    );
  }

  /// [list]'s item [i], spaced from the one above it: tools in a run sit
  /// close, as one block of work. With [stamp], when it was said under it.
  Widget _tile(List<ChatItem> list, int i, int live, bool stamp) {
    final item = list[i];
    final above = i > 0 ? list[i - 1] : null;
    final close = above != null && _small(above) && _small(item);
    final at = item.at;
    final files = item.body['files'];
    if ((item.kind == 'text' ||
            (item.kind == 'user' && item.body['sender'] is! Map)) &&
        files is List &&
        files.isNotEmpty &&
        _isPhoto(files.last)) {
      return _Spaced(
        key: ValueKey(item.id),
        top: above == null ? 0 : 8,
        child: _ChatAttachments(
          feed: widget.feed,
          files: files,
          right: item.kind == 'user',
          caption: item.text,
          at: at,
          stamp: stamp,
        ),
      );
    }
    final shown = _shown(item, i, live);
    return _Spaced(
      key: ValueKey(item.id),
      top: above == null ? 0 : (close ? 4 : 14),
      child: stamp && at != null && !_carriedOn(item)
          ? _Stamped(
              at: at,
              right: item.kind == 'user' && item.body['sender'] is! Map,
              child: shown,
            )
          : shown,
    );
  }

  Widget _shown(ChatItem item, int i, int live) => switch (item.kind) {
    'user' when _carriedOn(item) => _Note(
      text: S.of(context).chatCarriedOn,
      error: false,
      icon: Icons.play_arrow_rounded,
    ),
    'user' => _Said(
      text: item.text,
      files: item.body['files'],
      feed: widget.feed,
      sender: item.body['sender'],
    ),
    'text' when item.body['files'] is List => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ChatAttachments(feed: widget.feed, files: item.body['files']),
        if (item.text.isNotEmpty) _Answer(text: item.text),
      ],
    ),
    'text' => _Answer(text: item.text),
    'thinking' => _Thinking(
      text: item.text,
      open: _open.contains(item.id),
      onTap: () => _toggle(item.id),
    ),
    'tool' => _Tool(
      body: item.body,
      open: _open.contains(item.id),
      onTap: () => _toggle(item.id),
    ),
    'ask' when item.body['questions'] is List => _Questions(
      body: item.body,
      onAnswer: (choice, answers) => widget.onAnswer(item.id, choice, answers),
    ),
    'ask' => _Ask(
      body: item.body,
      onAnswer: (choice) => widget.onAnswer(item.id, choice, const {}),
    ),
    // Only the latest stop is drawn whole; those before are a line.
    _ when CarryOn.stops(item.kind, item.body) && i == live => _Limit(
      resets: item.body['resets'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (item.body['resets'] as num).round(),
            )
          : null,
      usage: widget.usage,
      carryOnAt: widget.carryOnAt,
      savingCarryOn: widget.savingCarryOn,
      onTap: widget.onCarry != null ? () => widget.onCarry!(item) : null,
    ),
    _ when CarryOn.stops(item.kind, item.body) => _Note(
      text: S.of(context).chatAtLimit,
      error: false,
      icon: Icons.pause_circle_outline_rounded,
    ),
    _ => _Note(text: item.text, error: item.body['error'] == true),
  };

  static bool _small(ChatItem item) =>
      item.kind == 'tool' || item.kind == 'thinking';

  /// The words a chat is told to carry on with once the limit is lifted:
  /// the app's doing, not the user's, so not drawn as theirs.
  static bool _carriedOn(ChatItem item) =>
      item.kind == 'user' &&
      item.body['sender'] is! Map &&
      item.text.trim() == CarryOn.words;
}

class _TalkScrollController extends ScrollController {
  final bool Function() followsFoot;

  _TalkScrollController(this.followsFoot) : super(keepScrollOffset: false);

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _TalkScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    followsFoot: followsFoot,
  );
}

class _TalkScrollPosition extends ScrollPositionWithSingleContext {
  final bool Function() followsFoot;

  _TalkScrollPosition({
    required super.physics,
    required super.context,
    required super.oldPosition,
    required this.followsFoot,
  }) : super(keepScrollOffset: false);

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    // Set the visible end during layout, before any frame can paint the
    // previous offset. A reader farther up keeps their existing offset.
    if (followsFoot() &&
        (!hasContentDimensions || this.maxScrollExtent != maxScrollExtent) &&
        (pixels - maxScrollExtent).abs() > 0.01) {
      correctPixels(maxScrollExtent);
      return false;
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// "14:05" today, "Yesterday 14:05" or "Nov 20 14:05" before — on the
/// app's clock.
String _when(BuildContext context, DateTime at) {
  final time = Dates.time(at, h24: MediaQuery.alwaysUse24HourFormatOf(context));
  return DateUtils.isSameDay(at, DateTime.now())
      ? time
      : '${Dates.dayWord(at) ?? Dates.shortDay(at)} $time';
}

/// [child] with when it was said under it, faint, on its side: kept out
/// of a selection, so words copied from the chat come without times.
class _Stamped extends StatelessWidget {
  final DateTime at;
  final bool right;
  final Widget child;

  const _Stamped({required this.at, required this.right, required this.child});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Column(
      crossAxisAlignment: right
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        child,
        Padding(
          padding: EdgeInsets.only(top: 4, left: right ? 0 : 2, right: 6),
          child: SelectionContainer.disabled(
            child: Text(
              _when(context, at),
              style: TextStyle(color: p.faint, fontSize: 11.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _Spaced extends StatelessWidget {
  final double top;
  final Widget child;

  const _Spaced({super.key, required this.top, required this.child});

  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(16, top, 16, 0), child: child);
}

/// A chat input from the user, a subscription, or another assistant.
class _Said extends StatelessWidget {
  final String text;
  final Object? files;
  final TalkFeed feed;
  final Object? sender;

  const _Said({
    required this.text,
    required this.feed,
    this.files,
    this.sender,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final from = sender;
    if (from is! Map) {
      return _bubble(
        right: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
          decoration: BoxDecoration(
            color: p.panelHi,
            borderRadius: BorderRadius.circular(18),
          ),
          child: _content(p, right: true),
        ),
      );
    }

    final s = S.of(context);
    final title = '${from['title'] ?? ''}'.trim();
    final event = from['event'] != null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = event
        ? (dark ? const Color(0xFF67C9BF) : const Color(0xFF176B64))
        : (dark ? const Color(0xFFBBA7FF) : const Color(0xFF6248AC));
    final card = Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 11),
      decoration: BoxDecoration(
        color: Color.alphaBlend(accent.withValues(alpha: 0.10), p.panel),
        borderRadius: event
            ? const BorderRadius.all(Radius.circular(16))
            : const BorderRadius.only(
                topLeft: Radius.circular(5),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: event
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                event ? Icons.call_merge : Icons.smart_toy_outlined,
                size: 15,
                color: accent,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  event
                      ? s.chatFromEvent(title)
                      : from['chat'] == null || title.isEmpty
                      ? s.chatFromOutside
                      : s.chatFrom(title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          _content(p, right: false),
        ],
      ),
    );
    return event ? card : _bubble(right: false, child: card);
  }

  Widget _bubble({required bool right, required Widget child}) {
    final alignment = right ? Alignment.centerRight : Alignment.centerLeft;
    return FractionallySizedBox(
      widthFactor: 0.85,
      alignment: alignment,
      child: Align(alignment: alignment, child: child),
    );
  }

  Widget _content(AppPalette p, {required bool right}) {
    final words = Text(
      text,
      style: TextStyle(color: p.text, fontSize: 15, height: 1.35),
    );
    final sent = files;
    if (sent is! List || sent.isEmpty) return words;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: right
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        _ChatAttachments(feed: feed, files: sent, right: right),
        if (text.trim().isNotEmpty) ...[const SizedBox(height: 2), words],
      ],
    );
  }
}

bool _isPhoto(Object? file) =>
    file is Map &&
    file['key'] is String &&
    '${file['mime']}'.startsWith('image/');

class _ChatAttachments extends StatelessWidget {
  final TalkFeed feed;
  final List files;
  final bool right;
  final String caption;
  final DateTime? at;
  final bool stamp;

  const _ChatAttachments({
    required this.feed,
    required this.files,
    this.right = false,
    this.caption = '',
    this.at,
    this.stamp = false,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: right
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start,
    children: [
      for (final (i, file) in files.whereType<Map>().indexed)
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 5),
          child: _isPhoto(file)
              ? _ChatPhoto(
                  key: ValueKey((i, file['key'])),
                  feed: feed,
                  object: file['key'],
                  name: '${file['name']}',
                  right: right,
                  caption: identical(file, files.last) ? caption : '',
                  at: at,
                  stamp: stamp && identical(file, files.last),
                )
              : _FileLabel(
                  name: '${file['name']}',
                  icon: '${file['mime']}'.startsWith('image/')
                      ? Icons.image_outlined
                      : Icons.insert_drive_file_outlined,
                ),
        ),
    ],
  );
}

class _FileLabel extends StatelessWidget {
  final String name;
  final IconData icon;

  const _FileLabel({required this.name, required this.icon});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: p.muted),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.text, fontSize: 13.5),
          ),
        ),
      ],
    );
  }
}

class _ChatPhoto extends StatefulWidget {
  final TalkFeed feed;
  final String object;
  final String name;
  final bool right;
  final String caption;
  final DateTime? at;
  final bool stamp;

  const _ChatPhoto({
    super.key,
    required this.feed,
    required this.object,
    required this.name,
    required this.right,
    required this.caption,
    required this.at,
    required this.stamp,
  });

  @override
  State<_ChatPhoto> createState() => _ChatPhotoState();
}

class _ChatPhotoState extends State<_ChatPhoto> {
  late var _photo = _load();

  Future<({Uint8List bytes, Size size})> _load() async {
    final bytes = await widget.feed.photo(widget.object);
    // Read the dimensions without decoding a full-size image for the preview.
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return (
          bytes: bytes,
          size: Size(descriptor.width.toDouble(), descriptor.height.toDouble()),
        );
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  @override
  void didUpdateWidget(_ChatPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feed != widget.feed || oldWidget.object != widget.object) {
      _photo = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final caption = widget.caption;
    final hasCaption = caption.trim().isNotEmpty;
    final at = widget.at;
    final time = widget.stamp && at != null ? _when(context, at) : null;
    final screen = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return LayoutBuilder(
      builder: (context, box) {
        final bounds = box.loosen().enforce(
          BoxConstraints(
            maxWidth: (screen.width * 0.72).clamp(0.0, 320.0),
            maxHeight: (screen.height * 0.6).clamp(0.0, 440.0),
          ),
        );
        return FutureBuilder(
          future: _photo,
          builder: (context, snapshot) {
            final photo = snapshot.connectionState == ConnectionState.done
                ? snapshot.data
                : null;
            final size = bounds.constrainSizeAndAttemptToPreserveAspectRatio(
              photo == null
                  ? const Size(180, 135)
                  : Size(
                      bounds.maxWidth,
                      bounds.maxWidth / photo.size.aspectRatio,
                    ),
            );
            final stamp = time == null
                ? null
                : SelectionContainer.disabled(
                    child: Text(
                      time,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hasCaption ? p.muted : Colors.white,
                        fontSize: 11.5,
                      ),
                    ),
                  );
            final fallback = Center(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: _FileLabel(
                  name: widget.name,
                  icon: Icons.broken_image_outlined,
                ),
              ),
            );
            final preview = photo != null
                ? InkWell(
                    onTap: () => showPhotoViewer(
                      context,
                      image: MemoryImage(photo.bytes),
                      name: widget.name,
                      caption: caption,
                      time: at == null ? null : _when(context, at),
                    ),
                    child: Image(
                      image: ResizeImage(
                        MemoryImage(photo.bytes),
                        width: (size.width * dpr).ceil().clamp(1, 4096),
                        height: (size.height * dpr).ceil().clamp(1, 4096),
                        policy: ResizeImagePolicy.fit,
                      ),
                      semanticLabel: widget.name,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => fallback,
                    ),
                  )
                : snapshot.hasError
                ? Tooltip(
                    message: MaterialLocalizations.of(
                      context,
                    ).refreshIndicatorSemanticLabel,
                    child: InkWell(
                      onTap: () => setState(() => _photo = _load()),
                      child: fallback,
                    ),
                  )
                : Center(child: Icon(Icons.image_outlined, color: p.faint));

            return Material(
              color: p.panelHi,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: p.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: hasCaption && size.width < 130
                    ? bounds.constrainWidth(130)
                    : size.width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectionContainer.disabled(
                      child: SizedBox(
                        height: size.height,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            preview,
                            if (!hasCaption && stamp != null)
                              Positioned(
                                right: 6,
                                bottom: 6,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: (size.width - 12).clamp(
                                      0,
                                      double.infinity,
                                    ),
                                  ),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 3,
                                      ),
                                      child: stamp,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (hasCaption)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.right)
                              Text(
                                caption,
                                style: TextStyle(
                                  color: p.text,
                                  fontSize: 15,
                                  height: 1.35,
                                ),
                              )
                            else
                              _Answer(text: caption),
                            if (stamp != null)
                              Align(
                                alignment: Alignment.centerRight,
                                child: stamp,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// The agent's words, across the width; [writing] while they come.
class _Answer extends StatelessWidget {
  final String text;
  final bool writing;

  const _Answer({required this.text, this.writing = false});

  @override
  Widget build(BuildContext context) =>
      MarkdownText(writing ? '$text ▍' : text);
}

class _Thinking extends StatelessWidget {
  final String text;
  final bool open;
  final VoidCallback onTap;

  const _Thinking({
    required this.text,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Line(
          icon: Icons.psychology_outlined,
          name: S.of(context).chatThinking,
          line: open ? '' : text.split('\n').first,
          onTap: onTap,
          open: open,
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 4, 0, 2),
            child: Text(
              text,
              style: TextStyle(
                color: p.muted,
                fontSize: 13.5,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}

/// A tool the agent used: its name and what it was asked to do on one
/// line, a mark for how it went, and under it, opened, the whole of it and
/// what came back.
class _Tool extends StatelessWidget {
  final Map<String, dynamic> body;
  final bool open;
  final VoidCallback onTap;

  const _Tool({required this.body, required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final done = body['done'] == true;
    final failed = body['failed'] == true;
    final detail = '${body['detail'] ?? ''}'.trim();
    final output = '${body['output'] ?? ''}'.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Line(
          icon: _iconOf('${body['name']}'),
          name: '${body['name']}',
          line: '${body['line'] ?? ''}',
          onTap: detail.isEmpty && output.isEmpty ? null : onTap,
          open: open,
          trailing: !done
              ? SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: p.muted,
                  ),
                )
              : failed
              ? Icon(
                  Icons.error_outline_rounded,
                  size: 15,
                  color: AppColors.danger,
                )
              : null,
        ),
        if (open && (detail.isNotEmpty || output.isNotEmpty))
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 6, 0, 2),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                color: p.panel,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    [
                      if (detail.isNotEmpty) detail,
                      if (output.isNotEmpty) output,
                    ].join('\n\n'),
                    style: TextStyle(
                      fontFamily: MarkdownText.mono,
                      fontSize: 11.5,
                      height: 1.4,
                      color: failed ? AppColors.danger : p.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static IconData _iconOf(String name) => switch (name) {
    'Bash' || 'Shell' => Icons.terminal_rounded,
    'Read' => Icons.description_outlined,
    'Write' || 'Edit' || 'NotebookEdit' => Icons.edit_outlined,
    'Glob' || 'Grep' => Icons.search_rounded,
    'WebFetch' || 'WebSearch' || 'Search' => Icons.public_rounded,
    'Task' || 'Agent' => Icons.call_split_rounded,
    'TodoWrite' => Icons.checklist_rounded,
    'Skill' => Icons.auto_awesome_outlined,
    _ => Icons.build_outlined,
  };
}

/// One line of work: an icon, a name, what it was about, cut to the width.
class _Line extends StatelessWidget {
  final IconData icon;
  final String name;
  final String line;
  final VoidCallback? onTap;
  final bool open;
  final Widget? trailing;

  const _Line({
    required this.icon,
    required this.name,
    required this.line,
    required this.onTap,
    required this.open,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: 16, color: p.faint),
            const SizedBox(width: 10),
            Text(
              name,
              style: TextStyle(
                color: p.muted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.faint,
                  fontSize: 12,
                  fontFamily: MarkdownText.mono,
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            if (onTap != null)
              Icon(
                open
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: p.faint,
              ),
          ],
        ),
      ),
    );
  }
}

/// A question of permission: what the agent wants to do, and the buttons
/// to say — until it is answered, then what was said.
class _Ask extends StatelessWidget {
  final Map<String, dynamic> body;
  final ValueChanged<String> onAnswer;

  const _Ask({required this.body, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final answer = body['answer'] as String?;
    final choices = [
      for (final c in body['choices'] as List? ?? const []) '$c',
    ];
    final detail = '${body['detail'] ?? ''}'.trim();
    void say(String choice) {
      HapticFeedback.selectionClick();
      onAnswer(choice);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: answer == null
              ? AppColors.overdue.withValues(alpha: 0.6)
              : p.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${body['tool']}',
            style: TextStyle(
              color: p.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if ('${body['line'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${body['line']}',
              style: TextStyle(
                color: p.muted,
                fontSize: 12.5,
                fontFamily: MarkdownText.mono,
                height: 1.4,
              ),
            ),
          ],
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Text(
                  detail,
                  style: TextStyle(
                    color: p.faint,
                    fontSize: 11.5,
                    fontFamily: MarkdownText.mono,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          if (answer != null)
            Text(switch (answer) {
              'allow' => s.chatAllowed,
              'always' => s.chatAlwaysAllowed,
              _ => s.chatDenied,
            }, style: TextStyle(color: p.faint, fontSize: 13))
          else
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: [
                if (choices.contains('deny'))
                  OutlinedButton(
                    onPressed: () => say('deny'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.text,
                      side: BorderSide(color: p.border),
                    ),
                    child: Text(s.chatDeny),
                  ),
                if (choices.contains('always'))
                  TextButton(
                    onPressed: () => say('always'),
                    style: TextButton.styleFrom(foregroundColor: p.muted),
                    child: Text(s.chatAlways),
                  ),
                FilledButton(
                  onPressed: () => say('allow'),
                  style: FilledButton.styleFrom(
                    backgroundColor: p.text,
                    foregroundColor: p.bg,
                  ),
                  child: Text(s.chatAllow),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Questions the agent asks the user (Claude's AskUserQuestion): each
/// with its options to tap, one or any, and Other… for words of one's
/// own; Answer once every question has one. Answered, what was said.
class _Questions extends StatefulWidget {
  final Map<String, dynamic> body;
  final void Function(String choice, Map<String, String> answers) onAnswer;

  const _Questions({required this.body, required this.onAnswer});

  @override
  State<_Questions> createState() => _QuestionsState();
}

class _QuestionsState extends State<_Questions> {
  /// Options picked, and words typed, by each question's place.
  final _picked = <int, Set<String>>{};
  final _typed = <int, String>{};

  List<Map> get _questions => [
    for (final q in widget.body['questions'] as List? ?? const [])
      if (q is Map) q,
  ];

  static List<Map> _options(Map q) => [
    for (final o in q['options'] as List? ?? const [])
      if (o is Map) o,
  ];

  /// What is said to question [i]: the options picked in their own order,
  /// then the words typed; several joined as Claude's terminal joins them.
  String _answerOf(int i) {
    final picked = _picked[i] ?? const {};
    return [
      for (final o in _options(_questions[i]))
        if (picked.contains('${o['label']}')) '${o['label']}',
      if ((_typed[i] ?? '').trim().isNotEmpty) _typed[i]!.trim(),
    ].join(', ');
  }

  void _pick(int i, String label) {
    HapticFeedback.selectionClick();
    setState(() {
      final picked = _picked.putIfAbsent(i, () => {});
      if (_questions[i]['multiSelect'] == true) {
        if (!picked.remove(label)) picked.add(label);
      } else {
        // One answer: an option takes the place of words typed.
        _typed.remove(i);
        picked
          ..clear()
          ..add(label);
      }
    });
  }

  Future<void> _other(int i) async {
    final got = await showDialog<String>(
      context: context,
      builder: (ctx) => _OtherAnswer(
        question: '${_questions[i]['question']}',
        typed: _typed[i] ?? '',
      ),
    );
    if (got == null || !mounted) return;
    setState(() {
      if (got.trim().isEmpty) {
        _typed.remove(i);
      } else {
        _typed[i] = got.trim();
        // One answer: words typed take the place of an option.
        if (_questions[i]['multiSelect'] != true) _picked.remove(i);
      }
    });
  }

  void _say(String choice) {
    HapticFeedback.selectionClick();
    widget.onAnswer(choice, {
      if (choice == 'answer')
        for (var i = 0; i < _questions.length; i++)
          '${_questions[i]['question']}': _answerOf(i),
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final questions = _questions;
    final answer = widget.body['answer'] as String?;
    final answers = widget.body['answers'] as Map? ?? const {};
    final ready = [
      for (var i = 0; i < questions.length; i++) _answerOf(i),
    ].every((a) => a.isNotEmpty);

    Widget question(int i) {
      final q = questions[i];
      final header = '${q['header'] ?? ''}';
      final many = q['multiSelect'] == true;
      final picked = _picked[i] ?? const {};
      final typed = _typed[i];
      final said = answers['${q['question']}'];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header.isNotEmpty || (many && answer == null))
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                [
                  if (header.isNotEmpty) header.toUpperCase(),
                  if (many && answer == null) s.chatPickAny,
                ].join(' · '),
                style: TextStyle(
                  color: p.faint,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          Text(
            '${q['question']}',
            style: TextStyle(
              color: p.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          if (answer != null)
            Text(
              said == null || '$said'.isEmpty ? s.chatNotAnswered : '$said',
              style: TextStyle(
                color: said == null ? p.faint : p.muted,
                fontSize: 13.5,
                height: 1.35,
              ),
            )
          else ...[
            for (final o in _options(q))
              _Option(
                label: '${o['label']}',
                description: '${o['description'] ?? ''}',
                many: many,
                picked: picked.contains('${o['label']}'),
                onTap: () => _pick(i, '${o['label']}'),
              ),
            _Option(
              label: typed ?? s.chatOther,
              description: '',
              many: many,
              picked: typed != null,
              onTap: () => _other(i),
            ),
          ],
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: answer == null
              ? AppColors.overdue.withValues(alpha: 0.6)
              : p.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < questions.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            question(i),
          ],
          if (answer == null) ...[
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton(
                  onPressed: () => _say('deny'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.text,
                    side: BorderSide(color: p.border),
                  ),
                  child: Text(s.chatSkip),
                ),
                FilledButton(
                  onPressed: ready ? () => _say('answer') : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: p.text,
                    foregroundColor: p.bg,
                    disabledBackgroundColor: p.border,
                    disabledForegroundColor: p.faint,
                  ),
                  child: Text(s.chatAnswer),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Words of one's own for a question; its field kept until the dialog
/// has gone, as it is drawn while it fades.
class _OtherAnswer extends StatefulWidget {
  final String question;
  final String typed;

  const _OtherAnswer({required this.question, required this.typed});

  @override
  State<_OtherAnswer> createState() => _OtherAnswerState();
}

class _OtherAnswerState extends State<_OtherAnswer> {
  late final _field = TextEditingController(text: widget.typed);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AlertDialog(
      title: Text(widget.question),
      content: TextField(
        controller: _field,
        autofocus: true,
        minLines: 1,
        maxLines: 5,
        decoration: InputDecoration(hintText: s.chatOtherHint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _field.text),
          child: Text(s.save),
        ),
      ],
    );
  }
}

/// One of a question's options: a round mark for one answer, a square
/// for any, filled when picked; its description under it.
class _Option extends StatelessWidget {
  final String label;
  final String description;
  final bool many;
  final bool picked;
  final VoidCallback onTap;

  const _Option({
    required this.label,
    required this.description,
    required this.many,
    required this.picked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: picked ? p.panelHi : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: picked ? p.muted : p.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    many
                        ? (picked
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded)
                        : (picked
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded),
                    size: 18,
                    color: picked ? p.text : p.faint,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 13.5,
                          height: 1.35,
                        ),
                      ),
                      if (description.isNotEmpty && description != label)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            description,
                            style: TextStyle(
                              color: p.faint,
                              fontSize: 12,
                              height: 1.35,
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
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final bool error;
  final IconData? icon;

  const _Note({required this.text, required this.error, this.icon});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final colour = error ? AppColors.danger : p.faint;
    final words = Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(color: colour, fontSize: 12.5, height: 1.4),
    );
    if (icon == null) return words;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 14, color: colour),
        const SizedBox(width: 5),
        Flexible(child: words),
      ],
    );
  }
}

/// The latest turn the account's limit refused: a card saying which limit
/// and when it resets, and a switch to have the chat carry on by itself
/// once it has — off unless the user turns it on.
class _Limit extends StatelessWidget {
  final DateTime? resets;
  final ChatUsage? usage;
  final DateTime? carryOnAt;
  final bool savingCarryOn;

  /// Null where its worker can't leave messages for later.
  final VoidCallback? onTap;

  const _Limit({
    required this.resets,
    required this.usage,
    required this.carryOnAt,
    required this.savingCarryOn,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final brief = limitBrief(context, usage, resets: resets);
    final at = carryOnAt;
    final status = at == null
        ? null
        : at.isAfter(DateTime.now())
        ? s.chatCarryOnScheduled(_when(context, at))
        : s.chatCarryOnWaiting;
    final toggle = savingCarryOn ? null : onTap;
    return SelectionContainer.disabled(
      // A Material, so the switch's row inks on it.
      child: Material(
        color: p.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.pause_circle_outline_rounded,
                    size: 20,
                    color: p.muted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.chatLimitTitle,
                          style: TextStyle(
                            color: p.text,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (brief != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              brief,
                              style: TextStyle(color: p.muted, fontSize: 12.5),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null || status != null) ...[
              Divider(height: 1, thickness: 1, color: p.border),
              InkWell(
                onTap: toggle,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          liveRegion: status != null,
                          child: Text(
                            status ??
                                (resets == null
                                    ? s.chatCarryOnSoon
                                    : s.chatCarryOnReset),
                            style: TextStyle(color: p.text, fontSize: 14),
                          ),
                        ),
                      ),
                      if (onTap != null) ...[
                        const SizedBox(width: 8),
                        if (savingCarryOn)
                          const SizedBox(
                            width: 52,
                            height: 40,
                            child: Center(
                              child: SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          )
                        else
                          Switch(
                            value: at != null,
                            onChanged: toggle == null ? null : (_) => toggle(),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// While a turn is under way and nothing is being written: a small spinner
/// and the word.
class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Row(
      children: [
        SizedBox.square(
          dimension: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: p.muted),
        ),
        const SizedBox(width: 10),
        Text(
          S.of(context).chatWorking,
          style: TextStyle(color: p.faint, fontSize: 13),
        ),
      ],
    );
  }
}

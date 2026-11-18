import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'desk.dart';

/// A strip blurred more and more across its height: not at all at one
/// edge, [most] at the other, and held at [most] for the last [hold] of it.
///
/// A blur can't be faded in by a gradient (masked, a blur drew nothing at
/// all here). So it is [_steps] thin bands of plain blur side by side, each
/// a little stronger than the one before, too little to see where one
/// meets the next. The bands read one copy of the screen between them
/// ([BackdropGroup]), so each blurs what is really under it, for one read.
///
/// A shader blurring each row by its own amount came before, across and
/// then down as two filters. On the phone the second read the screen as it
/// was rather than what the first had made of it, so only one direction
/// ever showed: unseen under the tab bar, streaks under a screen's head.
class GradedBlur extends StatelessWidget {
  /// The blur's sigma at its strongest.
  final double most;

  /// Whether it is clear at the top and strongest at the foot, or the other
  /// way up.
  final bool downwards;

  /// How much of the strip, at its strong end, is at [most] throughout.
  final double hold;

  const GradedBlur({
    super.key,
    required this.most,
    this.downwards = true,
    this.hold = 0,
  });

  static const _steps = 16;

  @override
  Widget build(BuildContext context) {
    Widget band(double top, double height, double sigma) => Positioned(
      left: 0,
      right: 0,
      top: top,
      height: height,
      child: ClipRect(
        child: BackdropFilter.grouped(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: const SizedBox.expand(),
        ),
      ),
    );
    return IgnorePointer(
      child: BackdropGroup(
        child: LayoutBuilder(
          builder: (context, box) {
            final whole = box.maxHeight;
            final held = math.min(hold, whole);
            final step = (whole - held) / _steps;
            return Stack(
              children: [
                if (held > 0) band(downwards ? whole - held : 0, held, most),
                for (var i = 0; i < _steps; i++)
                  band(
                    downwards ? i * step : whole - (i + 1) * step,
                    step,
                    // Eased in, so the first bands are too faint to be
                    // told from what is outside the strip.
                    most * math.pow((i + 0.5) / _steps, 2),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// How much of a screen's top its head covers, which a scroll under
/// [GlassTop] starts with as room, as it ends with the tab bar's. None
/// outside one.
class HeadRoom extends InheritedWidget {
  final double height;

  const HeadRoom({super.key, required this.height, required super.child});

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HeadRoom>()?.height ?? 0;

  @override
  bool updateShouldNotify(HeadRoom old) => height != old.height;
}

/// A screen whose top — the phone's status bar, the header, a row of groups
/// under it — stands on frosted glass over what scrolls up beneath it, as
/// the tab bar does at the foot. What passes under is blurred and dimmed
/// into the ground, the blur thinning out towards the head's foot so there
/// is no edge where the glass ends. A list cut off square at the header's
/// foot, and running sharp under the groups, was asked to be blurred.
///
/// The body is laid out the full height and given the head's height as
/// [HeadRoom] in the same frame. A desktop's wide window has no status bar
/// and lays the head above the body as before.
class GlassTop extends StatelessWidget {
  final Widget head;
  final Widget body;

  const GlassTop({super.key, required this.head, required this.body});

  /// The tab bar's frost, so the two ends of the screen are one glass.
  static const blur = 17.0;

  /// How much of the ground is laid over the blur, so the title reads over
  /// whatever passes under it.
  static const fill = 0.65;

  /// How far up from the head's foot the blur takes to come to its full:
  /// a third of the head, within bounds. Over 24 points, under the groups,
  /// the blur's start showed as a line across the cards; 44 under a head
  /// with only a title left the title over rows hardly blurred at all.
  static double leadOf(double head) => (head / 3).clamp(16.0, 44.0);

  @override
  Widget build(BuildContext context) {
    if (Desk.wideOf(context)) {
      return Column(
        children: [
          head,
          Expanded(child: body),
        ],
      );
    }
    final status = MediaQuery.paddingOf(context).top;
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: CustomMultiChildLayout(
        delegate: _GlassLayout(),
        children: [
          LayoutId(
            id: _Part.body,
            child: LayoutBuilder(
              builder: (context, box) =>
                  HeadRoom(height: (box as _UnderHead).head, child: body),
            ),
          ),
          LayoutId(id: _Part.glass, child: const _Glass()),
          // Taps on the head stay there rather than reaching a card blurred
          // under it.
          LayoutId(
            id: _Part.head,
            child: ColoredBox(
              color: Colors.transparent,
              child: Padding(
                padding: EdgeInsets.only(top: status),
                child: head,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Part { body, glass, head }

/// The head at its own height, then the body the full height told how much
/// of it the head covers, then the glass under the head.
class _GlassLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final head = layoutChild(
      _Part.head,
      BoxConstraints(
        minWidth: size.width,
        maxWidth: size.width,
        maxHeight: size.height,
      ),
    ).height;
    layoutChild(_Part.body, _UnderHead(size, head));
    layoutChild(_Part.glass, BoxConstraints.tight(Size(size.width, head)));
    for (final part in _Part.values) {
      positionChild(part, Offset.zero);
    }
  }

  @override
  bool shouldRelayout(_GlassLayout old) => false;
}

/// The body's constraints, carrying the head's height to the body's
/// builder within the same layout — as the `Scaffold` hands its body the
/// app bar's.
class _UnderHead extends BoxConstraints {
  final double head;

  _UnderHead(super.size, this.head) : super.tight();

  @override
  bool operator ==(Object other) =>
      other is _UnderHead && super == other && other.head == head;

  @override
  int get hashCode => Object.hash(super.hashCode, head);
}

/// The glass itself: a full blur down to [GlassTop.leadOf] above the head's
/// foot, then thinning to none at it, with the ground laid over in step.
class _Glass extends StatelessWidget {
  const _Glass();

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          final height = box.maxHeight;
          final full = math.max(0.0, height - GlassTop.leadOf(height));
          return Stack(
            children: [
              Positioned.fill(
                child: GradedBlur(
                  most: GlassTop.blur,
                  downwards: false,
                  hold: full,
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        p.bg.withValues(alpha: GlassTop.fill),
                        p.bg.withValues(alpha: GlassTop.fill),
                        p.bg.withValues(alpha: 0),
                      ],
                      stops: [0, height > 0 ? full / height : 0, 1],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

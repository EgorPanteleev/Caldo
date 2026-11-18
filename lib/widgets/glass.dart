import 'dart:math' as math;
import 'dart:ui' show FragmentProgram, ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'desk.dart';

/// A strip blurred more and more across its height, from [least] at one
/// edge to [most] at the other, and held at [most] for the last [hold] of
/// it, in [steps] bands of plain blur side by side.
///
/// A blur can't be faded in by a gradient (masked, a blur drew nothing at
/// all here); hence bands. They read one copy of the screen between them
/// ([BackdropGroup]), so each blurs what is really under it. Each band is
/// a blur of its own, and they are what this costs: sixteen of them under
/// a head and sixteen under the tab bar dropped frames. Few bands show
/// their edges where the blur is light and type can still be read, so a
/// strip that starts from none starts with a [FadingBlur] below [least].
class GradedBlur extends StatelessWidget {
  /// The blur's sigma at its strongest.
  final double most;

  /// The blur's sigma at its lightest; none if zero.
  final double least;

  /// Whether it is lightest at the top and strongest at the foot, or the
  /// other way up.
  final bool downwards;

  /// How much of the strip, at its strong end, is at [most] throughout.
  final double hold;

  /// How many bands the blur grows in.
  final int steps;

  const GradedBlur({
    super.key,
    required this.most,
    this.least = 0,
    this.downwards = true,
    this.hold = 0,
    this.steps = 4,
  });

  /// The blur of the [i]th band from the light end: from [least], each a
  /// like part stronger than the last, which is how a change of blur is
  /// seen; eased in from nothing, when that is where it starts.
  double _sigma(int i) => least > 0
      ? least * math.pow(most / least, (i + 1) / (steps + 1))
      : most * math.pow((i + 0.5) / steps, 2);

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
            final step = (whole - held) / steps;
            return Stack(
              children: [
                if (held > 0) band(downwards ? whole - held : 0, held, most),
                for (var i = 0; i < steps; i++)
                  band(
                    downwards ? i * step : whole - (i + 1) * step,
                    step,
                    _sigma(i),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A light blur growing from none at one edge of a strip to [most] at the
/// other, in one pass of a shader (`shaders/fading_blur.frag`) that blurs
/// each row by its own amount, so it has no steps at all. It blurs up and
/// down only: a second pass across, after it, read the screen as it was
/// rather than what this one made of it, and never showed. Too light to
/// see that here; a strong one smeared type into streaks. A renderer
/// without shader filters (the desktop's) gets [GradedBlur]'s bands.
class FadingBlur extends StatefulWidget {
  /// The blur's sigma at its strongest.
  final double most;

  /// Whether it is clear at the top and strongest at the foot, or the other
  /// way up.
  final bool downwards;

  const FadingBlur({super.key, required this.most, this.downwards = true});

  static Future<FragmentProgram>? _loading;
  static FragmentProgram? _program;

  @override
  State<FadingBlur> createState() => _FadingBlurState();
}

class _FadingBlurState extends State<FadingBlur> {
  @override
  void initState() {
    super.initState();
    if (FadingBlur._program == null && ImageFilter.isShaderFilterSupported) {
      (FadingBlur._loading ??= FragmentProgram.fromAsset(
        'shaders/fading_blur.frag',
      )).then((program) {
        FadingBlur._program = program;
        if (mounted) setState(() {});
      }, onError: (_) {});
    }
  }

  /// Where the strip is on the screen, in pixels: the shader is handed the
  /// screen's coordinates, not the strip's. Read after each layout.
  double _top = 0, _foot = 0;

  void _place(Duration _) {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final top = box.localToGlobal(Offset.zero).dy * ratio;
    final foot = top + box.size.height * ratio;
    if (top != _top || foot != _foot) {
      setState(() {
        _top = top;
        _foot = foot;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ImageFilter.isShaderFilterSupported) {
      return GradedBlur(
        most: widget.most,
        downwards: widget.downwards,
        steps: 8,
      );
    }
    final program = FadingBlur._program;
    if (program != null) WidgetsBinding.instance.addPostFrameCallback(_place);
    // Nothing until the shader is in and it is known where the strip is.
    if (program == null || _foot <= _top) return const SizedBox.expand();
    final shader = program.fragmentShader()
      ..setFloat(2, widget.most * MediaQuery.devicePixelRatioOf(context))
      ..setFloat(3, widget.downwards ? _top : _foot)
      ..setFloat(4, widget.downwards ? _foot : _top);
    return IgnorePointer(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.shader(shader),
          child: const SizedBox.expand(),
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
/// foot, then thinning to none at it — in a few bands while it is strong,
/// then smoothly ([FadingBlur]) while it is light enough for steps to show
/// — with the ground laid over in step.
class _Glass extends StatelessWidget {
  const _Glass();

  /// Where the bands hand over to the smooth part.
  static const _light = 2.0;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          final height = box.maxHeight;
          final lead = math.min(height, GlassTop.leadOf(height));
          final full = height - lead;
          return Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: full + lead / 2,
                child: GradedBlur(
                  most: GlassTop.blur,
                  least: _light,
                  downwards: false,
                  hold: full,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: full + lead / 2,
                bottom: 0,
                child: const FadingBlur(most: _light, downwards: false),
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

part of 'settings_screen.dart';

/// Settings › Appearance › Surfaces: the glass, the grain and the cards,
/// each on a slider shown on the app as it moves and kept when let go,
/// under a little screen drawn with them — the page itself has no glass
/// over it to judge a blur by.
List<Widget> _surfaces(BuildContext context, SettingsProvider settings, S s) {
  final look = settings.look;
  final background = settings.background;
  String share(double v) => '${(v * 100).round()}%';
  String plain(double v) => v.round().toString();
  _LookSlider slider({
    required IconData icon,
    required String title,
    required double Function(Look) read,
    required Look Function(Look, double) write,
    required double most,
    double least = 0,
    int? divisions,
    String Function(double)? reads,
  }) => _LookSlider(
    icon: icon,
    title: title,
    value: read(look),
    stock: read(Look.defaults),
    least: least,
    most: most,
    divisions: divisions,
    reads: reads ?? share,
    onTry: (v) => settings.tryLook(write(settings.look, v)),
    onKeep: (v) => settings.update(look: write(settings.look, v)),
  );
  return [
    const _SurfacesPreview(),
    _Group(
      label: s.lookGlass.toUpperCase(),
      children: [
        slider(
          icon: Icons.blur_on_rounded,
          title: s.lookBlur,
          read: (l) => l.blur,
          write: (l, v) => l.copyWith(blur: v),
          most: 40,
          divisions: 40,
          reads: plain,
        ),
        slider(
          icon: Icons.gradient_rounded,
          title: s.lookGlassFill,
          read: (l) => l.glassFill,
          write: (l, v) => l.copyWith(glassFill: v),
          most: 1.5,
          divisions: 30,
        ),
      ],
    ),
    _Group(
      label: s.backgroundGrain.toUpperCase(),
      children: [
        slider(
          icon: Icons.grain_rounded,
          title: s.lookGrainSize,
          read: (l) => l.grainSize,
          write: (l, v) => l.copyWith(grainSize: v),
          least: 1,
          most: 8,
          divisions: 7,
          reads: (v) => '${v.round()}×',
        ),
        _LookSlider(
          icon: Icons.texture_rounded,
          title: s.lookGroundGrain,
          value: background.noise.toDouble(),
          stock: PaletteBackground.defaults.noise.toDouble(),
          most: 100,
          divisions: 100,
          reads: (v) => '${v.round()}%',
          onTry: (v) => settings.tryBackground(
            settings.background.copyWith(noise: v.round()),
          ),
          onKeep: (v) => settings.update(
            background: settings.background.copyWith(noise: v.round()),
          ),
        ),
        slider(
          icon: Icons.auto_awesome_outlined,
          title: s.lookCardGrain,
          read: (l) => l.cardGrain,
          write: (l, v) => l.copyWith(cardGrain: v),
          most: 4,
          divisions: 40,
        ),
      ],
    ),
    _Group(
      label: s.lookCards.toUpperCase(),
      children: [
        slider(
          icon: Icons.opacity_rounded,
          title: s.lookCardInk,
          read: (l) => l.cardInk,
          write: (l, v) => l.copyWith(cardInk: v),
          most: 2.5,
          divisions: 50,
        ),
        slider(
          icon: Icons.check_box_outlined,
          title: s.lookDoneInk,
          read: (l) => l.doneInk,
          write: (l, v) => l.copyWith(doneInk: v),
          most: 4,
          divisions: 40,
        ),
        slider(
          icon: Icons.crop_square_rounded,
          title: s.lookCardRim,
          read: (l) => l.cardRim,
          write: (l, v) => l.copyWith(cardRim: v),
          most: 1.75,
          divisions: 35,
        ),
        slider(
          icon: Icons.rounded_corner_rounded,
          title: s.lookCorners,
          read: (l) => l.corners,
          write: (l, v) => l.copyWith(corners: v),
          most: 28,
          divisions: 28,
          reads: plain,
        ),
      ],
    ),
    _Group(
      children: [
        _Row(
          icon: Icons.restart_alt_rounded,
          title: s.lookReset,
          onTap:
              look.isDefault &&
                  background.noise == PaletteBackground.defaults.noise
              ? null
              : () => settings.update(
                  look: Look.defaults,
                  background: background.copyWith(
                    noise: PaletteBackground.defaults.noise,
                  ),
                ),
        ),
      ],
    ),
  ];
}

/// A screen in small, drawn as the look stands: a head on the glass over
/// the top of two cards, one open and one done, on the ground.
class _SurfacesPreview extends StatelessWidget {
  const _SurfacesPreview();

  static const _open = Color(0xFF7B61E8);
  static const _done = Color(0xFF35A06A);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final look = Look.current;
    Widget card(String title, Color colour, {bool done = false}) => Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: CardPane(
        ink: colour.withValues(
          alpha: done
              ? TaskCard.doneInkOf(TaskCard.doneInk)
              : TaskCard.inkOf(TaskCard.ink),
        ),
        frost: TaskCard.frostOf(done ? 0 : 1),
      ),
      foregroundDecoration: BoxDecoration(
        border: Border.all(
          color: TaskCard.rimOf(colour, faded: done),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(TaskCard.radius),
      ),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: done ? p.muted : p.text,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          decoration: done ? TextDecoration.lineThrough : null,
        ),
      ),
    );
    const head = 46.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 156,
          child: Stack(
            children: [
              Positioned.fill(
                child: BackgroundSurface(
                  color: p.bg,
                  child: const SizedBox.expand(),
                ),
              ),
              // Under the head's foot, so the blur has something to blur.
              Positioned(
                left: 0,
                right: 0,
                top: head - 26,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    card(s.lookSampleTask, _open),
                    card(s.lookSampleNext, AppTheme.accentOf(context).color),
                    card(s.lookSampleDone, _done, done: true),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: head,
                child: ClipRect(
                  child: BackdropFilter(
                    enabled: look.blur > 0,
                    filter: ImageFilter.blur(
                      sigmaX: look.blur,
                      sigmaY: look.blur,
                    ),
                    child: ColoredBox(
                      color: p.bg.withValues(alpha: GlassTop.fill),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            s.schedule,
                            style: TextStyle(
                              color: p.text,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
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

/// One number of the look on a slider: put in force as it moves
/// ([onTry]), kept when let go ([onKeep]), with a way back to as built.
class _LookSlider extends StatelessWidget {
  final IconData icon;
  final String title;
  final double value, stock, least, most;
  final int? divisions;
  final String Function(double) reads;
  final ValueChanged<double> onTry;
  final ValueChanged<double> onKeep;

  const _LookSlider({
    required this.icon,
    required this.title,
    required this.value,
    required this.stock,
    this.least = 0,
    required this.most,
    this.divisions,
    required this.reads,
    required this.onTry,
    required this.onKeep,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final moved = value != stock;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(width: 24, child: Icon(icon, size: 21, color: p.muted)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                reads(value),
                style: TextStyle(
                  color: moved ? p.text : p.muted,
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              // Its room kept while there is nothing to undo, so the
              // reading does not jump.
              SizedBox(
                width: 44,
                height: 44,
                child: moved
                    ? IconButton(
                        icon: Icon(
                          Icons.undo_rounded,
                          size: 20,
                          color: p.muted,
                        ),
                        tooltip: S.of(context).lookReset,
                        onPressed: () => onKeep(stock),
                      )
                    : null,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: _Row.textStart - 16 - 16),
            child: Semantics(
              label: title,
              child: Slider(
                value: value.clamp(least, most),
                min: least,
                max: most,
                divisions: divisions,
                onChanged: onTry,
                onChangeEnd: onKeep,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

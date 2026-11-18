part of 'settings_screen.dart';

/// Settings › Debug, an admin's only: the app's colours tried on the device
/// (`Tweaks`), the keyboard's numbers, which were a long press on the
/// title alone, and how hard the app is working (`PerfHud`). English only, like the numbers.
List<Widget> _debug(BuildContext context, SettingsProvider settings, S s) => [
  _DebugRows(accent: settings.accent),
];

/// What the list says of the page.
String _debugValue() {
  final t = Tweaks.instance;
  if (!t.on) return 'Off';
  return t.count == 0 ? 'On, nothing changed' : 'On, ${t.count} changed';
}

class _DebugRows extends StatelessWidget {
  /// The accent Appearance has chosen, which the accent's rows start from.
  final AppAccent accent;

  const _DebugRows({required this.accent});

  @override
  Widget build(BuildContext context) {
    final tweaks = Tweaks.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        tweaks,
        KeyboardGap.showNumbers,
        PerfHud.shown,
        PerfHud.graphs,
      ]),
      builder: (context, _) {
        // The theme on screen first: the other's colours are set blind.
        final dark = Theme.of(context).brightness == Brightness.dark;
        Widget side(String side, AppPalette stock) => _Group(
          label: side == 'dark' ? 'Dark theme' : 'Light theme',
          children: [
            for (final (field, name) in Tweaks.palette)
              _ColourRow(
                tweak: '$side.$field',
                title: name,
                stock: Tweaks.stockOf(stock, field),
              ),
          ],
        );
        return Column(
          children: [
            _Group(
              footnote:
                  'Kept on this device only, not backed up or synced. Off '
                  'puts everything back as shipped; signing out turns it '
                  'off. The home-screen widget, the reminder cover and the '
                  'system bars before the app opens keep their own colours.',
              children: [
                _SwitchRow(
                  icon: Icons.bug_report_outlined,
                  title: 'Debug mode',
                  hint: _debugValue(),
                  value: tweaks.on,
                  onChanged: tweaks.setOn,
                ),
                if (!onDesktop)
                  _SwitchRow(
                    icon: Icons.keyboard_outlined,
                    title: 'Keyboard numbers',
                    hint: 'Shown above the add field',
                    value: KeyboardGap.showNumbers.value,
                    onChanged: (on) => KeyboardGap.showNumbers.value = on,
                  ),
              ],
            ),
            _Group(
              label: 'Performance',
              footnote:
                  'Only while Debug mode is on. Judge them on a release build only. Frame times are of '
                  'the last two seconds, average/longest; CPU is of one core '
                  '(two busy cores are 200%). GPU shows where the system '
                  'lets an app read it, which most phones do not; raster '
                  'time stands for it then. The box can be dragged.',
              children: [
                // Greyed, not switched off, while Debug mode is: each
                // keeps its place for when it comes back on.
                for (final row in [
                  _SwitchRow(
                    icon: Icons.speed_rounded,
                    title: 'Performance numbers',
                    hint: 'FPS, frame times, CPU, memory, GPU',
                    value: PerfHud.shown.value,
                    enabled: tweaks.on,
                    onChanged: (on) => PerfHud.shown.value = on,
                  ),
                  _SwitchRow(
                    icon: Icons.stacked_line_chart_rounded,
                    title: 'Frame graphs',
                    hint: "Flutter's own, UI and raster threads",
                    value: PerfHud.graphs.value,
                    enabled: tweaks.on,
                    onChanged: (on) => PerfHud.graphs.value = on,
                  ),
                ])
                  Opacity(opacity: tweaks.on ? 1 : 0.4, child: row),
              ],
            ),
            if (tweaks.on) ...[
              if (dark) ...[
                side('dark', AppPalette.dark),
                side('light', AppPalette.light),
              ] else ...[
                side('light', AppPalette.light),
                side('dark', AppPalette.dark),
              ],
              _Group(
                label: 'Accent',
                footnote:
                    'Over whichever accent Appearance has chosen, '
                    'in both themes.',
                children: [
                  _ColourRow(
                    tweak: 'accent.color',
                    title: 'Accent',
                    stock: accent.color,
                  ),
                  _ColourRow(
                    tweak: 'accent.soft',
                    title: 'Accent, soft',
                    stock: accent.soft,
                  ),
                  _ColourRow(
                    tweak: 'accent.gradientEnd',
                    title: 'Accent, gradient end',
                    stock: accent.gradientEnd,
                  ),
                ],
              ),
              _Group(
                label: 'Signals',
                footnote: 'The same in both themes.',
                children: [
                  for (final (key, name, stock) in AppColors.signals)
                    _ColourRow(tweak: key, title: name, stock: stock),
                ],
              ),
              const _Group(
                label: 'Ink',
                footnote:
                    'How deep a task\'s colour is laid over the ground, as a '
                    'share of how it ships.',
                children: [
                  _InkRow(tweak: 'cardInk', title: 'Cards'),
                  _InkRow(tweak: 'doneInk', title: 'Done cards'),
                  _InkRow(tweak: 'chipInk', title: 'Day chips, opened month'),
                ],
              ),
              _Group(
                footnote:
                    'Copied as text, to send on or to paste on another '
                    'device.',
                children: [
                  _Row(
                    icon: Icons.copy_rounded,
                    title: 'Copy changes',
                    trailing: const SizedBox.shrink(),
                    onTap: () async {
                      await Clipboard.setData(
                        ClipboardData(text: tweaks.asText),
                      );
                      if (context.mounted) _say(context, 'Copied');
                    },
                  ),
                  _Row(
                    icon: Icons.content_paste_rounded,
                    title: 'Paste changes',
                    value: 'Replaces what is set here',
                    trailing: const SizedBox.shrink(),
                    onTap: () async {
                      final text = (await Clipboard.getData(
                        'text/plain',
                      ))?.text;
                      final ok = text != null && await tweaks.paste(text);
                      if (context.mounted) {
                        _say(context, ok ? 'Pasted' : 'Nothing to paste');
                      }
                    },
                  ),
                  _Row(
                    icon: Icons.restart_alt_rounded,
                    title: 'Reset everything',
                    danger: true,
                    onTap: () => _resetTweaks(context),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

Future<void> _resetTweaks(BuildContext context) async {
  final s = S.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Reset everything?'),
      content: const Text('Every colour and ink goes back as shipped.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(s.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Reset'),
        ),
      ],
    ),
  );
  if (ok == true) await Tweaks.instance.reset();
}

/// One colour: a swatch of it as it stands, its name, and its value — with
/// what it shipped as beside it once changed. A tap opens it to be set.
class _ColourRow extends StatelessWidget {
  final String tweak;
  final String title;
  final Color stock;

  const _ColourRow({
    required this.tweak,
    required this.title,
    required this.stock,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final set = Tweaks.instance.stored(tweak);
    final now = set ?? stock;
    return _Row(
      leading: _Chip(colour: now),
      title: title,
      value: set == null
          ? Tweaks.hex(stock)
          : '${Tweaks.hex(set)}  ·  was ${Tweaks.hex(stock)}',
      onTap: () => _pick(context),
      trailing: set == null
          ? null
          : IconButton(
              icon: Icon(Icons.undo_rounded, size: 20, color: p.muted),
              tooltip: 'As shipped',
              onPressed: () => Tweaks.instance.setColour(tweak, null),
            ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final tweaks = Tweaks.instance;
    final before = tweaks.stored(tweak);
    final picked = await showAppSheet<Color>(
      context,
      child: _ColourSheet(
        tweak: tweak,
        title: title,
        stock: stock,
        start: before ?? stock,
      ),
    );
    if (picked == null) {
      // Cancelled, or brushed away: what was shown while picking goes.
      await tweaks.setColour(tweak, before, keep: false);
    } else {
      await tweaks.setColour(tweak, picked == stock ? null : picked);
    }
  }
}

/// A colour as a small rimmed square, so a ground the same as the panel's
/// still shows.
class _Chip extends StatelessWidget {
  final Color colour;
  final double size;

  const _Chip({required this.colour, this.size = 22});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: colour,
      borderRadius: BorderRadius.circular(size / 4),
      border: Border.all(color: AppTheme.of(context).faint, width: 1),
    ),
  );
}

/// Sets one colour by hue, saturation and lightness, or by its hex. Every
/// change is shown on the app behind as it is made; Save keeps it.
class _ColourSheet extends StatefulWidget {
  final String tweak;
  final String title;
  final Color stock;
  final Color start;

  const _ColourSheet({
    required this.tweak,
    required this.title,
    required this.stock,
    required this.start,
  });

  @override
  State<_ColourSheet> createState() => _ColourSheetState();
}

class _ColourSheetState extends State<_ColourSheet> {
  late HSLColor _hsl = HSLColor.fromColor(widget.start);

  /// The exact colour, when it was typed or is the one started from: going
  /// through HSL can land a step off the hex that was asked for.
  late Color? _exact = widget.start;

  late final _hex = TextEditingController(text: Tweaks.hex(widget.start));

  Color get _colour => _exact ?? _hsl.toColor();

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _show() => Tweaks.instance.setColour(widget.tweak, _colour, keep: false);

  void _slid(HSLColor hsl) {
    setState(() {
      _hsl = hsl;
      _exact = null;
      _hex.text = Tweaks.hex(_colour);
    });
    _show();
  }

  void _typed(String text) {
    final colour = Tweaks.parse(text);
    if (colour == null) return;
    setState(() {
      _exact = colour;
      _hsl = HSLColor.fromColor(colour);
    });
    _show();
  }

  void _toStock() {
    setState(() {
      _exact = widget.stock;
      _hsl = HSLColor.fromColor(widget.stock);
      _hex.text = Tweaks.hex(widget.stock);
    });
    _show();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final colour = _colour;
    return Padding(
      // Clear of the keyboard while the hex is typed, as the group sheet is.
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        8 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _Chip(colour: widget.stock, size: 44),
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward_rounded, size: 18, color: p.faint),
              const SizedBox(width: 8),
              _Chip(colour: colour, size: 44),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _hex,
                  onChanged: _typed,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '#RRGGBB',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Channel(
            name: 'Hue',
            reading: '${_hsl.hue.round()}°',
            value: _hsl.hue,
            max: 360,
            onChanged: (v) => _slid(_hsl.withHue(v)),
          ),
          _Channel(
            name: 'Saturation',
            reading: '${(_hsl.saturation * 100).toStringAsFixed(1)}%',
            value: _hsl.saturation,
            max: 1,
            onChanged: (v) => _slid(_hsl.withSaturation(v)),
          ),
          _Channel(
            name: 'Lightness',
            reading: '${(_hsl.lightness * 100).toStringAsFixed(1)}%',
            value: _hsl.lightness,
            max: 1,
            onChanged: (v) => _slid(_hsl.withLightness(v)),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              SheetAction(
                label: s.cancel,
                onTap: () => Navigator.of(context).pop(),
              ),
              SheetAction(label: 'As shipped', onTap: _toStock),
              SheetAction(
                label: s.save,
                onTap: () => Navigator.of(context).pop(colour),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One slider of the colour sheet, its name and reading above it.
class _Channel extends StatelessWidget {
  final String name;
  final String reading;
  final double value;
  final double max;
  final ValueChanged<double> onChanged;

  const _Channel({
    required this.name,
    required this.reading,
    required this.value,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Row(
            children: [
              Text(name, style: TextStyle(color: p.muted, fontSize: 13)),
              const Spacer(),
              Text(
                reading,
                style: TextStyle(
                  color: p.text,
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        Slider(value: value.clamp(0, max), max: max, onChanged: onChanged),
      ],
    );
  }
}

/// How deep one kind of ink is, from none to two and a half times as
/// shipped, shown on the app as the slider moves.
class _InkRow extends StatelessWidget {
  final String tweak;
  final String title;

  const _InkRow({required this.tweak, required this.title});

  static const _most = 2.5;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final tweaks = Tweaks.instance;
    final set = tweaks.storedNumber(tweak);
    final value = set ?? 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 24,
                child: Icon(Icons.opacity_rounded, size: 21, color: p.muted),
              ),
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
                '×${value.toStringAsFixed(2)}',
                style: TextStyle(
                  color: set == null ? p.muted : p.text,
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              // Its room kept while there is nothing to undo, so the
              // reading does not jump.
              SizedBox(
                width: 48,
                height: 48,
                child: set == null
                    ? null
                    : IconButton(
                        icon: Icon(
                          Icons.undo_rounded,
                          size: 20,
                          color: p.muted,
                        ),
                        tooltip: 'As shipped',
                        onPressed: () => tweaks.setNumber(tweak, null),
                      ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: _Row.textStart - 16 - 16),
            child: Slider(
              value: value.clamp(0, _most),
              max: _most,
              divisions: 50,
              onChanged: (v) => tweaks.setNumber(tweak, v, keep: false),
              onChangeEnd: (v) => tweaks.setNumber(tweak, v == 1 ? null : v),
            ),
          ),
        ],
      ),
    );
  }
}

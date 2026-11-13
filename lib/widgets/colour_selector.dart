import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task_list.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'date_time_pickers.dart';

/// The swatches a task or a group picks its colour from: the palette in two
/// rows of eight, round the wheel, and under them the group's own colour
/// (for a task, marked with a link rather than a colour of its own), the
/// colours last made on the custom sheet, and a plus that opens it.
class ColourSelector extends StatelessWidget {
  final String? value;

  /// The colour of the task's group, offered first on the last row as "no
  /// colour of its own" (a null [value]). Null for a group, which has no
  /// group to fall back on.
  final Color? groupColour;

  /// What the custom sheet's sample card says: the task's title, or the
  /// group's name.
  final String sample;
  final ValueChanged<String?> onChanged;

  const ColourSelector({
    super.key,
    required this.value,
    this.groupColour,
    required this.sample,
    required this.onChanged,
  });

  static const _perRow = 8;
  static const _gap = 10.0;

  Future<void> _custom(BuildContext context) async {
    final settings = context.read<SettingsProvider?>();
    final made = await showCustomColourSheet(
      context,
      start: value == null ? groupColour : ListStyle.byId(value).color,
      sample: sample,
    );
    if (made == null) return;
    onChanged(made);
    await settings?.rememberColour(made);
  }

  @override
  Widget build(BuildContext context) {
    final recent = context.select<SettingsProvider?, List<String>>(
      (s) => s?.customColours ?? const [],
    );
    // A colour of the task's own that has fallen off the recent ones, or
    // came in a backup, is still shown, picked, where they are.
    final own = ListStyle.isCustom(value) && !recent.contains(value)
        ? value
        : null;
    final room =
        _perRow - 1 - (groupColour == null ? 0 : 1) - (own == null ? 0 : 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Eight to a row on any phone, so the palette's two rows are the
        // wheel's two halves.
        final size = ((constraints.maxWidth - _gap * (_perRow - 1)) / _perRow)
            .floorToDouble()
            .clamp(24.0, 36.0);
        Widget swatch(String? id, Color color, {IconData? icon}) => _Swatch(
          size: size,
          color: color,
          selected: value == id,
          icon: icon,
          onTap: () => onChanged(id),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: _gap,
              runSpacing: _gap,
              children: [
                for (final style in ListStyle.presets)
                  swatch(style.id, style.color),
              ],
            ),
            const SizedBox(height: _gap),
            Wrap(
              spacing: _gap,
              runSpacing: _gap,
              children: [
                if (groupColour != null)
                  swatch(null, groupColour!, icon: Icons.link),
                if (own != null) swatch(own, ListStyle.byId(own).color),
                for (final id in recent.take(room))
                  swatch(id, ListStyle.byId(id).color),
                _MakeSwatch(
                  key: customColourKey,
                  size: size,
                  onTap: () => _custom(context),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  final double size;
  final Color color;
  final bool selected;
  final IconData? icon;
  final VoidCallback onTap;

  /// Whether it is drawn faint until picked. The palette's are, so the one
  /// picked stands out of it; the custom sheet's tones are not, since
  /// telling them apart is all they are there for.
  final bool fades;

  const _Swatch({
    required this.size,
    required this.color,
    required this.selected,
    required this.onTap,
    this.icon,
    this.fades = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected || !fades ? 1 : 0.35),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? p.text : p.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: icon != null
            ? Icon(icon, size: size * 0.47, color: Colors.white)
            : (selected
                  ? Icon(Icons.check, size: size / 2, color: Colors.white)
                  : null),
      ),
    );
  }
}

/// The plus that opens the custom sheet: ringed with the whole wheel, the
/// one swatch that is every colour rather than one.
class _MakeSwatch extends StatelessWidget {
  final double size;
  final VoidCallback onTap;

  const _MakeSwatch({super.key, required this.size, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Tooltip(
      message: S.of(context).customColour,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(colors: _wheel(_tones[2])),
          ),
          child: Container(
            decoration: BoxDecoration(color: p.bg, shape: BoxShape.circle),
            child: Icon(Icons.add, size: size / 2, color: p.text),
          ),
        ),
      ),
    );
  }
}

/// The plus on [ColourSelector].
const customColourKey = Key('custom-colour');

/// The hue strip on the custom sheet.
const hueStripKey = Key('hue-strip');

/// Saturation and lightness of each tone the custom sheet offers. Not a
/// free square of them: a card shows a quarter of its colour over black, so
/// anything much darker than these is a black card and anything paler a grey
/// one, and a picker that offers those offers cards nobody can tell apart.
const _tones = [
  (s: 0.55, l: 0.40),
  (s: 0.62, l: 0.49),
  (s: 0.68, l: 0.57),
  (s: 0.72, l: 0.65),
  (s: 0.64, l: 0.73),
];

Color _colour(double hue, ({double s, double l}) tone) =>
    HSLColor.fromAHSL(1, hue % 360, tone.s, tone.l).toColor();

/// The wheel at one tone, red to red.
List<Color> _wheel(({double s, double l}) tone) => [
  for (var h = 0; h <= 360; h += 30) _colour(h.toDouble(), tone),
];

/// Opens the custom sheet at [start]'s hue and the tone nearest it. Returns
/// the colour made, as it is stored, or null if none was.
Future<String?> showCustomColourSheet(
  BuildContext context, {
  Color? start,
  required String sample,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PickerSheet(
      child: _CustomSheet(start: start, sample: sample),
    ),
  );
}

class _CustomSheet extends StatefulWidget {
  final Color? start;
  final String sample;

  const _CustomSheet({this.start, required this.sample});

  @override
  State<_CustomSheet> createState() => _CustomSheetState();
}

class _CustomSheetState extends State<_CustomSheet> {
  // Violet's hue, the app's own colour, when there is nothing to start from.
  double _hue = 252;
  int _tone = 2;

  @override
  void initState() {
    super.initState();
    final start = widget.start;
    if (start == null) return;
    final hsl = HSLColor.fromColor(start);
    // A grey has no hue to speak of; start it on the wheel's own.
    if (hsl.saturation > 0.12) _hue = hsl.hue;
    double away(({double s, double l}) t) =>
        (t.s - hsl.saturation).abs() * 0.5 + (t.l - hsl.lightness).abs();
    for (var i = 0; i < _tones.length; i++) {
      if (away(_tones[i]) < away(_tones[_tone])) _tone = i;
    }
  }

  Color get _picked => _colour(_hue, _tones[_tone]);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final picked = _picked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.customColour,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          _SampleCard(colour: picked, title: widget.sample),
          const SizedBox(height: 20),
          _HueStrip(
            hue: _hue,
            tone: _tones[_tone],
            onChanged: (h) => setState(() => _hue = h),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < _tones.length; i++)
                _Swatch(
                  size: 40,
                  color: _colour(_hue, _tones[i]),
                  selected: i == _tone,
                  fades: false,
                  onTap: () => setState(() => _tone = i),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            // The same pair the pickers end with, drawn in towards the
            // middle rather than out to the corners.
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              SheetAction(
                label: s.cancel,
                onTap: () => Navigator.of(context).pop(),
              ),
              SheetAction(
                label: s.save,
                onTap: () => Navigator.of(context).pop(ListStyle.idOf(picked)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The colour as a card wears it — a quarter of it over the ground, the
/// tick in it at full strength — since that is where it will be seen, and a
/// swatch at full strength says little about how the card will look.
class _SampleCard extends StatelessWidget {
  final Color colour;
  final String title;

  const _SampleCard({required this.colour, required this.title});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: colour, width: 1.8),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.text,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The wheel laid out flat at the chosen tone, with a ring on the hue. Takes
/// a tap or a sideways drag; the sheet keeps the vertical one.
class _HueStrip extends StatelessWidget {
  final double hue;
  final ({double s, double l}) tone;
  final ValueChanged<double> onChanged;

  const _HueStrip({
    required this.hue,
    required this.tone,
    required this.onChanged,
  });

  static const _height = 32.0;
  static const _thumb = 30.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // The ring's centre runs from half a ring in to half a ring short
        // of the end, so it never hangs off either side.
        final run = width - _thumb;
        void at(double x) =>
            onChanged(((x - _thumb / 2) / run).clamp(0.0, 1.0) * 360);
        return GestureDetector(
          key: hueStripKey,
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => at(d.localPosition.dx),
          onHorizontalDragStart: (d) => at(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
          child: SizedBox(
            height: _thumb + 4,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: _height,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_height / 2),
                    gradient: LinearGradient(
                      colors: _wheel(tone),
                      // The ends are under the ring's centre at 0 and 360,
                      // so the colour under the ring is the one picked.
                      stops: [
                        for (var i = 0; i <= 12; i++)
                          (_thumb / 2 + run * i / 12) / width,
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: run * hue.clamp(0, 360) / 360,
                  child: Container(
                    width: _thumb,
                    height: _thumb,
                    decoration: BoxDecoration(
                      color: _colour(hue, tone),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [
                        BoxShadow(color: Color(0x66000000), blurRadius: 6),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

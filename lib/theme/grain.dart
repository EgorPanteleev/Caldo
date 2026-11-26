import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'look.dart';

/// The same unfiltered grain on cards and app surfaces, decoded once.
abstract final class Grain {
  static const asset = AssetImage('assets/grain.png');
  static final _image = ValueNotifier<ui.Image?>(null);
  static Listenable get repaint => _image;
  static ImageStream? _stream;
  static final _waiting = <VoidCallback>{};

  static void load() {
    if (_stream != null) return;
    // Keep listening so the image stays available to every painter.
    _stream = asset.resolve(ImageConfiguration.empty)
      ..addListener(
        ImageStreamListener((info, _) {
          _image.value = info.image;
          final callbacks = [..._waiting];
          _waiting.clear();
          for (final callback in callbacks) {
            callback();
          }
        }),
      );
  }

  static void wait(VoidCallback? callback) {
    if (callback != null) _waiting.add(callback);
    load();
  }

  static void forget(VoidCallback? callback) => _waiting.remove(callback);

  static bool draw(
    Canvas canvas,
    RRect shape,
    double pixelRatio,
    double opacity, {
    bool darken = false,
  }) {
    final image = _image.value;
    if (image == null) return false;
    // Tile in one draw, a texel to as many physical pixels as the look
    // says: one as built.
    final scale = Look.current.grainSize / pixelRatio;
    final place = Float64List.fromList([
      scale, 0, 0, 0, //
      0, scale, 0, 0,
      0, 0, 1, 0,
      shape.left, shape.top, 0, 1,
    ]);
    canvas.drawRRect(
      shape,
      Paint()
        ..color = Colors.white.withValues(alpha: opacity)
        ..colorFilter = darken
            ? const ColorFilter.mode(Colors.black, BlendMode.srcIn)
            : null
        ..shader = ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          place,
          filterQuality: FilterQuality.none,
        ),
    );
    return true;
  }
}

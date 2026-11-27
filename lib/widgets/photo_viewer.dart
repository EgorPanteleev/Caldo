import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens a draft or sent chat photo with room to zoom and pan.
Future<void> showPhotoViewer(
  BuildContext context, {
  required ImageProvider image,
  required String name,
  String caption = '',
  String? time,
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  builder: (context) => Dialog.fullscreen(
    child: _PhotoViewer(image: image, name: name, caption: caption, time: time),
  ),
);

class _PhotoViewer extends StatefulWidget {
  final ImageProvider image;
  final String name;
  final String caption;
  final String? time;

  const _PhotoViewer({
    required this.image,
    required this.name,
    required this.caption,
    required this.time,
  });

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  bool _showControls = true;

  @override
  Widget build(BuildContext context) {
    final time = widget.time;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onTap: () => setState(() => _showControls = !_showControls),
              child: InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: Image(
                    image: widget.image,
                    semanticLabel: widget.name,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
            if (_showControls)
              Align(
                alignment: Alignment.topCenter,
                child: ColoredBox(
                  color: Colors.black54,
                  child: SafeArea(
                    bottom: false,
                    child: ListTile(
                      leading: const BackButton(color: Colors.white),
                      title: Text(
                        widget.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: time == null
                          ? null
                          : Text(
                              time,
                              style: const TextStyle(color: Colors.white70),
                            ),
                    ),
                  ),
                ),
              ),
            if (_showControls && widget.caption.trim().isNotEmpty)
              Align(
                alignment: Alignment.bottomCenter,
                child: ColoredBox(
                  color: Colors.black54,
                  child: SafeArea(
                    top: false,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.25,
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            widget.caption,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
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
    );
  }
}

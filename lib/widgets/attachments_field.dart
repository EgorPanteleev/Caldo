import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../services/attachments.dart';
import '../theme/app_theme.dart';

/// A task's attachments in the form: its photos as a row of thumbnails, its
/// other files a line each, and under them the three ways to add one. One
/// panel in the fields' grey, as the checklist above it is.
///
/// A thumbnail opens the photos full screen; a file opens in whatever app
/// on the phone reads it. Either can be taken off with its cross, which
/// only takes it off the task — the copy is let go of on a later start
/// (`Attachments.sweep`), so Cancel and Undo can still have it back.
class AttachmentsField extends StatelessWidget {
  final List<Attachment> attachments;
  final ValueChanged<AttachFrom> onAdd;
  final ValueChanged<Attachment> onRemove;

  const AttachmentsField({
    super.key,
    required this.attachments,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final images = [
      for (final a in attachments)
        if (a.isImage) a,
    ];
    final files = [
      for (final a in attachments)
        if (!a.isImage) a,
    ];
    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final image in images)
                    _Thumb(
                      key: ObjectKey(image),
                      image: image,
                      onTap: () => showAttachedPhotos(context, images, image),
                      onRemove: () => onRemove(image),
                    ),
                ],
              ),
            ),
          for (final file in files)
            _FileRow(
              key: ObjectKey(file),
              file: file,
              onRemove: () => onRemove(file),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                _Add(
                  key: attachPhotoKey,
                  icon: Icons.photo_outlined,
                  label: s.attachPhoto,
                  onTap: () => onAdd(AttachFrom.photos),
                ),
                _Add(
                  icon: Icons.photo_camera_outlined,
                  label: s.attachCamera,
                  onTap: () => onAdd(AttachFrom.camera),
                ),
                _Add(
                  icon: Icons.attach_file,
                  label: s.attachFile,
                  onTap: () => onAdd(AttachFrom.files),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The form's way to attach a photo.
const attachPhotoKey = Key('attach-photo');

/// Says something went wrong opening an attachment, where the form's other
/// complaints are said.
void _say(BuildContext context, String words) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(words)));

/// Opens [a] in another app, or says why it could not be.
Future<void> openAttachment(BuildContext context, Attachment a) async {
  final s = S.of(context);
  if (!Attachments.instance.has(a)) {
    _say(context, s.attachmentMissing);
    return;
  }
  final opened = await Attachments.instance.open(a);
  if (!opened && context.mounted) _say(context, s.noAppOpens);
}

/// A size as the file pickers write it: "340 KB", "2.4 MB".
String sizeText(S s, int bytes) {
  const kb = 1024;
  if (bytes < kb * kb) return s.kilobytes('${(bytes / kb).ceil()}');
  final mb = bytes / (kb * kb);
  String n;
  try {
    n = NumberFormat(mb < 10 ? '0.#' : '0').format(mb);
  } on ArgumentError {
    n = mb.toStringAsFixed(mb < 10 ? 1 : 0);
  }
  return s.megabytes(n);
}

class _Add extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _Add({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: p.muted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.muted, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A photo as a square, cut to fill it. Decoded at the size it is drawn, not
/// the camera's: a dozen twelve-megapixel photos at full size is a few
/// hundred megabytes of memory for a form.
class _Thumb extends StatelessWidget {
  final Attachment image;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _Thumb({
    super.key,
    required this.image,
    required this.onTap,
    required this.onRemove,
  });

  static const side = 72.0;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final file = Attachments.instance.fileOf(image);
    final missing = Container(
      color: p.field,
      alignment: Alignment.center,
      child: Icon(Icons.broken_image_outlined, color: p.faint, size: 24),
    );
    final px = (side * MediaQuery.devicePixelRatioOf(context)).round();
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: Attachments.instance.has(image)
                  ? onTap
                  : () => _say(context, S.of(context).attachmentMissing),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: file == null || !file.existsSync()
                    ? missing
                    : Image.file(
                        file,
                        fit: BoxFit.cover,
                        cacheWidth: px,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => missing,
                      ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: Colors.white,
                    semanticLabel: S.of(context).remove,
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

/// A file that is not a photo: what kind it is, its name and size, and a
/// cross. A tap opens it in another app.
class _FileRow extends StatelessWidget {
  final Attachment file;
  final VoidCallback onRemove;

  const _FileRow({super.key, required this.file, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final here = Attachments.instance.has(file);
    return InkWell(
      onTap: () => openAttachment(context, file),
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 4),
        child: Row(
          children: [
            Icon(iconOf(file), size: 20, color: p.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.text, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      here ? sizeText(s, file.size) : s.attachmentMissing,
                      maxLines: 1,
                      style: TextStyle(color: p.faint, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 18, color: p.faint),
              tooltip: s.remove,
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }

  static IconData iconOf(Attachment a) {
    final mime = a.mime;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.contains('spreadsheet') || mime.contains('excel')) {
      return Icons.table_chart_outlined;
    }
    if (mime.contains('zip') || mime.contains('compressed')) {
      return Icons.folder_zip_outlined;
    }
    if (mime.startsWith('text/') ||
        mime.contains('document') ||
        mime.contains('msword')) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

/// [images] full screen on black, opened at [first]: swiped through, pinched
/// to zoom, and handed to another app — a gallery or an editor — from the
/// top bar. Only the photos whose copies are here are shown.
Future<void> showAttachedPhotos(
  BuildContext context,
  List<Attachment> images,
  Attachment first,
) {
  final shown = images.where(Attachments.instance.has).toList();
  final start = shown.indexOf(first);
  if (start < 0) return Future.value();
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, _, _) => _Photos(images: shown, start: start),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _Photos extends StatefulWidget {
  final List<Attachment> images;
  final int start;

  const _Photos({required this.images, required this.start});

  @override
  State<_Photos> createState() => _PhotosState();
}

class _PhotosState extends State<_Photos> {
  late final _pages = PageController(initialPage: widget.start);
  late int _at = widget.start;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final shown = widget.images[_at];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() => _at = i),
            itemBuilder: (_, i) => InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: Image.file(
                  Attachments.instance.fileOf(widget.images[i])!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 40,
                  ),
                ),
              ),
            ),
          ),
          // A shade behind the bar, so its white reads over a white photo.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          widget.images.length > 1
                              ? '${_at + 1} / ${widget.images.length}'
                              : shown.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.open_in_new,
                          color: Colors.white,
                        ),
                        tooltip: s.openInApp,
                        onPressed: () => openAttachment(context, shown),
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

/// A card's mark for what is attached to its task: a paperclip, with how
/// many beside it once there is more than one.
class AttachmentMark extends StatelessWidget {
  final int count;
  final Color color;
  final double size;
  final double fontSize;

  const AttachmentMark({
    super.key,
    required this.count,
    required this.color,
    this.size = 14,
    this.fontSize = 12.5,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      key: attachmentMarkKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.attach_file, size: size, color: color),
        if (count > 1) ...[
          const SizedBox(width: 1),
          Text(
            '$count',
            style: TextStyle(color: color, fontSize: fontSize),
          ),
        ],
      ],
    );
  }
}

const attachmentMarkKey = Key('attachment-mark');

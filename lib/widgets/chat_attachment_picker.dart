import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/attachments.dart';
import '../theme/app_theme.dart';

Future<Picked?> showChatAttachmentPicker(BuildContext context) {
  return showModalBottomSheet<Picked>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ChatAttachmentPicker(),
  );
}

class _ChatAttachmentPicker extends StatefulWidget {
  const _ChatAttachmentPicker();

  @override
  State<_ChatAttachmentPicker> createState() => _ChatAttachmentPickerState();
}

class _ChatAttachmentPickerState extends State<_ChatAttachmentPicker>
    with WidgetsBindingObserver {
  final _attachments = Attachments.instance;
  final _photos = <GalleryPhoto>[];
  final _selected = <String>{};
  GalleryAccess? _access;
  bool _loading = false;
  bool _busy = false;
  bool _more = true;
  // The library may change while a page is in flight, for example when the
  // app resumes after Android changes which photos it can see.
  int _offset = 0;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _refresh();
  }

  Future<void> _refresh() {
    setState(() {
      _generation++;
      _offset = 0;
      _more = true;
      _loading = false;
      _photos.clear();
      if (_access != GalleryAccess.full) _selected.clear();
      _access = null;
    });
    return _loadPage();
  }

  Future<void> _loadPage() async {
    if (_loading || !_more) return;
    setState(() => _loading = true);
    final generation = _generation;
    final page = await _attachments.galleryPage(_offset);
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      _more = page?.more ?? false;
      if (page == null) {
        if (_offset == 0) _selected.clear();
        return;
      }
      _access = page.access;
      if (_offset == 0 && page.access != GalleryAccess.full) _selected.clear();
      final present = _photos.map((photo) => photo.id).toSet();
      _photos.addAll(page.photos.where((photo) => present.add(photo.id)));
      _offset += page.photos.length;
    });
  }

  Future<void> _askForAccess() async {
    setState(() => _busy = true);
    await _attachments.requestGalleryAccess();
    if (!mounted) return;
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  Future<void> _pick([AttachFrom? source]) async {
    setState(() => _busy = true);
    final external = source == null
        ? Picked.none
        : await _attachments.pick(source);
    if (!mounted) return;
    if (source != null &&
        external.attached.isEmpty &&
        external.tooBig.isEmpty &&
        external.unreadable == 0) {
      await _refresh();
      if (mounted) setState(() => _busy = false);
      return;
    }
    final selected = _selected.toList();
    final inline = selected.isEmpty
        ? Picked.none
        : await _attachments.pickFromGallery(selected);
    if (!mounted) return;
    Navigator.of(context).pop(
      Picked(
        [...inline.attached, ...external.attached],
        [...inline.tooBig, ...external.tooBig],
        inline.unreadable + external.unreadable,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final short = MediaQuery.sizeOf(context).height < 500;
    return PopScope(
      canPop: !_busy,
      child: DraggableScrollableSheet(
        expand: false,
        minChildSize: short ? 0.70 : 0.42,
        initialChildSize: short ? 0.89 : 0.64,
        maxChildSize: 0.94,
        shouldCloseOnMinExtent: false,
        snap: true,
        snapSizes: [short ? 0.89 : 0.64],
        builder: (context, scroll) => Material(
          color: p.panel,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: p.border),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Expanded(child: _gallery(scroll, p, s)),
                _footer(p, s),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppPalette p, S s) => ColoredBox(
    color: p.panel,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            width: 32,
            height: 3,
            decoration: BoxDecoration(
              color: p.faint,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  s.attachmentGallery,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, color: p.muted, size: 20),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _gallery(ScrollController scroll, AppPalette p, S s) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notice) {
        if (!_busy && notice.metrics.extentAfter < 360 && _photos.isNotEmpty) {
          _loadPage();
        }
        return false;
      },
      child: CustomScrollView(
        controller: scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          PinnedHeaderSliver(child: _header(p, s)),
          if (_access == GalleryAccess.partial && _photos.isNotEmpty)
            SliverToBoxAdapter(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextButton.icon(
                    onPressed: _busy ? null : _askForAccess,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: Text(s.attachmentMorePhotos),
                  ),
                ),
              ),
            ),
          if (_photos.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _access == GalleryAccess.none
                                  ? s.attachmentPhotoAccessHint
                                  : s.attachmentNoPhotos,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: p.muted),
                            ),
                            if (_access == GalleryAccess.none ||
                                _access == GalleryAccess.partial)
                              TextButton(
                                onPressed: _busy ? null : _askForAccess,
                                child: Text(
                                  _access == GalleryAccess.partial
                                      ? s.attachmentMorePhotos
                                      : s.attachmentPhotoAccess,
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 145,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: _photos.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _CameraTile(
                      onTap: _busy ? null : () => _pick(AttachFrom.camera),
                    );
                  }
                  final photo = _photos[index - 1];
                  return _PhotoTile(
                    key: ValueKey((_generation, photo.id)),
                    photo: photo,
                    order: _selected.contains(photo.id)
                        ? _selected.toList().indexOf(photo.id) + 1
                        : null,
                    onTap: _busy ? null : () => _toggle(photo.id),
                  );
                },
              ),
            ),
          if (_loading && _photos.isNotEmpty)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
        ],
      ),
    );
  }

  Widget _footer(AppPalette p, S s) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.border)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: _selected.isEmpty
          ? Row(
              children: [
                _source(
                  s.attachmentBrowsePhotos,
                  Icons.collections_outlined,
                  AttachFrom.photos,
                ),
                if (_photos.isEmpty)
                  _source(
                    s.attachCamera,
                    Icons.photo_camera_outlined,
                    AttachFrom.camera,
                  ),
                _source(
                  s.attachFile,
                  Icons.insert_drive_file_outlined,
                  AttachFrom.files,
                ),
              ],
            )
          : SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : () => _pick(),
                icon: const Icon(Icons.attach_file, size: 18),
                label: Text('${s.chatAttachFiles} (${_selected.length})'),
              ),
            ),
    );
  }

  Widget _source(String label, IconData icon, AttachFrom source) => Expanded(
    child: TextButton(
      onPressed: _busy ? null : () => _pick(source),
      style: TextButton.styleFrom(
        foregroundColor: AppTheme.of(context).text,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 21),
          const SizedBox(height: 2),
          Text(label, maxLines: 2, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _CameraTile extends StatelessWidget {
  final VoidCallback? onTap;

  const _CameraTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final label = S.of(context).attachCamera;
    return Material(
      color: p.field,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_camera_outlined, color: p.text, size: 27),
              const SizedBox(height: 4),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoTile extends StatefulWidget {
  final GalleryPhoto photo;
  final int? order;
  final VoidCallback? onTap;

  const _PhotoTile({
    super.key,
    required this.photo,
    required this.order,
    required this.onTap,
  });

  @override
  State<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<_PhotoTile> {
  Future<Uint8List?>? _thumbnail;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final colors = Theme.of(context).colorScheme;
    final order = widget.order;
    return Semantics(
      label: widget.photo.name,
      selected: order != null,
      child: Material(
        color: p.field,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder(
                future: _thumbnail ??= Attachments.instance.thumbnailOf(
                  widget.photo,
                  (145 * MediaQuery.devicePixelRatioOf(context)).round(),
                ),
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes != null) {
                    return Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      excludeFromSemantics: true,
                    );
                  }
                  return Center(
                    child: Icon(Icons.image_outlined, color: p.faint, size: 20),
                  );
                },
              ),
              if (order != null)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.16),
                      border: Border.all(color: colors.primary, width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              PositionedDirectional(
                top: 7,
                end: 7,
                child: Container(
                  width: 25,
                  height: 25,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: order == null
                        ? Colors.black.withValues(alpha: 0.42)
                        : colors.primary,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: order == null
                      ? null
                      : Text(
                          '$order',
                          style: TextStyle(
                            color: colors.onPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
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

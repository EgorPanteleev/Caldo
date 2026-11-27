import 'package:caldo/l10n/strings.dart';
import 'package:caldo/services/attachments.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/chat_attachment_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('caldo/attachments');
  final s = S.forCode('en');

  Future<void> show(
    WidgetTester tester,
    Future<Object?> Function(MethodCall) platform,
    ValueChanged<Picked?> onPick,
  ) async {
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, platform);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [S.delegate],
        theme: AppTheme.dark(AppAccent.presets.first),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  onPick(await showChatAttachmentPicker(context)),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Map<String, Object> photo(String id) => {
    'file': '$id/photo.jpg',
    'name': '$id.jpg',
    'mime': 'image/jpeg',
    'size': 120,
  };

  testWidgets('gallery attaches only the confirmed photos in selection order', (
    tester,
  ) async {
    List<String>? copied;
    Picked? picked;
    await show(tester, (call) async {
      switch (call.method) {
        case 'galleryPage':
          return {
            'access': 'full',
            'photos': [
              for (final id in ['1', '2', '3']) {'id': id, 'name': '$id.jpg'},
            ],
            'more': false,
          };
        case 'galleryPick':
          copied = List<String>.from(call.arguments['ids'] as List);
          return {'attached': copied!.map(photo).toList()};
        default:
          return null;
      }
    }, (result) => picked = result);
    final heading = find.text(s.attachmentGallery);
    final collapsedAt = tester.getTopLeft(heading).dy;
    await tester.drag(heading, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(heading).dy, lessThan(collapsedAt));

    for (final id in ['2', '3', '2', '1']) {
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == '$id.jpg',
        ),
      );
      await tester.pumpAndSettle();
    }

    expect(copied, isNull);
    await tester.tap(find.text('${s.chatAttachFiles} (2)'));
    await tester.pumpAndSettle();
    expect(copied, ['3', '1']);
    expect(picked?.attached.map((a) => a.name), ['3.jpg', '1.jpg']);
  });

  testWidgets('files can still be attached when gallery access is denied', (
    tester,
  ) async {
    final methods = <String>[];
    Picked? picked;
    await show(tester, (call) async {
      methods.add(call.method);
      switch (call.method) {
        case 'galleryPage':
          return {'access': 'none', 'photos': [], 'more': false};
        case 'pick':
          expect(call.arguments['from'], 'files');
          return {
            'attached': [photo('file')],
          };
        default:
          return null;
      }
    }, (result) => picked = result);

    expect(methods, ['galleryPage']);
    expect(find.text(s.attachmentPhotoAccess), findsOneWidget);
    expect(find.text(s.attachmentBrowsePhotos), findsOneWidget);
    await tester.tap(find.text(s.attachmentPhotoAccess));
    await tester.pumpAndSettle();
    expect(methods, ['galleryPage', 'galleryAccess', 'galleryPage']);

    await tester.tap(find.text(s.attachFile));
    await tester.pumpAndSettle();
    expect(picked?.attached.single.name, 'file.jpg');
  });
}

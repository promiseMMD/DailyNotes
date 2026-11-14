import 'dart:io';
import 'dart:ui' as ui;

import 'package:dailynotes/src/app.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Saves actual widget-rendered screenshots as CI artifacts for UI review.
/// These are NOT a golden baseline or proof of physical-device appearance.
/// All visible content remains empty-state preview, not invented diary data.
void main() {
  testWidgets('capture phone previews for human visual review', (tester) async {
    const key = Key('capture-root');
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Flutter widget tests use block-glyph test fonts by default.
    // Install a review-only CJK font and Material icons on the CI host.
    // Never copy these font binaries into the user APK or screenshot artifact.
    await tester.runAsync(() async {
      const cjkPath =
          '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      if (flutterRoot == null) throw StateError('FLUTTER_ROOT missing');
      final iconPath =
          '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
      if (!await File(cjkPath).exists()) {
        throw StateError('Chinese review font missing: $cjkPath');
      }
      if (!await File(iconPath).exists()) {
        throw StateError('Material icon review font missing: $iconPath');
      }
      await ui.loadFontFromList(
        await File(cjkPath).readAsBytes(),
        fontFamily: 'DailyNotesScreenshotCJK',
      );
      await ui.loadFontFromList(
        await File(iconPath).readAsBytes(),
        fontFamily: 'MaterialIcons',
      );
    });
    await tester.pumpWidget(const RepaintBoundary(
      key: key,
      child: DailyNotesApp(screenshotFontFamily: 'DailyNotesScreenshotCJK'),
    ));
    await tester.pumpAndSettle();

    Future<void> capture(String name) async {
      // Encoding and file I/O are real async operations, outside fake clock.
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (bytes == null) throw StateError('Failed to encode UI screenshot');
        final output = File('build/ui-screenshots/$name.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes.buffer.asUint8List());
      });
    }

    await capture('01-diary');
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    await capture('02-drawer');
    await tester.tapAt(const Offset(389, 500)); // Dismiss drawer scrim.
    await tester.pumpAndSettle();

    await tester.tap(find.text('待办').last);
    await tester.pumpAndSettle();
    await capture('03-todo');

    await tester.tap(find.text('笔记').last);
    await tester.pumpAndSettle();
    await capture('04-notes');

  });
}

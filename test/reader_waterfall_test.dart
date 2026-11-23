import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera_edge/components/window_frame.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/comic_source/comic_source.dart';
import 'package:venera_edge/foundation/comic_type.dart';
import 'package:venera_edge/foundation/favorites.dart';
import 'package:venera_edge/foundation/history.dart';
import 'package:venera_edge/foundation/js_engine.dart';
import 'package:venera_edge/foundation/local.dart';
import 'package:venera_edge/pages/reader/reader.dart';
import 'package:venera_edge/src/rust/api/local.dart';
import 'package:venera_edge/src/rust/frb_generated.dart';
import 'package:venera_edge/utils/translations.dart';

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test('waterfall reader', () {}, skip: 'Set VENERA_BACKEND_LIBRARY');
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    await AppTranslation.init();
  });

  testWidgets('waterfall keeps position and reads both ways within a group', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messenger = tester.binding.defaultBinaryMessenger;
    for (final name in ['flutter_memory_info', 'window_manager']) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    const chapters = ComicChapters.grouped({
      'Main': {'ep1': 'First', 'ep2': 'Second'},
      'Extras': {'ep3': 'Extra'},
    });
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('venera-waterfall-'),
    ))!;

    void writeChapter(String id) {
      final chapter = Directory('${LocalManager().path}/comic/$id')
        ..createSync(recursive: true);
      for (var i = 1; i <= 2; i++) {
        File('${chapter.path}/$i.png').writeAsBytesSync(png);
      }
    }

    final local = LocalManager();
    final comic = (await tester.runAsync(() async {
      App.dataPath = root.path;
      App.cachePath = root.path;
      await appdata.init();
      appdata.settings['proxy'] = 'direct';
      await JsEngine().init();
      await ComicSourceManager().init();
      await local.init();
      await LocalFavoritesManager().init();
      await HistoryManager().init();
      writeChapter('ep2');
      writeChapter('ep3');
      final store = await LocalStore.open(path: '${root.path}/local.db');
      store.save(
        comicJson: jsonEncode({
          'id': 'waterfall',
          'title': 'Waterfall',
          'subtitle': '',
          'tags': <String>[],
          'directory': 'comic',
          'chapters': chapters.toJson(),
          'cover': 'ep2/1.png',
          'comic_type': ComicType.local.value,
          'downloaded_chapters': chapters.ids.toList(),
          'created_at': 1,
        }),
      );
      store.close();
      store.dispose();

      appdata.settings['readerMode'] = 'continuousTopToBottom';
      appdata.settings['enablePageAnimation'] = false;
      appdata.settings['limitImageWidth'] = false;
      appdata.settings['enableClockAndBatteryInfoInReader'] = false;
      expect(appdata.settings['readerWaterfall'], isFalse);
      appdata.settings.setReaderSetting('waterfall', 'local', 'enabled', true);
      appdata.settings.setReaderSetting(
        'waterfall',
        'local',
        'readerWaterfall',
        true,
      );
      await appdata.saveData(false);
      return local.find('waterfall', ComicType.local)!;
    }))!;

    Future<void> pumpUntil(bool Function() ready) async {
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(
        ready(),
        isTrue,
        reason: 'Reader did not reach the expected state',
      );
    }

    final history = History.fromModel(model: comic, ep: 2, page: 1);
    Widget host(Widget child) => MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      builder: (_, child) => Material(child: WindowFrame(child!)),
      home: child,
    );
    await tester.pumpWidget(
      host(
        Reader(
          type: ComicType.local,
          cid: comic.id,
          name: comic.title,
          chapters: chapters,
          initialChapter: 2,
          history: history,
          author: '',
          tags: const [],
        ),
      ),
    );

    final listFinder = find.byType(ScrollablePositionedList);
    ScrollablePositionedList list() => tester.widget(listFinder);
    bool imagesDecoded() {
      final images = find.byType(ComicImage).evaluate();
      return images.isNotEmpty &&
          images.every(
            (image) => find
                .descendant(
                  of: find.byWidget(image.widget),
                  matching: find.byType(RawImage),
                )
                .evaluate()
                .isNotEmpty,
          );
    }

    await pumpUntil(() => listFinder.evaluate().length == 1 && imagesDecoded());
    final controller = list().itemScrollController!;
    // Reach the failing previous-chapter edge, then retry once its files exist.
    controller.jumpTo(index: 0);
    final retryText = find.textContaining('Retry');
    await pumpUntil(() => retryText.evaluate().isNotEmpty);
    expect(list().itemCount, 5);
    expect(history.ep, 2);

    await tester.runAsync(() async => writeChapter('ep1'));
    await tester.tap(retryText);
    await pumpUntil(() => list().itemCount == 8);
    await tester.pump();
    await tester.pump();
    expect(
      history.ep,
      2,
      reason: 'Prepending keeps the current chapter visible',
    );
    expect(identical(list().itemScrollController, controller), isTrue);

    controller.jumpTo(index: 2);
    await pumpUntil(() => history.ep == 1 && history.page == 1);
    expect(history.group, 1);
    controller.jumpTo(index: 5);
    await pumpUntil(() => history.ep == 2 && history.page == 1);
    expect(history.group, 1);

    final dynamic reader = tester.state(find.byType(Reader));
    expect(reader.toPage(2), isTrue);
    await pumpUntil(() => history.ep == 2 && history.page == 2);
    expect(reader.toChapter(1, toLastPage: true), isTrue);
    await pumpUntil(
      () =>
          listFinder.evaluate().length == 1 &&
          list().itemCount == 8 &&
          !identical(list().itemScrollController, controller) &&
          imagesDecoded(),
    );
    expect(
      history.ep,
      1,
      reason: 'Appending keeps the current chapter visible',
    );
    list().itemScrollController!.jumpTo(index: 5);
    await pumpUntil(() => history.ep == 2 && history.page == 1);
    expect(reader.toChapter(3), isTrue);
    await pumpUntil(
      () =>
          listFinder.evaluate().length == 1 &&
          history.group == 2 &&
          imagesDecoded(),
    );
    expect(history.ep, 1);
    expect(list().itemCount, 5);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(host(const SizedBox()));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      local.dispose();
      HistoryManager().close();
      LocalFavoritesManager().close();
      JsEngine().dispose();
      await root.delete(recursive: true);
    });
  });
}

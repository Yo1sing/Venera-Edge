import 'package:flutter_test/flutter_test.dart';
import 'package:venera_edge/foundation/home_layout.dart';

void main() {
  test(
    'legacy settings and empty layouts use the existing Edge home order',
    () {
      for (final data in [
        null,
        {},
        {'order': false, 'hidden': 42},
      ]) {
        final layout = HomeLayout.fromJson(data);
        expect(layout.order, [
          'search',
          'sync',
          'history',
          'local',
          'updates',
          'sources',
          'images',
        ]);
        expect(layout.hidden, isEmpty);
        expect(layout.compact, isFalse);
      }
    },
  );

  test('reordering Edge modules preserves imported Prime module slots', () {
    final layout = HomeLayout.fromJson({
      'order': [
        'history',
        'statistics',
        'search',
        'search',
        'invalid',
        1,
        'readLater',
        'sync',
      ],
      'hidden': ['statistics', 'local', 'invalid', 1],
    });
    layout.move('history', 'sync');
    expect(layout.order, [
      'search',
      'sync',
      'history',
      'local',
      'updates',
      'sources',
      'images',
    ]);
    expect(layout.toJson()['order'], [
      'search',
      'statistics',
      'sync',
      'readLater',
      'history',
      'local',
      'updates',
      'sources',
      'images',
    ]);
    expect(layout.hidden, {'local', 'statistics'});
    layout.move('history', 'search');
    expect(layout.order.take(3), ['history', 'search', 'sync']);
    expect(HomeLayout.fromJson(layout.toJson()).toJson(), layout.toJson());
  });

  test(
    'adding an existing folder reveals it and removing it cleans its layout entries',
    () {
      final layout = HomeLayout.fromJson({
        'compact': true,
        'folders': {
          'folder:我的收藏': '我的收藏',
          'folder:mismatch': 'another',
          'folder:': '',
        },
        'order': ['folder:我的收藏', 'folder:absent'],
        'hidden': ['folder:我的收藏', 'folder:mismatch'],
      });
      expect(layout.compact, isTrue);
      expect(layout.hidden, {'folder:我的收藏'});
      layout.addFolder('我的收藏');
      expect(layout.hidden, isEmpty);
      expect(layout.order.where((id) => id == 'folder:我的收藏'), hasLength(1));
      expect(layout.folders, {'folder:我的收藏': '我的收藏'});
      layout.addFolder('New');
      expect(layout.order.last, 'folder:New');
      layout.hidden.add('folder:New');
      layout.removeFolder('folder:New');
      expect(layout.hidden, isEmpty);
      expect(layout.order, isNot(contains('folder:New')));
      expect(layout.folders, isNot(contains('folder:New')));
    },
  );
}

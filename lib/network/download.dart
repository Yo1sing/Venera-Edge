import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/comic_source/comic_source.dart';
import 'package:venera_edge/foundation/comic_type.dart';
import 'package:venera_edge/foundation/js_engine.dart';
import 'package:venera_edge/foundation/local.dart';
import 'package:venera_edge/foundation/log.dart';
import 'package:venera_edge/src/rust/api/comic_queue.dart' as backend;
import 'package:venera_edge/utils/io.dart';

/// Observable presentation model. Rust owns scheduling, retries, files and checkpoints.
class DownloadTask with ChangeNotifier {
  Map<String, dynamic> _snapshot;
  DownloadTask(this._snapshot);
  String get id => _snapshot['comicId'];
  String get queueKey => '${_snapshot['source']}@$id';
  ComicType get comicType => ComicType(_snapshot['comicType']);
  String get title =>
      _snapshot['comic']?['title'] ?? _snapshot['comicTitle'] ?? 'Loading...';
  String? get cover => _snapshot['cover'] ?? _snapshot['comic']?['cover'];
  String get message => _snapshot['message'] ?? 'Paused';
  bool get isError => _snapshot['_error'] == true;
  bool get isPaused => _snapshot['_running'] != true;
  int get speed => (_snapshot['_speed'] as num?)?.toInt() ?? 0;
  String? get path => _snapshot['path'];
  double get progress {
    final total = (_snapshot['totalCount'] as num?) ?? 0;
    return total == 0
        ? 0
        : ((_snapshot['downloadedCount'] as num?) ?? 0) / total;
  }

  void pause() => DownloadQueueView.command(queueKey, 'pause');
  void resume() => DownloadQueueView.command(queueKey, 'resume');
  void cancel() => DownloadQueueView.command(queueKey, 'cancel');
  Map<String, dynamic> toJson() => Map.from(_snapshot);
  void apply(Map<String, dynamic> snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }

  static DownloadTask? fromJson(Map<String, dynamic> json) =>
      DownloadTask(json);
  @override
  bool operator ==(Object other) =>
      other is DownloadTask && queueKey == other.queueKey;
  @override
  int get hashCode => queueKey.hashCode;
}

class ImagesDownloadTask extends DownloadTask {
  ImagesDownloadTask({
    required ComicSource source,
    required String comicId,
    ComicDetails? comic,
    List<String>? chapters,
    String? comicTitle,
  }) : super({
         'type': 'ImagesDownloadTask',
         'source': source.key,
         'comicId': comicId,
         'comicType': source.key.hashCode,
         'comic': comic?.toJson(),
         'chapters': chapters,
         'comicTitle': comicTitle,
       });
}

class ArchiveDownloadTask extends DownloadTask {
  ArchiveDownloadTask(String archiveUrl, ComicDetails comic)
    : super({
        'type': 'ArchiveDownloadTask',
        'archiveUrl': archiveUrl,
        'comic': comic.toJson(),
        'source': comic.sourceKey,
        'comicId': comic.id,
        'comicType': comic.sourceKey.hashCode,
      });
}

abstract class DownloadQueueView {
  static backend.ComicDownloadQueue? _queue;
  static Future<void>? _initializing;
  static Future<String> _options() async {
    final runtime = jsonDecode(await JsEngine.runtimeOptions());
    return jsonEncode({
      'data_path': App.dataPath,
      'cache_path': App.cachePath,
      'local_path': LocalManager().path,
      'saf': LocalManager().directory is AndroidDirectory,
      'threads': appdata.settings['downloadThreads'],
      'http': runtime['http'],
    });
  }

  static Future<void> initialize() => _initializing ??= _open();
  static Future<void> _open() async {
    _queue = await backend.ComicDownloadQueue.open(
      runtime: JsEngine().runtime,
      optionsJson: await _options(),
      sourceTypesJson: jsonEncode({
        for (final source in ComicSource.all()) source.key: source.key.hashCode,
      }),
    );
    _apply(_queue!.snapshot());
    unawaited(_listen());
    unawaited(_platform());
  }

  static void _apply(String value) {
    final old = {
      for (final task in LocalManager().downloadingTasks) task.queueKey: task,
    };
    final tasks = <DownloadTask>[];
    for (final row in jsonDecode(value) as List) {
      final snapshot = Map<String, dynamic>.from(row);
      final task = old[snapshot['_key']] ?? DownloadTask(snapshot);
      task.apply(snapshot);
      tasks.add(task);
    }
    LocalManager().applyDownloadSnapshot(tasks);
  }

  static Future<void> _listen() async {
    try {
      while (true) {
        final value = await _queue!.nextSnapshot();
        if (value == null) break;
        _apply(value);
      }
    } catch (e, s) {
      Log.error('Download queue', e, s);
    }
  }

  static Future<dynamic> handlePlatformOperation(
    Map<String, dynamic> event,
  ) async {
    dynamic result;
    final from = event['from'] as String;
    final to = event['to'] as String?;
    switch (event['operation']) {
      case 'copyDirectory':
        final target = Directory(to!);
        await target.create(recursive: true);
        await copyDirectoryIsolate(Directory(from), target);
      case 'exists':
        result = await File(from).exists() || await Directory(from).exists();
      case 'listFiles':
        result = await Directory(from)
            .list()
            .where((entry) => entry is File)
            .map((entry) => entry.name)
            .toList();
      case 'readFile':
        result = (await File(from).readAsBytes()).toList();
      case 'createDirectory':
        await Directory(from).create();
      case 'moveFile':
        if (await File(to!).exists() || await Directory(to).exists()) {
          throw StateError('Destination already exists');
        }
        await File(from).rename(to);
        if (!await File(to).exists() || await File(from).exists()) {
          throw StateError('File move was not completed');
        }
      case 'removeFile':
        await File(from).delete();
        if (await File(from).exists()) {
          throw StateError('File deletion was not completed');
        }
      case 'removeEmptyDirectory':
        final directory = Directory(from);
        if (await directory.list().isEmpty) await directory.delete();
      case 'removeDirectory':
        await Directory(from).delete(recursive: true);
        if (await Directory(from).exists()) {
          throw StateError('Directory deletion was not completed');
        }
      default:
        throw StateError('Unknown download file operation');
    }
    return result;
  }

  static Future<void> _platform() async {
    while (true) {
      final encoded = await _queue!.nextPlatformEvent();
      if (encoded == null) return;
      final event = jsonDecode(encoded);
      String? error;
      dynamic result;
      try {
        result = await handlePlatformOperation(
          Map<String, dynamic>.from(event),
        );
      } catch (e) {
        error = e.toString();
      }
      await _queue!.resolvePlatform(
        id: event['id'],
        error: error,
        valueJson: jsonEncode(result),
      );
    }
  }

  static void add(DownloadTask task) => _run(() async {
    await initialize();
    await _queue!.configure(optionsJson: await _options());
    await _queue!.add(taskJson: jsonEncode(task.toJson()));
  });

  static Future<Map<String, dynamic>> moveStorage(String destination) async {
    await initialize();
    return jsonDecode(
      await _queue!.moveStorage(destination: destination, android: App.isAndroid),
    ) as Map<String, dynamic>;
  }
  static void command(String key, String action) => _run(() async {
    await initialize();
    await _queue!.configure(optionsJson: await _options());
    await _queue!.command(key: key, action: action);
  });
  static void _run(Future<void> Function() action) {
    unawaited(
      action().catchError((Object e, StackTrace s) {
        Log.error('Download queue', e, s);
      }),
    );
  }
}

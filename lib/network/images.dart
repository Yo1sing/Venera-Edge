import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/src/rust/api/media.dart' as backend;

/// Flutter owns subscriptions; source hooks, transport, retries and caching run in Rust.
abstract class ImageDownloader {
  static final _loadingImages = <String, _SharedImageStream>{};

  static Future<Uint8List> loadView(
    Map<String, dynamic> request,
    StreamController<ImageChunkEvent>? chunks,
    void Function()? checkStop,
  ) async {
    final encoded = jsonEncode(request);
    Stream<ImageDownloadProgress> open() => _transfer(
      () => backend.ImageTransfer.startView(
        runtime: JsEngine().runtime,
        dataPath: App.dataPath,
        cachePath: App.cachePath,
        localPath: LocalManager().path,
        requestJson: encoded,
      ),
    );
    final stream = request['kind'] == 'reader'
        ? _shared(encoded, open)
        : open();
    final iterator = StreamIterator(stream);
    final onCancel = chunks?.onCancel;
    if (chunks != null) {
      chunks.onCancel = () {
        onCancel?.call();
        unawaited(iterator.cancel());
      };
    }
    try {
      checkStop?.call();
      while (await iterator.moveNext()) {
        checkStop?.call();
        final event = iterator.current;
        if (event.imageBytes case final bytes?) return bytes;
        chunks?.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.currentBytes,
            expectedTotalBytes: event.totalBytes,
          ),
        );
      }
      checkStop?.call();
      throw StateError('Image stream ended without data');
    } finally {
      await iterator.cancel();
      if (chunks != null) chunks.onCancel = onCancel;
    }
  }

  static Future<void> invalidateView(Map<String, dynamic> request) =>
      backend.invalidateViewImage(
        dataPath: App.dataPath,
        cachePath: App.cachePath,
        requestJson: jsonEncode(request),
      );

  static Future<Uint8List> loadOriginal(
    String image,
    String? source,
    String comic,
    String chapter,
  ) => loadView(
    {
      'kind': 'reader',
      'image': image,
      'source': source,
      'comic': comic,
      'chapter': chapter,
      'page': 0,
    },
    null,
    null,
  );

  static void cancelAllLoadingImages() {
    for (final stream in _loadingImages.values.toList()) {
      stream.cancel();
    }
    _loadingImages.clear();
  }

  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final key = '$imageKey@$sourceKey@$cid@$eid';
    return _shared(
      key,
      () => _transfer(
        () => backend.ImageTransfer.start(
          runtime: JsEngine().runtime,
          dataPath: App.dataPath,
          cachePath: App.cachePath,
          image: imageKey,
          source: sourceKey,
          comic: cid,
          chapter: eid,
          thumbnail: false,
        ),
      ),
    );
  }

  static Stream<ImageDownloadProgress> _shared(
    String key,
    Stream<ImageDownloadProgress> Function() open,
  ) {
    final shared = _loadingImages.putIfAbsent(
      key,
      () => _SharedImageStream(open(), () => _loadingImages.remove(key)),
    );
    return shared.subscribe();
  }

  static Stream<ImageDownloadProgress> _transfer(
    Future<backend.ImageTransfer> Function() open,
  ) {
    backend.ImageTransfer? transfer;
    var cancelled = false;
    late StreamController<ImageDownloadProgress> controller;
    controller = StreamController(
      onListen: () async {
        try {
          transfer = await open();
          if (cancelled) {
            transfer!.cancel();
            return;
          }
          while (!cancelled) {
            final event = await transfer!.next();
            if (event == null || cancelled) break;
            if (event.error != null) throw StateError(event.error!);
            controller.add(
              ImageDownloadProgress(
                currentBytes: event.current,
                totalBytes: event.total,
                imageBytes: event.bytes,
              ),
            );
            if (event.bytes != null) break;
          }
        } catch (error, stack) {
          if (!cancelled) controller.addError(error, stack);
        } finally {
          transfer?.cancel();
          transfer?.dispose();
          transfer = null;
          unawaited(controller.close());
        }
      },
      onCancel: () {
        cancelled = true;
        transfer?.cancel();
      },
    );
    return controller.stream;
  }
}

class _SharedImageStream {
  final Stream<ImageDownloadProgress> input;
  final void Function() onClosed;
  final listeners = <StreamController<ImageDownloadProgress>>{};
  StreamSubscription<ImageDownloadProgress>? subscription;
  _SharedImageStream(this.input, this.onClosed);
  Stream<ImageDownloadProgress> subscribe() {
    late StreamController<ImageDownloadProgress> controller;
    controller = StreamController(
      onListen: () {
        listeners.add(controller);
        subscription ??= input.listen(
          (event) {
            for (final listener in listeners.toList()) {
              listener.add(event);
            }
          },
          onError: (Object error, StackTrace stack) {
            for (final listener in listeners.toList()) {
              listener.addError(error, stack);
            }
          },
          onDone: cancel,
        );
      },
      onCancel: () {
        listeners.remove(controller);
        if (listeners.isEmpty) cancel();
      },
    );
    return controller.stream;
  }

  void cancel() {
    final active = subscription;
    subscription = null;
    unawaited(active?.cancel());
    final controllers = listeners.toList();
    listeners.clear();
    for (final controller in controllers) {
      unawaited(controller.close());
    }
    onClosed();
  }
}

class ImageDownloadProgress {
  final int currentBytes;
  final int? totalBytes;
  final Uint8List? imageBytes;
  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}

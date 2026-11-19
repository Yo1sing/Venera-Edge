import 'dart:async' show Future, StreamController, scheduleMicrotask;
import 'dart:math';
import 'dart:ui' as ui show Codec;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:venera_edge/foundation/log.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  static const int maxImagePixel = 2560 * 1440;

  static TargetImageSize _getTargetSize(int width, int height) {
    // ignore invalid size
    if (width <= 0 || height <= 0) {
      return TargetImageSize(width: width, height: height);
    }
    // ignore too wide or too tall image
    final imageRatio = width / height;
    if (imageRatio > 2 || imageRatio < 0.5) {
      return TargetImageSize(width: width, height: height);
    }
    // resize if too large
    if (width * height > maxImagePixel) {
      final ratio = sqrt(maxImagePixel / (width * height));
      return TargetImageSize(
        width: (width * ratio).round(),
        height: (height * ratio).round(),
      );
    }
    return TargetImageSize(width: width, height: height);
  }

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadBufferAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>(
          'Image provider: $this \n Image key: $key',
          this,
          style: DiagnosticsTreeStyle.errorProperty,
        );
      },
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    T key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      var stopped = false;
      chunkEvents.onCancel = () => stopped = true;
      void checkStop() {
        if (stopped) throw const _ImageLoadingStopException();
      }

      final data = await load(chunkEvents, checkStop);
      checkStop();
      if (data.isEmpty) throw Exception("Empty image data");

      try {
        final buffer = await ImmutableBuffer.fromUint8List(data);
        return decode(
          buffer,
          getTargetSize: enableResize ? _getTargetSize : null,
        );
      } catch (e) {
        await invalidateCache();
        rethrow;
      }
    } on _ImageLoadingStopException {
      rethrow;
    } catch (e, s) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      Log.error("Image Loading", e, s);
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  );

  String get key;

  Future<void> invalidateCache() async {}

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() {
    return "$runtimeType($key)";
  }

  bool get enableResize => false;
}

class _ImageLoadingStopException implements Exception {
  const _ImageLoadingStopException();
}

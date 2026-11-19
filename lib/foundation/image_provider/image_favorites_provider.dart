import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/comic_type.dart';
import 'package:venera_edge/foundation/history.dart';
import 'package:venera_edge/foundation/js_engine.dart';
import 'package:venera_edge/foundation/local.dart';
import 'package:venera_edge/src/rust/api/media.dart' as backend;
import 'base_image_provider.dart';

class ImageFavoritesProvider extends BaseImageProvider<ImageFavoritesProvider> {
  const ImageFavoritesProvider(this.imageFavorite);

  final ImageFavorite imageFavorite;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    backend.ImageTransfer? transfer;
    final previousOnCancel = chunkEvents?.onCancel;
    var cancelled = false;
    if (chunkEvents != null) {
      chunkEvents.onCancel = () {
        cancelled = true;
        transfer?.cancel();
        previousOnCancel?.call();
      };
    }
    try {
      checkStop?.call();
      transfer = await backend.ImageTransfer.startFavorite(
        runtime: JsEngine().runtime,
        dataPath: App.dataPath,
        cachePath: App.cachePath,
        localPath: LocalManager().path,
        comicType: ComicType.fromKey(imageFavorite.sourceKey).value,
        favoriteJson: jsonEncode(imageFavorite.toJson()),
      );
      if (cancelled) transfer.cancel();
      checkStop?.call();
      while (!cancelled) {
        final event = await transfer.next();
        checkStop?.call();
        if (event == null) break;
        if (event.error != null) throw StateError(event.error!);
        chunkEvents?.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.current,
            expectedTotalBytes: event.total,
          ),
        );
        if (event.bytes != null) return event.bytes!;
      }
      throw StateError('Image favorite loading cancelled');
    } finally {
      transfer?.cancel();
      transfer?.dispose();
      if (chunkEvents != null) chunkEvents.onCancel = previousOnCancel;
    }
  }

  static Future<void> deleteFromCache(ImageFavorite imageFavorite) async {
    await backend.deleteFavoriteImageCache(
      cachePath: App.cachePath,
      favoriteJson: jsonEncode(imageFavorite.toJson()),
    );
    await ImageFavoritesProvider(imageFavorite).evict();
  }

  @override
  Future<void> invalidateCache() => deleteFromCache(imageFavorite);

  @override
  Future<ImageFavoritesProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => jsonEncode([
    'ImageFavorites',
    imageFavorite.sourceKey,
    imageFavorite.id,
    imageFavorite.eid,
    imageFavorite.page,
  ]);
}

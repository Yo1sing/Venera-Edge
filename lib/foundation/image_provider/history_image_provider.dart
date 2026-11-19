import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_edge/network/images.dart';

import '../history.dart';
import 'base_image_provider.dart';

class HistoryImageProvider extends BaseImageProvider<HistoryImageProvider> {
  const HistoryImageProvider(this.history);

  final History history;

  Map<String, dynamic> get _request => {
    'kind': 'history_cover',
    'image': history.cover,
    'source': history.type.comicSource?.key,
    'comic': history.id,
    'comic_type': history.type.value,
  };

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunks,
    void Function() checkStop,
  ) => ImageDownloader.loadView(_request, chunks, checkStop);

  @override
  Future<void> invalidateCache() => ImageDownloader.invalidateView(_request);

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => "history${history.id}${history.type.value}";
}

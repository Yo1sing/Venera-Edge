import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_edge/network/images.dart';

import 'base_image_provider.dart';

class CachedImageProvider extends BaseImageProvider<CachedImageProvider> {
  const CachedImageProvider(
    this.url, {
    this.sourceKey,
    this.cid,
    this.fallbackToLocalCover = false,
  });

  final String url;
  final String? sourceKey;
  final String? cid;
  final bool fallbackToLocalCover;

  Map<String, dynamic> get _request => {
    'kind': 'thumbnail',
    'image': url,
    'source': sourceKey,
    'comic': cid ?? '',
    'fallback_type': fallbackToLocalCover && cid != null
        ? sourceKey?.hashCode
        : null,
  };

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent>? chunks,
    void Function()? checkStop,
  ) => ImageDownloader.loadView(_request, chunks, checkStop);

  @override
  Future<void> invalidateCache() => ImageDownloader.invalidateView(_request);

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => url + (sourceKey ?? "") + (cid ?? "");
}

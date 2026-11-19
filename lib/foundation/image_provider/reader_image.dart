import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/network/images.dart';

import 'base_image_provider.dart';

class ReaderImageProvider extends BaseImageProvider<ReaderImageProvider> {
  ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.enableResize = false,
  }) : processor = appdata.settings['enableCustomImageProcessing'] == true
           ? appdata.settings['customImageProcessing'] as String?
           : null;

  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;
  final int page;
  final String? processor;

  @override
  final bool enableResize;

  Map<String, dynamic> get _request => {
    'kind': 'reader',
    'image': imageKey,
    'source': sourceKey,
    'comic': cid,
    'chapter': eid,
    'page': page,
    'processor': processor,
  };

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunks,
    void Function() checkStop,
  ) => ImageDownloader.loadView(_request, chunks, checkStop);

  @override
  Future<void> invalidateCache() => ImageDownloader.invalidateView(_request);

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => jsonEncode([
    imageKey,
    sourceKey,
    cid,
    eid,
    page,
    enableResize,
    processor,
  ]);
}

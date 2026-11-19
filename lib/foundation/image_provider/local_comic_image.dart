import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:venera_edge/foundation/local.dart';
import 'package:venera_edge/network/images.dart';

import 'base_image_provider.dart';

class LocalComicImageProvider
    extends BaseImageProvider<LocalComicImageProvider> {
  const LocalComicImageProvider(this.comic);

  final LocalComic comic;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunks,
    void Function() checkStop,
  ) => ImageDownloader.loadView(
    {
      'kind': 'local_cover',
      'comic': comic.id,
      'comic_type': comic.comicType.value,
    },
    chunks,
    checkStop,
  );

  @override
  Future<LocalComicImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => jsonEncode([
    'local',
    comic.id,
    comic.comicType.value,
    comic.coverFile.path,
  ]);
}

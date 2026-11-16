import 'package:venera/utils/book_export.dart';
import 'package:venera/src/rust/api/archive.dart' as archive;
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';

class ComicMetaData {
  final String title;

  final String author;

  final List<String> tags;

  final List<ComicChapter>? chapters;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'tags': tags,
    'chapters': chapters?.map((e) => e.toJson()).toList(),
  };

  ComicMetaData.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      author = json['author'],
      tags = List<String>.from(json['tags']),
      chapters = json['chapters'] == null
          ? null
          : List<ComicChapter>.from(
              json['chapters'].map((e) => ComicChapter.fromJson(e)),
            );

  ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.chapters,
  });
}

class ComicChapter {
  final String title;

  final int start;

  final int end;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};

  ComicChapter.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      start = json['start'],
      end = json['end'];

  ComicChapter({required this.title, required this.start, required this.end});
}

/// Comic archive UI/platform adapter; parsing, layout and metadata are Rust-owned.
abstract class CBZ {
  static Future<void> extractArchive(File file, Directory out) =>
      archive.extractArchive(input: file.path, output: out.path);

  static Future<LocalComic> import(File file) async {
    final result = await LocalManager().runOperation({
      'mode': 'archive',
      'path': file.path,
    });
    final comics = result['imported'] as List;
    if (comics.isEmpty) throw StateError('Comic archive was not imported');
    return LocalComic.fromBackend(Map<String, dynamic>.from(comics.first));
  }

  static Future<File> export(LocalComic comic, String output) =>
      exportLocalBook(comic, output, 'cbz');
}

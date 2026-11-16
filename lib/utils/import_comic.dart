import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';
import 'io.dart';

class ImportComic {
  final String? selectedFolder;
  final bool copyToLocal;

  const ImportComic({this.selectedFolder, this.copyToLocal = true});

  Future<bool> _run(
    String mode,
    String path, [
    Map<String, dynamic> extra = const {},
  ]) async {
    try {
      final result = await LocalManager().runOperation({
        'mode': mode,
        'path': path,
        'folder': selectedFolder,
        'copy': copyToLocal,
        ...extra,
      });
      final count = (result['imported'] as List).length;
      final skipped = (result['skipped'] as List).length;
      if ((result['errors'] as List).isEmpty) {
        App.rootContext.showMessage(
          message: 'Imported @a comics'.tlParams({'a': count}),
        );
      }
      return count > 0 || skipped > 0;
    } catch (error, stack) {
      Log.error('Import Comic', error, stack);
      App.rootContext.showMessage(message: error.toString());
      return false;
    }
  }

  Future<bool> cbz() async {
    final file = await selectFile(ext: ['cbz', 'zip', '7z', 'cb7']);
    return file != null && await _run('archive', file.path);
  }

  Future<bool> multipleCbz() async {
    final directory = await DirectoryPicker().pickDirectory(directAccess: true);
    return directory != null && await _run('archives', directory.path);
  }

  Future<bool> ehViewer() async {
    final database = await selectFile(ext: ['db']);
    if (database == null) return false;
    final directory = await DirectoryPicker().pickDirectory();
    return directory != null &&
        await _run('ehviewer', directory.path, {
          'database': database.path,
          'default_folder': '(EhViewer)Default'.tl,
        });
  }

  Future<bool> directory(bool single) async {
    final directory = await DirectoryPicker().pickDirectory();
    return directory != null &&
        await _run(single ? 'directory' : 'directories', directory.path);
  }

  Future<bool> localDownloads() => _run(
    'local_downloads',
    LocalManager().path,
    {'copy': false, 'folder': null},
  );
}

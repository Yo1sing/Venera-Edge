import 'dart:async';
import 'package:venera_edge/src/rust/frb_generated.dart';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/cache_manager.dart';
import 'package:venera_edge/foundation/comic_source/comic_source.dart';
import 'package:venera_edge/foundation/js_engine.dart';
import 'package:venera_edge/foundation/log.dart';
import 'package:venera_edge/network/cookie_jar.dart';
import 'package:venera_edge/pages/comic_source_page.dart';
import 'package:venera_edge/pages/follow_updates_page.dart';
import 'package:venera_edge/pages/settings/settings_page.dart';
import 'package:venera_edge/utils/app_links.dart';
import 'package:venera_edge/utils/handle_text_share.dart';
import 'package:venera_edge/utils/opencc.dart';
import 'package:venera_edge/utils/tags_translation.dart';
import 'package:venera_edge/utils/translations.dart';
import 'foundation/appdata.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

Future<void> init() async {
  await RustLib.init();
  await App.init().wait();
  await SingleInstanceCookieJar.createInstance();
  try {
    var futures = [
      App.initComponents(),
      SAFTaskWorker().init().wait(),
      AppTranslation.init().wait(),
      TagsTranslation.readData().wait(),
      JsEngine().init().wait(),
      ComicSourceManager().init().wait(),
      OpenCC.init(),
    ];
    await Future.wait(futures);
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  }
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  if (App.isAndroid) {
    handleLinks();
    handleTextShare();
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch(e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
  if (App.isWindows) {
    // Report to the monitor thread that the app is running
    // https://github.com/venera-app/venera/issues/343
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('venera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
}

Future<void> _checkAppUpdates() async {
  var lastCheck = appdata.implicitData['lastCheckUpdate'] ?? 0;
  var now = DateTime.now().millisecondsSinceEpoch;
  if (now - lastCheck < 24 * 60 * 60 * 1000) {
    return;
  }
  appdata.setImplicitData('lastCheckUpdate', now);
  appdata.writeImplicitData();
  ComicSourcePage.checkComicSourceUpdate();
  if (appdata.settings['checkUpdateOnStart']) {
    await checkUpdateUi(false, true);
  }
}

void checkUpdates() {
  _checkAppUpdates();
  FollowUpdatesService.initChecker();
}

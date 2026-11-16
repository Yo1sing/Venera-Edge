import 'dart:async';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/src/rust/api/http.dart' as backend;

import 'cookie_jar.dart';

class CloudflareException implements DioException {
  final String url;
  final RequestOptions? _options;

  CloudflareException(this.url, {RequestOptions? options}) : _options = options;

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    const bridgePrefix = 'AnyhowException(';
    if (message.startsWith(bridgePrefix) && message.endsWith(')')) {
      message = message.substring(bridgePrefix.length, message.length - 1);
    }
    final url = RegExp(
      r'CloudflareException: (https?://[^\s]+)',
    ).firstMatch(message)?.group(1);
    return url == null ? null : CloudflareException(url);
  }

  @override
  DioException copyWith({
    RequestOptions? requestOptions,
    Response<dynamic>? response,
    DioExceptionType? type,
    Object? error,
    StackTrace? stackTrace,
    String? message,
  }) {
    return this;
  }

  @override
  Object? get error => this;

  @override
  String? get message => toString();

  @override
  RequestOptions get requestOptions => _options ?? RequestOptions(path: url);

  @override
  Response? get response => null;

  @override
  StackTrace get stackTrace => StackTrace.empty;

  @override
  DioExceptionType get type => DioExceptionType.badResponse;

  @override
  DioExceptionReadableStringBuilder? stringBuilder;
}

Future<void> passCloudflare(
  CloudflareException error,
  void Function() onFinished,
) async {
  final url = error.url;
  var active = true;
  var checking = false;
  var checkAgain = false;
  var verified = false;
  try {
    final jar = SingleInstanceCookieJar.instance!;
    final generation = jar.generation;

    Future<void> check({
      required Future<dynamic> Function(String) evaluate,
      required Future<String?> Function() userAgent,
      required Future<List<io.Cookie>> Function() cookies,
      required bool Function() isCurrent,
      required void Function() close,
    }) async {
      if (!active || !isCurrent()) return;
      if (checking) {
        checkAgain = true;
        return;
      }
      checking = true;
      try {
        final head = await evaluate('document.head && document.head.innerHTML');
        final body = await evaluate('document.body && document.body.innerHTML');
        if (head is! String ||
            body is! String ||
            backend.isCloudflareChallengePage(head: head, body: body)) {
          return;
        }
        final agent = await userAgent();
        if (agent == null || agent.isEmpty) return;
        final result = await cookies();
        if (!active || !isCurrent()) return;
        if (jar.completeCloudflare(url, result, agent, generation)) {
          verified = true;
          active = false;
          close();
        }
      } catch (error, stack) {
        if (active && isCurrent()) Log.error('Cloudflare', error, stack);
      } finally {
        checking = false;
        if (checkAgain) {
          checkAgain = false;
          unawaited(
            check(
              evaluate: evaluate,
              userAgent: userAgent,
              cookies: cookies,
              isCurrent: isCurrent,
              close: close,
            ),
          );
        }
      }
    }

    if (App.isLinux) {
      final closed = Completer<void>();
      final webview = DesktopWebview(
        initialUrl: url,
        onTitleChange: (_, controller) => unawaited(
          check(
            evaluate: controller.evaluateJavascript,
            userAgent: () async => controller.userAgent,
            cookies: controller.readCookies,
            isCurrent: () => !closed.isCompleted,
            close: controller.close,
          ),
        ),
        onClose: () => closed.complete(),
      );
      await webview.open();
      await closed.future;
    } else {
      await App.rootContext.to(
        () => Builder(
          builder: (context) {
            void checkPage(InAppWebViewController controller) {
              unawaited(
                check(
                  evaluate: (source) =>
                      controller.evaluateJavascript(source: source),
                  userAgent: controller.getUA,
                  cookies: () => controller.getCookies(url),
                  isCurrent: () =>
                      context.mounted &&
                      ModalRoute.of(context)?.isCurrent == true,
                  close: () => Navigator.of(context).pop(),
                ),
              );
            }

            return AppWebview(
              initialUrl: url,
              singlePage: true,
              onTitleChange: (_, controller) => checkPage(controller),
              onLoadStop: checkPage,
            );
          },
        ),
      );
    }
  } catch (error, stack) {
    Log.error('Cloudflare', error, stack);
  } finally {
    active = false;
    if (verified) onFinished();
  }
}

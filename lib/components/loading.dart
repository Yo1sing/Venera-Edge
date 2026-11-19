part of 'components.dart';

class NetworkError extends StatelessWidget {
  const NetworkError({
    super.key,
    required this.message,
    this.retry,
    this.withAppbar = true,
    this.buttonText,
    this.action,
  });

  final String message;

  final void Function()? retry;

  final bool withAppbar;

  final String? buttonText;

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    var cfe = CloudflareException.fromString(message);
    Widget body = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 28,
                  color: context.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  "Error".tl,
                  style: ts.withColor(context.colorScheme.error).s16,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            cfe == null ? message : "Cloudflare verification required".tl,
            textAlign: TextAlign.center,
            maxLines: 3,
          ),
          TextButton(
            onPressed: () {
              saveFile(
                data: utf8.encode(Log().toString()),
                filename: 'log.txt',
              );
            },
            child: Text("Export logs".tl),
          ),
          const SizedBox(height: 8),
          if (retry != null)
            if (cfe != null)
              FilledButton(
                onPressed: () => passCloudflare(
                  CloudflareException.fromString(message)!,
                  retry!,
                ),
                child: Text('Verify'.tl),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (action != null)
                    action!.paddingRight(8),
                  FilledButton(
                    onPressed: retry,
                    child: Text(buttonText ?? 'Retry'.tl),
                  ),
                ],
              ),
        ],
      ),
    );
    if (withAppbar) {
      body = Column(
        children: [
          const Appbar(title: Text("")),
          Expanded(child: body),
        ],
      );
    }
    return Material(child: body);
  }
}

class ListLoadingIndicator extends StatelessWidget {
  const ListLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: double.infinity,
      height: 80,
      child: Center(child: prism.ActivityIndicator()),
    );
  }
}

class SliverListLoadingIndicator extends StatelessWidget {
  const SliverListLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    // SliverToBoxAdapter can not been lazy loaded.
    // Use SliverList to make sure the animation can be lazy loaded.
    return SliverList.list(
      children: const [SizedBox(), ListLoadingIndicator()],
    );
  }
}

abstract class LoadingState<T extends StatefulWidget, S extends Object>
    extends State<T> {
  bool isLoading = false;

  S? data;

  String? error;

  Future<Res<S>> loadData();

  Future<Res<S>> loadDataWithRetry() async {
    int retry = 0;
    while (true) {
      var res = await loadData();
      if (res.success) {
        return res;
      } else {
        if (!mounted) return res;
        if (retry >= 3) {
          return res;
        }
        retry++;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  FutureOr<void> onDataLoaded() {}

  Widget buildContent(BuildContext context, S data);

  Widget? buildFrame(BuildContext context, Widget child) => null;

  Widget buildLoading() {
    return const Center(child: prism.ActivityIndicator.page());
  }

  void retry() {
    setState(() {
      isLoading = true;
      error = null;
    });
    loadDataWithRetry().then((value) async {
      if (value.success) {
        data = value.data;
        await onDataLoaded();
        setState(() {
          isLoading = false;
        });
      } else {
        setState(() {
          isLoading = false;
          error = value.errorMessage!;
        });
      }
    });
  }

  Widget buildError() {
    return NetworkError(message: error!, retry: retry);
  }

  @override
  @mustCallSuper
  void initState() {
    isLoading = true;
    Future.microtask(() {
      loadDataWithRetry().then((value) async {
        if (!mounted) return;
        if (value.success) {
          data = value.data;
          await onDataLoaded();
          setState(() {
            isLoading = false;
          });
        } else {
          setState(() {
            isLoading = false;
            error = value.errorMessage!;
          });
        }
      });
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    Widget child;

    if (isLoading) {
      child = buildLoading();
    } else if (error != null) {
      child = buildError();
    } else {
      child = buildContent(context, data!);
    }

    return buildFrame(context, child) ?? child;
  }
}

abstract class MultiPageLoadingState<T extends StatefulWidget, S extends Object>
    extends State<T> {
  bool _isFirstLoading = true;

  bool _isLoading = false;

  List<S>? data;

  String? _error;

  int _page = 1;

  int? _maxPage;

  Future<Res<List<S>>> loadData(int page);

  Widget? buildFrame(BuildContext context, Widget child) => null;

  Widget buildContent(BuildContext context, List<S> data);

  bool get isLoading => _isLoading || _isFirstLoading;

  bool get isFirstLoading => _isFirstLoading;

  bool get haveNextPage => _maxPage == null || _page <= _maxPage!;

  void nextPage() {
    if (_maxPage != null && _page > _maxPage!) return;
    if (_isLoading) return;
    _isLoading = true;
    loadData(_page).then((value) {
      _isLoading = false;
      if (mounted) {
        if (value.success) {
          _page++;
          if (value.subData is int) {
            _maxPage = value.subData as int;
          }
          setState(() {
            data!.addAll(value.data);
          });
        } else {
          var message = value.errorMessage ?? "Network Error";
          if (message.length > 20) {
            message = "${message.substring(0, 20)}...";
          }
          context.showMessage(message: message);
        }
      }
    });
  }

  void reset() {
    setState(() {
      _isFirstLoading = true;
      _isLoading = false;
      data = null;
      _error = null;
      _page = 1;
    });
    firstLoad();
  }

  void firstLoad() {
    Future.microtask(() {
      loadData(_page).then((value) {
        if (!mounted) return;
        if (value.success) {
          _page++;
          if (value.subData is int) {
            _maxPage = value.subData as int;
          }
          setState(() {
            _isFirstLoading = false;
            data = value.data;
          });
        } else {
          setState(() {
            _isFirstLoading = false;
            _error = value.errorMessage!;
          });
        }
      });
    });
  }

  @override
  void initState() {
    firstLoad();
    super.initState();
  }

  Widget buildLoading(BuildContext context) {
    return const Center(child: prism.ActivityIndicator.page());
  }

  Widget buildError(BuildContext context, String error) {
    return NetworkError(withAppbar: false, message: error, retry: reset);
  }

  @override
  Widget build(BuildContext context) {
    Widget child;

    if (_isFirstLoading) {
      child = buildLoading(context);
    } else if (_error != null) {
      child = buildError(context, _error!);
    } else {
      child = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.pixels ==
              notification.metrics.maxScrollExtent) {
            nextPage();
          }
          return false;
        },
        child: buildContent(context, data!),
      );
    }

    return buildFrame(context, child) ?? child;
  }
}

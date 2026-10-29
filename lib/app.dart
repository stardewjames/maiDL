import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/core/download_controller.dart';
import 'src/core/downloads_api.dart';
import 'src/ui/home_page.dart';
import 'src/ui/theme.dart';

class MaidlApp extends StatefulWidget {
  const MaidlApp({super.key, this.controller});

  /// Injectable for tests; when null the app talks to the native channel.
  final DownloadController? controller;

  @override
  State<MaidlApp> createState() => _MaidlAppState();
}

class _MaidlAppState extends State<MaidlApp> with WidgetsBindingObserver {
  late final bool _ownsController = widget.controller == null;
  late final DownloadController _controller =
      widget.controller ?? DownloadController(MethodChannelDownloadsApi());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A share-initiated download may have finished while we were away; the
    // native store is authoritative.
    if (state == AppLifecycleState.resumed) {
      _controller.refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: MaterialApp(
        title: 'maiDL',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: HomePage(controller: _controller),
      ),
    );
  }
}

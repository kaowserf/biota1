import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../screens/no_internet_screen.dart' show PageLoadErrorScreen;
import '../utils/bluetooth_bridge.dart';
import '../utils/bluetooth_js_polyfill.dart';
import '../utils/connectivity_helper.dart';

const String _kAppUrl = 'https://biota1.lovable.app/';
const String _kAppHost = 'biota1.lovable.app';

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen>
    with SingleTickerProviderStateMixin {
  late final WebViewController _controller;
  final ConnectivityHelper _connectivity = ConnectivityHelper();
  late final BluetoothBridge _bluetooth;
  late final StreamSubscription<bool> _connectivitySub;
  late final AnimationController _logoAnimController;
  late final Animation<double> _logoFadeAnimation;
  late final Animation<double> _logoScaleAnimation;

  bool _isLoading = true;
  bool _showSplash = true;
  bool _hasError = false;
  bool _isOffline = false;
  bool _isReconnecting = false;
  bool _isNoInternetDialogShowing = false;
  double _progress = 0;
  final Stopwatch _splashTimer = Stopwatch();

  static const Duration _minSplashDuration = Duration(milliseconds: 1500);
  static const Duration _splashFadeDuration = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    _splashTimer.start();

    _logoAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _logoFadeAnimation = CurvedAnimation(
      parent: _logoAnimController,
      curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
    );
    _logoScaleAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoAnimController,
        curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
      ),
    );

    _bluetooth = BluetoothBridge(
      onResultReady: _sendBluetoothResultToWeb,
    );

    _startup();
  }

  /// Send Bluetooth results from native back to the web page.
  void _sendBluetoothResultToWeb(String method, String data) {
    if (!_webViewInitialized) return;
    final escaped = data.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    _controller.runJavaScript(
      "window._bluetoothBridgeCallback('$method', '$escaped');",
    );
  }

  /// Handle messages from the web page's Bluetooth JS bridge.
  void _onBluetoothMessage(JavaScriptMessage message) {
    try {
      final msg = jsonDecode(message.message) as Map<String, dynamic>;
      final action = msg['action'] as String?;

      switch (action) {
        case 'requestDevice':
          final nameFilter = msg['nameFilter'] as String? ?? '';
          _bluetooth.showDevicePicker(context, nameFilter: nameFilter);
          break;
        case 'write':
          final data = msg['data'] as String? ?? '';
          final charUuid = msg['charUuid'] as String?;
          _bluetooth.writeData(data, charUuid: charUuid);
          break;
        case 'disconnect':
          _bluetooth.disconnect();
          break;
      }
    } catch (e) {
      debugPrint('Bluetooth bridge message error: $e');
    }
  }

  Future<void> _startup() async {
    // Remove native splash first, then run our own animated splash
    FlutterNativeSplash.remove();
    _logoAnimController.forward();

    // Request microphone & camera permissions upfront so WebView can use them
    await [
      Permission.microphone,
      Permission.camera,
    ].request();

    // Check connectivity before loading webview
    final connected = await _connectivity.checkConnectivity();
    if (!connected && mounted) {
      setState(() => _isOffline = true);
      _showNoInternetPopup();
      // Don't init webview yet — wait for retry
      _listenConnectivity();
      return;
    }

    _initWebView();
    _listenConnectivity();
  }

  bool _webViewInitialized = false;

  void _listenConnectivity() {
    _connectivitySub = _connectivity.onConnectionChange.listen((connected) {
      if (!mounted) return;
      if (connected) {
        _dismissNoInternetPopup();
        setState(() {
          _isOffline = false;
          _isReconnecting = true;
        });
        if (!_webViewInitialized) {
          _initWebView();
        } else {
          // Fresh load instead of reload to avoid cached error pages
          _controller.loadRequest(Uri.parse(_kAppUrl));
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Back online'),
            duration: Duration(seconds: 2),
            backgroundColor: Color(0xFF00b4d8),
          ),
        );
      } else {
        setState(() => _isOffline = true);
        _showNoInternetPopup();
      }
    });
  }

  void _showNoInternetPopup() {
    if (_isNoInternetDialogShowing || !mounted) return;
    _isNoInternetDialogShowing = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0xFF0a1628),
      builder: (ctx) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: const Color(0xFF1a2a3f),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/logo_splash.png',
                  width: 100,
                ),
                const SizedBox(height: 24),
                const Icon(
                  Icons.wifi_off_rounded,
                  size: 56,
                  color: Color(0xFF00b4d8),
                ),
                const SizedBox(height: 20),
                const Text(
                  'No Internet Connection',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                const Text(
                  'Please connect to the internet\nto use Biota1.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white60,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final connected =
                          await _connectivity.checkConnectivity();
                      if (connected && ctx.mounted) {
                        Navigator.of(ctx).pop();
                        _isNoInternetDialogShowing = false;
                        setState(() {
                          _isOffline = false;
                          _isReconnecting = true;
                        });
                        if (!_webViewInitialized) {
                          _initWebView();
                        } else {
                          _controller.loadRequest(Uri.parse(_kAppUrl));
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00b4d8),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Retry',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _dismissNoInternetPopup() {
    if (_isNoInternetDialogShowing && mounted) {
      Navigator.of(context).pop();
      _isNoInternetDialogShowing = false;
    }
  }

  void _initWebView() {
    _webViewInitialized = true;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0a1628))
      ..addJavaScriptChannel(
        'FlutterBluetooth',
        onMessageReceived: _onBluetoothMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            setState(() {
              _isLoading = true;
              _hasError = false;
            });
          },
          onPageFinished: (_) {
            // Inject Bluetooth polyfill after every page load
            _controller.runJavaScript(bluetoothJsPolyfill);
            setState(() {
              _isLoading = false;
              _isReconnecting = false;
            });
            _dismissSplash();
          },
          onProgress: (progress) {
            setState(() => _progress = progress / 100);
          },
          onNavigationRequest: (request) => _handleNavigation(request),
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
            if (error.isForMainFrame ?? false) {
              setState(() => _hasError = true);
              _dismissSplash();
            }
          },
        ),
      )
      ..setOnConsoleMessage((message) {
        debugPrint('WebView console: ${message.message}');
      });

    // Android-specific: grant mic/camera, enable debugging
    if (_controller.platform is AndroidWebViewController) {
      final android = _controller.platform as AndroidWebViewController;

      // Grant microphone & camera when web page requests them
      android.setOnPlatformPermissionRequest((request) {
        request.grant();
      });

      android.setMediaPlaybackRequiresUserGesture(false);
      AndroidWebViewController.enableDebugging(true);
    }

    // Enable JavaScript popups support
    _controller.setOnJavaScriptAlertDialog((request) async {
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(request.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    });

    _controller.setOnJavaScriptConfirmDialog((request) async {
      if (!mounted) return false;
      return await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              content: Text(request.message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('OK'),
                ),
              ],
            ),
          ) ??
          false;
    });

    // Load the app AFTER all handlers are configured
    _controller.loadRequest(Uri.parse(_kAppUrl));
  }

  Future<void> _dismissSplash() async {
    if (!_showSplash) return;

    final elapsed = _splashTimer.elapsed;
    if (elapsed < _minSplashDuration) {
      await Future.delayed(_minSplashDuration - elapsed);
    }
    _splashTimer.stop();

    if (mounted) {
      setState(() => _showSplash = false);
    }
  }

  // Auth-related hosts that must stay inside the WebView for login to work.
  static const _kAllowedHosts = <String>{
    _kAppHost,
    // Supabase auth
    'supabase.co',
    'supabase.com',
    // Google OAuth
    'accounts.google.com',
    'apis.google.com',
    // Apple sign-in
    'appleid.apple.com',
    // GitHub OAuth
    'github.com',
    // Microsoft OAuth
    'login.microsoftonline.com',
    'login.live.com',
  };

  NavigationDecision _handleNavigation(NavigationRequest request) {
    final uri = Uri.parse(request.url);

    // Handle mailto and tel links
    if (uri.scheme == 'mailto' || uri.scheme == 'tel') {
      launchUrl(uri);
      return NavigationDecision.prevent;
    }

    // Allow empty host (internal) and any auth-related domains
    if (uri.host == '' ||
        _kAllowedHosts.any((h) =>
            uri.host == h || uri.host.endsWith('.$h'))) {
      return NavigationDecision.navigate;
    }

    // External links — open in system browser
    launchUrl(uri, mode: LaunchMode.externalApplication);
    return NavigationDecision.prevent;
  }

  Future<bool> _showExitDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF1a2a3f),
            title: const Text(
              'Exit App?',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'Are you sure you want to exit Biota1?',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel',
                    style: TextStyle(color: Color(0xFF00b4d8))),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child:
                    const Text('Exit', style: TextStyle(color: Colors.white54)),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  void dispose() {
    _logoAnimController.dispose();
    _connectivitySub.cancel();
    _connectivity.dispose();
    _bluetooth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Page load error screen
    if (_hasError && !_isOffline && !_showSplash && !_isReconnecting) {
      return PageLoadErrorScreen(
        onRetry: () {
          setState(() {
            _hasError = false;
            _isReconnecting = true;
          });
          _controller.loadRequest(Uri.parse(_kAppUrl));
        },
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_webViewInitialized && await _controller.canGoBack()) {
          _controller.goBack();
        } else {
          final shouldExit = await _showExitDialog();
          if (shouldExit) {
            SystemNavigator.pop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0a1628),
        body: Stack(
          children: [
            // WebView layer (only when initialized)
            if (_webViewInitialized)
              SafeArea(
                child: Column(
                  children: [
                    if (_isLoading)
                      LinearProgressIndicator(
                        value: _progress,
                        backgroundColor: const Color(0xFF0a1628),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF00b4d8),
                        ),
                        minHeight: 3,
                      ),
                    Expanded(
                      child: WebViewWidget(controller: _controller),
                    ),
                  ],
                ),
              ),

            // Opaque cover to hide browser error pages during offline/error/reconnect
            if (_isOffline || _hasError || _isReconnecting)
              Container(
                color: const Color(0xFF0a1628),
                child: _isReconnecting
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF00b4d8),
                        ),
                      )
                    : const SizedBox.expand(),
              ),

            // Programmatic splash overlay with animated logo
            if (_showSplash)
              AnimatedOpacity(
                opacity: _showSplash ? 1.0 : 0.0,
                duration: _splashFadeDuration,
                child: Container(
                  color: const Color(0xFF0a1628),
                  child: Center(
                    child: FadeTransition(
                      opacity: _logoFadeAnimation,
                      child: ScaleTransition(
                        scale: _logoScaleAnimation,
                        child: Image.asset(
                          'assets/logo_splash.png',
                          width: MediaQuery.of(context).size.width * 0.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

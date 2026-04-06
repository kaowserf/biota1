import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityHelper {
  final Connectivity _connectivity = Connectivity();
  late StreamSubscription<ConnectivityResult> _subscription;
  final StreamController<bool> _connectionChangeController =
      StreamController<bool>.broadcast();

  Stream<bool> get onConnectionChange => _connectionChangeController.stream;

  bool _isConnected = true;
  bool get isConnected => _isConnected;

  ConnectivityHelper() {
    _subscription = _connectivity.onConnectivityChanged.listen(_updateStatus);
  }

  Future<bool> checkConnectivity() async {
    final result = await _connectivity.checkConnectivity();
    _isConnected = result != ConnectivityResult.none;
    return _isConnected;
  }

  void _updateStatus(ConnectivityResult result) {
    final wasConnected = _isConnected;
    _isConnected = result != ConnectivityResult.none;

    if (wasConnected != _isConnected) {
      _connectionChangeController.add(_isConnected);
    }
  }

  void dispose() {
    _subscription.cancel();
    _connectionChangeController.close();
  }
}

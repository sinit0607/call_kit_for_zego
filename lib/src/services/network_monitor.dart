import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../utils/rtc_logger.dart';

/// Monitors network connectivity status
/// Provides callbacks for network changes during calls
class NetworkMonitor {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  bool _isConnected = true;
  Function(bool isConnected)? onConnectivityChanged;

  /// Start monitoring network connectivity
  void startMonitoring() {
    RtcLogger.debug('Starting network monitoring');

    _subscription = _connectivity.onConnectivityChanged.listen(
      (List<ConnectivityResult> results) {
        _handleConnectivityChange(results);
      },
      onError: (error) {
        RtcLogger.error('Network monitoring error', error);
      },
    );

    // Check initial connectivity
    _checkInitialConnectivity();
  }

  /// Check initial connectivity status
  Future<void> _checkInitialConnectivity() async {
    try {
      final results = await _connectivity.checkConnectivity();
      _handleConnectivityChange(results);
    } catch (e) {
      RtcLogger.error('Failed to check initial connectivity', e);
    }
  }

  /// Handle connectivity changes
  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final wasConnected = _isConnected;

    // Consider connected if any connection type is available
    _isConnected = results.any((result) =>
      result != ConnectivityResult.none
    );

    if (wasConnected != _isConnected) {
      RtcLogger.info(
        'Network connectivity changed',
        {'connected': _isConnected, 'types': results.map((r) => r.name).join(', ')},
      );
      onConnectivityChanged?.call(_isConnected);
    }
  }

  /// Check if currently connected
  bool get isConnected => _isConnected;

  /// Stop monitoring
  void stopMonitoring() {
    RtcLogger.debug('Stopping network monitoring');
    _subscription?.cancel();
    _subscription = null;
    onConnectivityChanged = null;
  }
}

import 'dart:async';
import '../config/rtc_call_config.dart';
import '../utils/rtc_logger.dart';

/// Manages call timeouts for ringing state
/// Automatically cancels calls that aren't answered within configured timeout
/// WhatsApp-like behavior: 30 second default timeout
class CallTimeoutManager {
  final RtcCallConfig _config;
  Timer? _timeoutTimer;
  String? _currentCallId;
  Function(String callId)? _onTimeout;

  CallTimeoutManager(this._config);

  /// Start timeout timer for a call
  /// If call is not accepted before timeout, callback is triggered
  void startTimeout({
    required String callId,
    required Function(String callId) onTimeout,
    Duration? customTimeout,
  }) {
    // Cancel existing timer
    cancelTimeout();

    _currentCallId = callId;
    _onTimeout = onTimeout;

    final timeout = customTimeout ?? _config.ringingTimeout;

    RtcLogger.debug(
      'Starting call timeout timer',
      {'callId': callId, 'timeout': '${timeout.inSeconds}s'},
    );

    _timeoutTimer = Timer(timeout, () {
      RtcLogger.warning('Call timeout triggered', callId);
      _triggerTimeout(callId);
    });
  }

  /// Cancel the active timeout timer
  void cancelTimeout() {
    if (_timeoutTimer != null) {
      RtcLogger.debug('Cancelling timeout timer', _currentCallId);
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      _currentCallId = null;
      _onTimeout = null;
    }
  }

  /// Check if timeout is active for a call
  bool isTimeoutActive(String callId) {
    return _timeoutTimer != null &&
        _timeoutTimer!.isActive &&
        _currentCallId == callId;
  }

  /// Trigger timeout callback
  void _triggerTimeout(String callId) {
    final callback = _onTimeout;
    final savedCallId = _currentCallId;

    // Clear state before callback
    _timeoutTimer = null;
    _currentCallId = null;
    _onTimeout = null;

    // Trigger callback
    if (callback != null && savedCallId == callId) {
      callback(callId);
    }
  }

  /// Dispose resources
  void dispose() {
    cancelTimeout();
    RtcLogger.debug('CallTimeoutManager disposed');
  }
}

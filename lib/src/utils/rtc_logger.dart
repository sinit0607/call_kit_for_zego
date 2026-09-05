import 'package:flutter/foundation.dart';
import '../config/rtc_call_config.dart';

// Re-export RtcLogLevel for public API
export '../config/rtc_call_config.dart' show RtcLogLevel;

/// Internal logger for RTC Call Kit
/// Respects config.enableLogs flag and config.logLevel setting
class RtcLogger {
  static RtcCallConfig? _config;

  /// Initialize logger with configuration
  static void init(RtcCallConfig config) {
    _config = config;
  }

  /// Check if logging is enabled
  static bool get _isEnabled => _config?.enableLogs ?? false;

  /// Get current log level
  static RtcLogLevel get _logLevel => _config?.logLevel ?? RtcLogLevel.info;

  /// True when the configured level is at or below [level] in severity
  static bool _at(RtcLogLevel level) => _logLevel.index <= level.index;

  /// Check if audio debug is enabled
  static bool get _isAudioDebugEnabled =>
      _config?.enableAudioDebug == true;

  /// Check if audio debug should print (respects kDebugMode + audioDebugInProduction)
  static bool get _shouldPrintAudioDebug {
    if (!_isAudioDebugEnabled) return false;
    if (kDebugMode) return true;
    return _config?.audioDebugInProduction == true;
  }

  /// Log debug message
  static void debug(String message, [Object? data]) {
    if (!_isEnabled || !_at(RtcLogLevel.verbose)) return;
    print('[RTC_DEBUG] $message${data != null ? ' | $data' : ''}');
  }

  /// Log info message
  static void info(String message, [Object? data]) {
    if (!_isEnabled || !_at(RtcLogLevel.info)) return;
    print('[RTC_INFO] $message${data != null ? ' | $data' : ''}');
  }

  /// Log warning message
  static void warning(String message, [Object? data]) {
    if (!_isEnabled || !_at(RtcLogLevel.warning)) return;
    print('[RTC_WARNING] $message${data != null ? ' | $data' : ''}');
  }

  /// Log error message (always logged, even if logging disabled)
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    print('[RTC_ERROR] $message${error != null ? ' | $error' : ''}');
    if (stackTrace != null && _isEnabled) {
      print(stackTrace);
    }
  }

  /// Log success message
  static void success(String message, [Object? data]) {
    if (!_isEnabled || !_at(RtcLogLevel.info)) return;
    print('[RTC_SUCCESS] $message${data != null ? ' | $data' : ''}');
  }

  /// Log flow step
  static void flowStep(String flow, String step, [Map<String, dynamic>? data]) {
    if (!_isEnabled || !_at(RtcLogLevel.info)) return;
    print('[RTC_FLOW:$flow] $step${data != null ? ' | $data' : ''}');
  }

  // ════════════════════════════════════════════════════════════════════════
  // COMPREHENSIVE AUDIO DEBUG LOGGING
  // All audio logs use ANSI red color (\x1B[91m) and [AUDIO_CALL] tag
  // ════════════════════════════════════════════════════════════════════════

  /// ANSI red color prefix for audio logs
  static const String _red = '\x1B[91m';

  /// Reset ANSI color
  static const String _reset = '\x1B[0m';

  /// Log comprehensive audio call debug info
  /// Uses red color + [AUDIO_CALL] tag for maximum visibility
  static void audioCall({
    String? userId,
    String? peerId,
    String? roomId,
    String? streamId,
    String? callType,
    required String step,
    String? detail,
  }) {
    if (!_shouldPrintAudioDebug) return;
    final timestamp = DateTime.now().toIso8601String();
    const audioCallTag = 'AUDIO_CALL';
    const audioDebugTag = 'AUDIO_DEBUG';
    final buffer = StringBuffer();
    buffer.write('[$_red[$audioCallTag]$_reset]');
    buffer.write('[$_red[$audioDebugTag]$_reset] ');
    buffer.write('$timestamp | ');
    if (userId != null) buffer.write('userId=$userId | ');
    if (peerId != null) buffer.write('peerId=$peerId | ');
    if (roomId != null) buffer.write('roomId=$roomId | ');
    if (streamId != null) buffer.write('streamId=$streamId | ');
    if (callType != null) buffer.write('callType=$callType | ');
    buffer.write('step=$step');
    if (detail != null) buffer.write(' | detail=$detail');
    print(buffer.toString());
  }

  /// Log audio capture device state
  static void audioCapture({
    required bool enabled,
    required String streamId,
    String? userId,
    String? roomId,
    String? peerId,
  }) {
    if (!_shouldPrintAudioDebug) return;
    final state = enabled ? 'ENABLED' : 'DISABLED';
    final buffer = StringBuffer();
    buffer.write('[$_red[AUDIO_CAPTURE]$_reset] ');
    buffer.write('Audio capture $state | streamId=$streamId');
    if (userId != null) buffer.write(' | userId=$userId');
    if (roomId != null) buffer.write(' | roomId=$roomId');
    if (peerId != null) buffer.write(' | peerId=$peerId');
    print(buffer.toString());
  }

  /// Log audio stream publish attempt
  static void audioPublish({
    required String streamId,
    required bool success,
    String? userId,
    String? roomId,
    String? peerId,
    String? error,
  }) {
    if (!_shouldPrintAudioDebug) return;
    final result = success ? 'SUCCESS' : 'FAILED';
    final buffer = StringBuffer();
    buffer.write('[$_red[AUDIO_PUBLISH]$_reset] ');
    buffer.write('Audio publish $result | streamId=$streamId');
    if (userId != null) buffer.write(' | userId=$userId');
    if (roomId != null) buffer.write(' | roomId=$roomId');
    if (peerId != null) buffer.write(' | peerId=$peerId');
    if (error != null) buffer.write(' | error=$error');
    print(buffer.toString());
  }

  /// Log audio stream subscribe/play attempt
  static void audioSubscribe({
    required String streamId,
    required bool success,
    String? userId,
    String? roomId,
    String? peerId,
    String? error,
  }) {
    if (!_shouldPrintAudioDebug) return;
    final result = success ? 'SUCCESS' : 'FAILED';
    final buffer = StringBuffer();
    buffer.write('[$_red[AUDIO_SUBSCRIBE]$_reset] ');
    buffer.write('Audio subscribe $result | streamId=$streamId');
    if (userId != null) buffer.write(' | userId=$userId');
    if (roomId != null) buffer.write(' | roomId=$roomId');
    if (peerId != null) buffer.write(' | peerId=$peerId');
    if (error != null) buffer.write(' | error=$error');
    print(buffer.toString());
  }

  /// Log audio track enabled/muted state
  static void audioTrackState({
    required String trackId,
    required bool enabled,
    required bool muted,
    String? streamId,
    String? userId,
  }) {
    if (!_shouldPrintAudioDebug) return;
    final state = enabled ? (muted ? 'ENABLED+MUTED' : 'ENABLED+UNMUTED') : 'DISABLED';
    final buffer = StringBuffer();
    buffer.write('[$_red[AUDIO_TRACK]$_reset] ');
    buffer.write('Track state: $state | trackId=$trackId');
    if (streamId != null) buffer.write(' | streamId=$streamId');
    if (userId != null) buffer.write(' | userId=$userId');
    print(buffer.toString());
  }

  /// Log device routing (speaker/earpiece)
  static void audioRouting({
    required String fromRoute,
    required String toRoute,
    String? streamId,
  }) {
    if (!_shouldPrintAudioDebug) return;
    final buffer = StringBuffer();
    buffer.write('[$_red[AUDIO_ROUTING]$_reset] ');
    buffer.write('Route: $fromRoute -> $toRoute');
    if (streamId != null) buffer.write(' | streamId=$streamId');
    print(buffer.toString());
  }

  /// Log signaling events for audio sessions
  static void audioSignaling({
    required String event,
    required String direction,
    Map<String, dynamic>? metadata,
  }) {
    if (!_shouldPrintAudioDebug) return;
    final buffer = StringBuffer();
    buffer.write('[$_red[AUDIO_SIGNAL]$_reset] ');
    buffer.write('Signaling: $event | direction=$direction');
    if (metadata != null) buffer.write(' | $metadata');
    print(buffer.toString());
  }

  // ════════════════════════════════════════════════════════════════════════
  // AUDIO-SPECIFIC LOGGING
  // Critical paths that were previously silent in production
  // ════════════════════════════════════════════════════════════════════════

  /// Log audio route change (e.g., speaker <-> earpiece)
  static void audioRouteChange({
    required String from,
    required String to,
    bool success = true,
    String? error,
  }) {
    if (!_isEnabled || !_at(RtcLogLevel.info)) return;

    if (success) {
      print('[RTC_AUDIO_ROUTE] Route changed: $from -> $to');
    } else {
      print('[RTC_AUDIO_ROUTE] Route change FAILED: $from -> $to${error != null ? ' | Error: $error' : ''}');
    }
  }

  /// Log stream play confirmation
  static void streamPlayStarted({
    required String streamId,
    bool success = true,
    String? error,
    String? audioRoute,
  }) {
    if (!_isEnabled || !_at(RtcLogLevel.info)) return;

    if (success) {
      final routeInfo = audioRoute != null ? ' | Audio route: $audioRoute' : '';
      print('[RTC_AUDIO_STREAM] Stream playback started: $streamId$routeInfo');
    } else {
      print('[RTC_AUDIO_STREAM] Stream playback FAILED: $streamId${error != null ? ' | Error: $error' : ''}');
    }
  }

  /// Log microphone mute state change
  static void microphoneStateChange({
    required bool isMuted,
    bool success = true,
    String? error,
  }) {
    if (!_isEnabled || !_at(RtcLogLevel.info)) return;

    final state = isMuted ? 'MUTED' : 'UNMUTED';
    if (success) {
      print('[RTC_AUDIO_MIC] Microphone $state');
    } else {
      print('[RTC_AUDIO_MIC] Microphone state change FAILED: $state${error != null ? ' | Error: $error' : ''}');
    }
  }

  /// Log audio capture device state
  static void audioCaptureDevice({
    required bool enabled,
    bool success = true,
    String? error,
  }) {
    if (!_isEnabled || !_at(RtcLogLevel.verbose)) return;

    final state = enabled ? 'ENABLED' : 'DISABLED';
    if (success) {
      print('[RTC_AUDIO_CAPTURE] Audio capture device $state');
    } else {
      print('[RTC_AUDIO_CAPTURE] Audio capture device state change FAILED: $state${error != null ? ' | Error: $error' : ''}');
    }
  }

  /// Log audio configuration applied
  static void audioConfigApplied({
    required int bitrate,
    required String channel,
    required bool echoCancellation,
    required bool noiseSuppression,
    required bool autoGainControl,
  }) {
    if (!_isEnabled || !_at(RtcLogLevel.info)) return;

    print('[RTC_AUDIO_CONFIG] Audio configuration applied:'
        ' bitrate=${bitrate}kbps, channel=$channel,'
        ' AEC=$echoCancellation, ANS=$noiseSuppression, AGC=$autoGainControl');
  }

  /// Log speaker state
  static void speakerState({
    required bool enabled,
    bool success = true,
    String? error,
  }) {
    if (!_isEnabled || !_at(RtcLogLevel.info)) return;

    final state = enabled ? 'ENABLED' : 'DISABLED';
    if (success) {
      print('[RTC_AUDIO_SPEAKER] Speaker $state');
    } else {
      print('[RTC_AUDIO_SPEAKER] Speaker state change FAILED: $state${error != null ? ' | Error: $error' : ''}');
    }
  }
}

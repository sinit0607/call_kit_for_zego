/// Analytics plugin interface for call tracking
///
/// Implement this interface to integrate your analytics service (Firebase, Mixpanel, etc.)
///
/// Example implementation:
/// ```dart
/// class FirebaseAnalyticsPlugin implements AnalyticsPlugin {
///   final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;
///
///   @override
///   Future<void> logCallStarted({...}) async {
///     await _analytics.logEvent(name: 'call_started', parameters: {...});
///   }
/// }
/// ```
abstract class AnalyticsPlugin {
  /// Log when a call is initiated
  Future<void> logCallStarted({
    required String callId,
    required String callType,
    required String callerId,
    required String calleeId,
    bool isOutgoing = true,
  });

  /// Log when a call is connected (both parties joined)
  Future<void> logCallConnected({
    required String callId,
    required String callType,
    int? timeToConnectMs,
  });

  /// Log when a call ends
  Future<void> logCallEnded({
    required String callId,
    required String callType,
    required String endReason,
    int? durationSeconds,
    int? totalDurationMs,
  });

  /// Log when a call fails
  Future<void> logCallFailed({
    required String callId,
    String? failureStage,
    String? failureReason,
    String? errorCode,
    int? timeToFailureMs,
  });

  /// Log call quality metrics
  Future<void> logCallQuality({
    required String callId,
    int? audioPacketLoss,
    int? videoPacketLoss,
    int? networkLatency,
    String? qualityRating,
  });

  /// Track custom funnel events
  Future<void> trackFunnelStep({
    required String callId,
    required String stepName,
    Map<String, dynamic>? metadata,
  });
}

/// Default no-op implementation (does nothing)
class NoOpAnalyticsPlugin implements AnalyticsPlugin {
  @override
  Future<void> logCallStarted({
    required String callId,
    required String callType,
    required String callerId,
    required String calleeId,
    bool isOutgoing = true,
  }) async {}

  @override
  Future<void> logCallConnected({
    required String callId,
    required String callType,
    int? timeToConnectMs,
  }) async {}

  @override
  Future<void> logCallEnded({
    required String callId,
    required String callType,
    required String endReason,
    int? durationSeconds,
    int? totalDurationMs,
  }) async {}

  @override
  Future<void> logCallFailed({
    required String callId,
    String? failureStage,
    String? failureReason,
    String? errorCode,
    int? timeToFailureMs,
  }) async {}

  @override
  Future<void> logCallQuality({
    required String callId,
    int? audioPacketLoss,
    int? videoPacketLoss,
    int? networkLatency,
    String? qualityRating,
  }) async {}

  @override
  Future<void> trackFunnelStep({
    required String callId,
    required String stepName,
    Map<String, dynamic>? metadata,
  }) async {}
}

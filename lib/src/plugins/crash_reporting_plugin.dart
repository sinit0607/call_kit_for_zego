/// Crash reporting plugin interface
///
/// Implement this interface to integrate your crash reporting service
/// (Firebase Crashlytics, Sentry, etc.)
///
/// Example implementation:
/// ```dart
/// class FirebaseCrashlyticsPlugin implements CrashReportingPlugin {
///   final FirebaseCrashlytics _crashlytics = FirebaseCrashlytics.instance;
///
///   @override
///   Future<void> recordError(dynamic error, StackTrace? stackTrace, {String? reason}) async {
///     await _crashlytics.recordError(error, stackTrace, reason: reason);
///   }
/// }
/// ```
abstract class CrashReportingPlugin {
  /// Record a non-fatal error
  Future<void> recordError(
    dynamic error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  });

  /// Record a call flow error with context
  Future<void> recordCallFlowError(
    String flowStep,
    String errorMessage,
    StackTrace? stackTrace, {
    String? callId,
    Map<String, dynamic>? context,
  });

  /// Set custom key-value pairs for crash context
  Future<void> setCustomKey(String key, dynamic value);

  /// Set user identifier for crash reports
  Future<void> setUserId(String userId);

  /// Log a message that will be attached to crash reports
  Future<void> log(String message);
}

/// Default no-op implementation (does nothing)
class NoOpCrashReportingPlugin implements CrashReportingPlugin {
  @override
  Future<void> recordError(
    dynamic error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) async {}

  @override
  Future<void> recordCallFlowError(
    String flowStep,
    String errorMessage,
    StackTrace? stackTrace, {
    String? callId,
    Map<String, dynamic>? context,
  }) async {}

  @override
  Future<void> setCustomKey(String key, dynamic value) async {}

  @override
  Future<void> setUserId(String userId) async {}

  @override
  Future<void> log(String message) async {}
}

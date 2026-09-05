/// Represents an error in the communication service
class CommunicationError {
  /// Error code
  final String code;

  /// Human-readable error message
  final String message;

  /// Source of the error (e.g., 'ZEGO', 'Socket', 'CallKit')
  final String? source;

  /// Original exception (if any)
  final dynamic exception;

  /// Stack trace (if available)
  final StackTrace? stackTrace;

  /// Additional context
  final Map<String, dynamic>? context;

  const CommunicationError({
    required this.code,
    required this.message,
    this.source,
    this.exception,
    this.stackTrace,
    this.context,
  });

  /// Create error from exception
  factory CommunicationError.fromException(
    dynamic exception, [
    StackTrace? stackTrace,
  ]) {
    return CommunicationError(
      code: 'UNKNOWN_ERROR',
      message: exception.toString(),
      exception: exception,
      stackTrace: stackTrace,
    );
  }

  /// Initialization error
  factory CommunicationError.initialization({
    required String message,
    dynamic exception,
    StackTrace? stackTrace,
  }) {
    return CommunicationError(
      code: 'INITIALIZATION_ERROR',
      message: message,
      source: 'Initialization',
      exception: exception,
      stackTrace: stackTrace,
    );
  }

  /// Call-related error
  factory CommunicationError.call({
    required String message,
    dynamic exception,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) {
    return CommunicationError(
      code: 'CALL_ERROR',
      message: message,
      source: 'Call',
      exception: exception,
      stackTrace: stackTrace,
      context: context,
    );
  }

  /// Chat-related error
  factory CommunicationError.chat({
    required String message,
    dynamic exception,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) {
    return CommunicationError(
      code: 'CHAT_ERROR',
      message: message,
      source: 'Chat',
      exception: exception,
      stackTrace: stackTrace,
      context: context,
    );
  }

  /// Network error
  factory CommunicationError.network({
    required String message,
    Map<String, dynamic>? context,
  }) {
    return CommunicationError(
      code: 'NETWORK_ERROR',
      message: message,
      source: 'Network',
      context: context,
    );
  }

  /// ZEGO SDK error
  factory CommunicationError.zego({
    required int errorCode,
    required String message,
  }) {
    return CommunicationError(
      code: 'ZEGO_$errorCode',
      message: message,
      source: 'ZEGO',
    );
  }

  /// Socket error
  factory CommunicationError.socket({
    required String message,
    Map<String, dynamic>? context,
  }) {
    return CommunicationError(
      code: 'SOCKET_ERROR',
      message: message,
      source: 'Socket',
      context: context,
    );
  }

  /// CallKit error
  factory CommunicationError.callKit({
    required String message,
    Map<String, dynamic>? context,
  }) {
    return CommunicationError(
      code: 'CALLKIT_ERROR',
      message: message,
      source: 'CallKit',
      context: context,
    );
  }

  /// Invalid state error
  factory CommunicationError.invalidState({
    required String message,
  }) {
    return CommunicationError(
      code: 'INVALID_STATE',
      message: message,
    );
  }

  /// Permission denied error
  factory CommunicationError.permissionDenied({
    required String permission,
  }) {
    return CommunicationError(
      code: 'PERMISSION_DENIED',
      message: 'Permission denied: $permission',
    );
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        'source': source,
        'context': context,
      };

  @override
  String toString() {
    final buffer = StringBuffer('CommunicationError($code: $message');
    if (source != null) buffer.write(', source: $source');
    if (context != null) buffer.write(', context: $context');
    buffer.write(')');
    return buffer.toString();
  }
}

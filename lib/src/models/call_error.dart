/// Represents an error that occurred during a call
/// Includes error classification for better handling
class CallError {
  /// Unique error code
  final String code;

  /// Human-readable error message
  final String message;

  /// Whether this error is recoverable (can retry)
  final bool isRecoverable;

  /// Original exception (if any)
  final Object? exception;

  /// Stack trace (if any)
  final StackTrace? stackTrace;

  /// Additional error details
  final Map<String, dynamic>? details;

  const CallError({
    required this.code,
    required this.message,
    this.isRecoverable = false,
    this.exception,
    this.stackTrace,
    this.details,
  });

  /// Common error codes
  static const String codeEngineNotInitialized = 'ENGINE_NOT_INITIALIZED';
  static const String codeNetworkError = 'NETWORK_ERROR';
  static const String codePermissionDenied = 'PERMISSION_DENIED';
  static const String codeRoomJoinFailed = 'ROOM_JOIN_FAILED';
  static const String codeStreamPublishFailed = 'STREAM_PUBLISH_FAILED';
  static const String codeStreamPlayFailed = 'STREAM_PLAY_FAILED';
  static const String codeCallTimeout = 'CALL_TIMEOUT';
  static const String codeCallRejected = 'CALL_REJECTED';
  static const String codeUserBusy = 'USER_BUSY';
  static const String codeInvalidState = 'INVALID_STATE';
  static const String codeInvalidInput = 'INVALID_INPUT';
  static const String codeUnknown = 'UNKNOWN';

  /// Create error for engine not initialized
  factory CallError.engineNotInitialized({String? message}) {
    return CallError(
      code: codeEngineNotInitialized,
      message: message ?? 'ZEGOCLOUD engine not initialized',
      isRecoverable: true,
    );
  }

  /// Create error for network failure
  factory CallError.networkError({String? message, Object? exception}) {
    return CallError(
      code: codeNetworkError,
      message: message ?? 'Network connection failed',
      isRecoverable: true,
      exception: exception,
    );
  }

  /// Create error for permission denied
  factory CallError.permissionDenied({String? message}) {
    return CallError(
      code: codePermissionDenied,
      message: message ?? 'Camera or microphone permission denied',
      isRecoverable: false,
    );
  }

  /// Create error for room join failure
  factory CallError.roomJoinFailed({String? message, Object? exception}) {
    return CallError(
      code: codeRoomJoinFailed,
      message: message ?? 'Failed to join call room',
      isRecoverable: true,
      exception: exception,
    );
  }

  /// Create error for stream publish failure
  factory CallError.streamPublishFailed({String? message, Object? exception}) {
    return CallError(
      code: codeStreamPublishFailed,
      message: message ?? 'Failed to publish audio/video stream',
      isRecoverable: true,
      exception: exception,
    );
  }

  /// Create error for stream play failure
  factory CallError.streamPlayFailed({String? message, Object? exception}) {
    return CallError(
      code: codeStreamPlayFailed,
      message: message ?? 'Failed to play remote stream',
      isRecoverable: true,
      exception: exception,
    );
  }

  /// Create error for call timeout
  factory CallError.callTimeout({String? message}) {
    return CallError(
      code: codeCallTimeout,
      message: message ?? 'Call timed out',
      isRecoverable: false,
    );
  }

  /// Create error for call rejected
  factory CallError.callRejected({String? message}) {
    return CallError(
      code: codeCallRejected,
      message: message ?? 'Call was rejected',
      isRecoverable: false,
    );
  }

  /// Create error for user busy
  factory CallError.userBusy({String? message}) {
    return CallError(
      code: codeUserBusy,
      message: message ?? 'User is busy with another call',
      isRecoverable: false,
    );
  }

  /// Create error for invalid state
  factory CallError.invalidState({required String message}) {
    return CallError(
      code: codeInvalidState,
      message: message,
      isRecoverable: false,
    );
  }

  /// Create error for invalid input
  factory CallError.invalidInput({required String message, Map<String, dynamic>? details}) {
    return CallError(
      code: codeInvalidInput,
      message: message,
      isRecoverable: false,
      details: details,
    );
  }

  /// Create unknown error
  factory CallError.unknown({String? message, Object? exception, StackTrace? stackTrace}) {
    return CallError(
      code: codeUnknown,
      message: message ?? 'An unknown error occurred',
      isRecoverable: false,
      exception: exception,
      stackTrace: stackTrace,
    );
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'message': message,
      'isRecoverable': isRecoverable,
      'details': details,
    };
  }

  @override
  String toString() {
    return 'CallError(code: $code, message: $message, isRecoverable: $isRecoverable)';
  }
}

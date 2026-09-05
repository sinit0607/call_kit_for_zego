import '../../../call_kit_for_zego.dart';

/// Types of call events that can occur
enum CallEventType {
  /// New incoming call received
  incomingCall,

  /// Call was accepted by remote party
  callAccepted,

  /// Call was declined by remote party
  callDeclined,

  /// Session started - server confirmed session is active
  /// This is the SINGLE SOURCE OF TRUTH to navigate to call screen
  sessionStarted,

  /// Call has ended
  callEnded,

  /// Call successfully connected and media is flowing
  callConnected,

  /// Call was disconnected (network issue)
  callDisconnected,

  /// Call failed to establish
  callFailed,

  /// Remote user joined the call
  remoteUserJoined,

  /// Remote user left the call
  remoteUserLeft,

  /// Mute state changed
  muteStateChanged,

  /// Speaker state changed
  speakerStateChanged,

  /// Call timeout
  callTimeout,
}

/// Event emitted by the communication service for call-related events
class CallEvent {
  /// Type of the event
  final CallEventType type;

  /// Unique call identifier
  final String callId;

  /// Remote user information (if applicable)
  final UserInfo? remoteUser;

  /// Type of call (audio/video)
  final CallType? callType;

  /// When the event occurred
  final DateTime timestamp;

  /// Additional metadata
  final Map<String, dynamic>? metadata;

  /// Error message (if applicable)
  final String? errorMessage;

  /// Convenience getter for sessionId from metadata
  String? get sessionId => metadata?['sessionId'] as String?;

  /// Convenience getter for roomId from metadata
  String? get roomId => metadata?['roomId'] as String?;

  const CallEvent({
    required this.type,
    required this.callId,
    this.remoteUser,
    this.callType,
    required this.timestamp,
    this.metadata,
    this.errorMessage,
  });

  // Convenience constructors for common events

  factory CallEvent.incomingCall({
    required String callId,
    required UserInfo remoteUser,
    required CallType callType,
    Map<String, dynamic>? metadata,
  }) {
    return CallEvent(
      type: CallEventType.incomingCall,
      callId: callId,
      remoteUser: remoteUser,
      callType: callType,
      timestamp: DateTime.now(),
      metadata: metadata,
    );
  }

  factory CallEvent.callAccepted({
    required String callId,
    UserInfo? remoteUser,
  }) {
    return CallEvent(
      type: CallEventType.callAccepted,
      callId: callId,
      remoteUser: remoteUser,
      timestamp: DateTime.now(),
    );
  }

  factory CallEvent.callDeclined({
    required String callId,
    String? reason,
  }) {
    return CallEvent(
      type: CallEventType.callDeclined,
      callId: callId,
      timestamp: DateTime.now(),
      metadata: {'reason': reason},
    );
  }

  factory CallEvent.sessionStarted({
    required String callId,
    required String sessionId,
    required String roomId,
    required CallType callType,
    // Required to address the peer's media — the app builds the remote video
    // view from the room and the peer's id. Omitting it left the remote view
    // unbuildable and the call screen black.
    UserInfo? remoteUser,
    Map<String, dynamic>? metadata,
  }) {
    return CallEvent(
      type: CallEventType.sessionStarted,
      callId: callId,
      callType: callType,
      remoteUser: remoteUser,
      timestamp: DateTime.now(),
      metadata: {
        'sessionId': sessionId,
        'roomId': roomId,
        ...?metadata,
      },
    );
  }

  factory CallEvent.callEnded({
    required String callId,
    String? reason,
  }) {
    return CallEvent(
      type: CallEventType.callEnded,
      callId: callId,
      timestamp: DateTime.now(),
      metadata: {'reason': reason},
    );
  }

  factory CallEvent.callConnected({
    required String callId,
    Map<String, dynamic>? metadata,
  }) {
    return CallEvent(
      type: CallEventType.callConnected,
      callId: callId,
      timestamp: DateTime.now(),
      metadata: metadata,
    );
  }

  factory CallEvent.callFailed({
    required String callId,
    required String error,
  }) {
    return CallEvent(
      type: CallEventType.callFailed,
      callId: callId,
      timestamp: DateTime.now(),
      errorMessage: error,
    );
  }

  factory CallEvent.callTimeout({
    required String callId,
  }) {
    return CallEvent(
      type: CallEventType.callTimeout,
      callId: callId,
      timestamp: DateTime.now(),
    );
  }

  factory CallEvent.remoteUserJoined({
    required String callId,
    required UserInfo remoteUser,
  }) {
    return CallEvent(
      type: CallEventType.remoteUserJoined,
      callId: callId,
      remoteUser: remoteUser,
      timestamp: DateTime.now(),
    );
  }

  factory CallEvent.remoteUserLeft({
    required String callId,
    required UserInfo remoteUser,
  }) {
    return CallEvent(
      type: CallEventType.remoteUserLeft,
      callId: callId,
      remoteUser: remoteUser,
      timestamp: DateTime.now(),
    );
  }

  factory CallEvent.callConnecting({
    required String callId,
  }) {
    return CallEvent(
      type: CallEventType.callConnected,
      callId: callId,
      timestamp: DateTime.now(),
    );
  }

  factory CallEvent.callDisconnected({
    required String callId,
    String? reason,
  }) {
    return CallEvent(
      type: CallEventType.callDisconnected,
      callId: callId,
      timestamp: DateTime.now(),
      metadata: {'reason': reason},
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'callId': callId,
        'remoteUser': remoteUser?.toJson(),
        'callType': callType?.name,
        'timestamp': timestamp.toIso8601String(),
        'metadata': metadata,
        'errorMessage': errorMessage,
      };

  @override
  String toString() =>
      'CallEvent(type: ${type.name}, callId: $callId, remoteUser: ${remoteUser?.userName})';
}

/// Events that flow through the signaling channel
///
/// These events are sent between peers to negotiate calls.
/// Your app sends these through your socket/signaling system.
enum RtcSignalingEventType {
  /// Caller sends this to callee to initiate a call
  callOffer,

  /// Callee sends this to accept the call
  callAnswer,

  /// Either party sends this to reject/decline the call
  callReject,

  /// Either party sends this to cancel an ongoing call
  callCancel,

  /// Either party sends this to end an active call
  callEnd,

  /// Sent when call times out (no answer)
  callTimeout,

  /// Sent when user is busy (already in another call)
  callBusy,

  /// ICE candidate exchange (for WebRTC, not needed for ZEGO)
  iceCandidate,
}

/// A signaling event that should be sent through your signaling channel
///
/// Your app receives this from the controller and sends it via socket/signaling.
class RtcSignalingEvent {
  /// Type of signaling event
  final RtcSignalingEventType type;

  /// Unique call identifier
  final String callId;

  /// User who initiated this event
  final String fromUserId;

  /// User who should receive this event
  final String toUserId;

  /// Call type (audio/video)
  final String? callType;

  /// ZEGO room ID for the call
  final String? roomId;

  /// Additional metadata
  final Map<String, dynamic>? metadata;

  /// Timestamp when event was created
  final DateTime? timestamp;

  const RtcSignalingEvent({
    required this.type,
    required this.callId,
    required this.fromUserId,
    required this.toUserId,
    this.callType,
    this.roomId,
    this.metadata,
    this.timestamp,
  });

  /// Create from JSON (received from socket)
  factory RtcSignalingEvent.fromJson(Map<String, dynamic> json) {
    return RtcSignalingEvent(
      type: RtcSignalingEventType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => RtcSignalingEventType.callOffer,
      ),
      callId: json['callId'] as String,
      fromUserId: json['fromUserId'] as String,
      toUserId: json['toUserId'] as String,
      callType: json['callType'] as String?,
      roomId: json['roomId'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
    );
  }

  /// Convert to JSON (to send via socket)
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'callId': callId,
      'fromUserId': fromUserId,
      'toUserId': toUserId,
      if (callType != null) 'callType': callType,
      if (roomId != null) 'roomId': roomId,
      if (metadata != null) 'metadata': metadata,
      'timestamp': (timestamp ?? DateTime.now()).toIso8601String(),
    };
  }

  /// Create a call offer event
  factory RtcSignalingEvent.callOffer({
    required String callId,
    required String fromUserId,
    required String toUserId,
    String? callType,
    String? roomId,
    Map<String, dynamic>? metadata,
  }) {
    return RtcSignalingEvent(
      type: RtcSignalingEventType.callOffer,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      callType: callType,
      roomId: roomId,
      metadata: metadata,
    );
  }

  /// Create a call answer event
  factory RtcSignalingEvent.callAnswer({
    required String callId,
    required String fromUserId,
    required String toUserId,
    String? roomId,
    Map<String, dynamic>? metadata,
  }) {
    return RtcSignalingEvent(
      type: RtcSignalingEventType.callAnswer,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      roomId: roomId,
      metadata: metadata,
    );
  }

  /// Create a call reject event
  factory RtcSignalingEvent.callReject({
    required String callId,
    required String fromUserId,
    required String toUserId,
    Map<String, dynamic>? metadata,
  }) {
    return RtcSignalingEvent(
      type: RtcSignalingEventType.callReject,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      metadata: metadata,
    );
  }

  /// Create a call cancel event
  factory RtcSignalingEvent.callCancel({
    required String callId,
    required String fromUserId,
    required String toUserId,
    Map<String, dynamic>? metadata,
  }) {
    return RtcSignalingEvent(
      type: RtcSignalingEventType.callCancel,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      metadata: metadata,
    );
  }

  /// Create a call end event
  factory RtcSignalingEvent.callEnd({
    required String callId,
    required String fromUserId,
    required String toUserId,
    Map<String, dynamic>? metadata,
  }) {
    return RtcSignalingEvent(
      type: RtcSignalingEventType.callEnd,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      metadata: metadata,
    );
  }

  /// Create a call timeout event
  factory RtcSignalingEvent.callTimeout({
    required String callId,
    required String fromUserId,
    required String toUserId,
    Map<String, dynamic>? metadata,
  }) {
    return RtcSignalingEvent(
      type: RtcSignalingEventType.callTimeout,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      metadata: metadata,
    );
  }

  /// Create a call busy event
  factory RtcSignalingEvent.callBusy({
    required String callId,
    required String fromUserId,
    required String toUserId,
    Map<String, dynamic>? metadata,
  }) {
    return RtcSignalingEvent(
      type: RtcSignalingEventType.callBusy,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      metadata: metadata,
    );
  }

  @override
  String toString() {
    return 'RtcSignalingEvent(type: ${type.name}, callId: $callId, from: $fromUserId, to: $toUserId)';
  }

  /// Create a copy with modified fields
  RtcSignalingEvent copyWith({
    RtcSignalingEventType? type,
    String? callId,
    String? fromUserId,
    String? toUserId,
    String? callType,
    String? roomId,
    Map<String, dynamic>? metadata,
    DateTime? timestamp,
  }) {
    return RtcSignalingEvent(
      type: type ?? this.type,
      callId: callId ?? this.callId,
      fromUserId: fromUserId ?? this.fromUserId,
      toUserId: toUserId ?? this.toUserId,
      callType: callType ?? this.callType,
      roomId: roomId ?? this.roomId,
      metadata: metadata ?? this.metadata,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}

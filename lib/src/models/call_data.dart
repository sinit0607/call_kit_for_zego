import 'call_user.dart';
import 'call_type.dart';
import 'call_state.dart';
import 'call_end_reason.dart';

/// Immutable data model representing a call
/// Contains all information about a call session
class CallData {
  /// Unique identifier for this call
  final String callId;

  /// User who initiated the call
  final CallUser caller;

  /// User receiving the call
  final CallUser receiver;

  /// Type of call (audio/video)
  final CallType callType;

  /// Current state of the call
  final CallState state;

  /// Timestamp when call was initiated
  final DateTime startTime;

  /// Timestamp when call ended (null if ongoing)
  final DateTime? endTime;

  /// Whether this is an incoming call for the current user
  final bool isIncoming;

  /// ZEGOCLOUD room ID for this call
  final String? roomId;

  /// Session ID from backend (if applicable)
  final String? sessionId;

  /// Reason why call ended (null if ongoing)
  final CallEndReason? endReason;

  /// Duration of the call in seconds (null if ongoing)
  final int? durationSeconds;

  /// Optional metadata
  final Map<String, dynamic>? metadata;

  const CallData({
    required this.callId,
    required this.caller,
    required this.receiver,
    required this.callType,
    required this.state,
    required this.startTime,
    required this.isIncoming,
    this.endTime,
    this.roomId,
    this.sessionId,
    this.endReason,
    this.durationSeconds,
    this.metadata,
  });

  /// Get the remote user (from current user's perspective)
  CallUser get remoteUser => isIncoming ? caller : receiver;

  /// Get the local user (current user)
  CallUser get localUser => isIncoming ? receiver : caller;

  /// Check if call is currently active
  bool get isActive => state.isActive;

  /// Check if call has ended
  bool get hasEnded => state.isTerminal;

  /// Get formatted duration string (MM:SS)
  String get formattedDuration {
    if (durationSeconds == null) return '00:00';
    final minutes = durationSeconds! ~/ 60;
    final seconds = durationSeconds! % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Create a copy with updated fields
  CallData copyWith({
    String? callId,
    CallUser? caller,
    CallUser? receiver,
    CallType? callType,
    CallState? state,
    DateTime? startTime,
    DateTime? endTime,
    bool? isIncoming,
    String? roomId,
    String? sessionId,
    CallEndReason? endReason,
    int? durationSeconds,
    Map<String, dynamic>? metadata,
  }) {
    return CallData(
      callId: callId ?? this.callId,
      caller: caller ?? this.caller,
      receiver: receiver ?? this.receiver,
      callType: callType ?? this.callType,
      state: state ?? this.state,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      isIncoming: isIncoming ?? this.isIncoming,
      roomId: roomId ?? this.roomId,
      sessionId: sessionId ?? this.sessionId,
      endReason: endReason ?? this.endReason,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() {
    return {
      'callId': callId,
      'caller': caller.toJson(),
      'receiver': receiver.toJson(),
      'callType': callType.toJson(),
      'state': state.toJson(),
      'startTime': startTime.toIso8601String(),
      'endTime': endTime?.toIso8601String(),
      'isIncoming': isIncoming,
      'roomId': roomId,
      'sessionId': sessionId,
      'endReason': endReason?.toJson(),
      'durationSeconds': durationSeconds,
      'metadata': metadata,
    };
  }

  /// Create from JSON map
  factory CallData.fromJson(Map<String, dynamic> json) {
    return CallData(
      callId: json['callId'] as String,
      caller: CallUser.fromJson(json['caller'] as Map<String, dynamic>),
      receiver: CallUser.fromJson(json['receiver'] as Map<String, dynamic>),
      callType: CallType.fromJson(json['callType'] as String),
      state: CallState.fromJson(json['state'] as String),
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: json['endTime'] != null ? DateTime.parse(json['endTime'] as String) : null,
      isIncoming: json['isIncoming'] as bool,
      roomId: json['roomId'] as String?,
      sessionId: json['sessionId'] as String?,
      endReason: json['endReason'] != null ? CallEndReason.fromJson(json['endReason'] as String) : null,
      durationSeconds: json['durationSeconds'] as int?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CallData && other.callId == callId;
  }

  @override
  int get hashCode => callId.hashCode;

  @override
  String toString() {
    return 'CallData(callId: $callId, state: $state, type: $callType, isIncoming: $isIncoming)';
  }
}

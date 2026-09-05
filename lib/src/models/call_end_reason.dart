/// Reason why a call ended
/// Used for analytics and user feedback
enum CallEndReason {
  /// Call ended normally by user
  ended,

  /// Call was rejected by remote user
  rejected,

  /// Incoming call was missed (not answered)
  missed,

  /// Call timed out during ringing
  timeout,

  /// Call failed due to error
  failed,

  /// Call cancelled by caller
  cancelled,

  /// Remote user ended the call
  remoteEnded,

  /// Network connection lost
  networkLost,

  /// User is busy with another call
  busy,

  /// Unknown reason
  unknown;

  /// Check if reason indicates a failure
  bool get isFailure => this == CallEndReason.failed ||
      this == CallEndReason.networkLost ||
      this == CallEndReason.timeout;

  /// Check if reason indicates user action
  bool get isUserAction => this == CallEndReason.ended ||
      this == CallEndReason.rejected ||
      this == CallEndReason.cancelled;

  /// Convert to display string
  String toDisplayString() {
    switch (this) {
      case CallEndReason.ended:
        return 'Call ended';
      case CallEndReason.rejected:
        return 'Call rejected';
      case CallEndReason.missed:
        return 'Missed call';
      case CallEndReason.timeout:
        return 'Call timeout';
      case CallEndReason.failed:
        return 'Call failed';
      case CallEndReason.cancelled:
        return 'Call cancelled';
      case CallEndReason.remoteEnded:
        return 'Remote user ended call';
      case CallEndReason.networkLost:
        return 'Network connection lost';
      case CallEndReason.busy:
        return 'User is busy';
      case CallEndReason.unknown:
        return 'Unknown reason';
    }
  }

  /// Convert to JSON string
  String toJson() => name;

  /// Create from JSON string
  static CallEndReason fromJson(String value) {
    return CallEndReason.values.firstWhere(
      (e) => e.name == value,
      orElse: () => CallEndReason.unknown,
    );
  }
}

/// Type of live stream participation
enum LiveStreamType {
  /// User is broadcasting (going live)
  broadcasting,

  /// User is viewing the stream
  viewing,
}

/// Check if this is a broadcasting session
extension LiveStreamTypeExtension on LiveStreamType {
  bool get isBroadcasting => this == LiveStreamType.broadcasting;

  bool get isViewing => this == LiveStreamType.viewing;
}

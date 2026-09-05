/// Type of RTC call
enum CallType {
  /// Audio-only call
  audio,

  /// Video call with audio
  video,

  /// Text chat (uses session system but no media)
  chat;

  /// Check if this is a video call
  bool get isVideo => this == CallType.video;

  /// Check if this is an audio call
  bool get isAudio => this == CallType.audio;

  /// Check if this is a text chat
  bool get isChat => this == CallType.chat;

  /// Check if this requires media (audio/video)
  bool get requiresMedia => this == CallType.audio || this == CallType.video;

  /// Convert to string representation
  String toDisplayString() {
    switch (this) {
      case CallType.audio:
        return 'Audio Call';
      case CallType.video:
        return 'Video Call';
      case CallType.chat:
        return 'Chat';
    }
  }

  /// Convert to JSON-compatible string
  String toJson() => name;

  /// Create from JSON string
  static CallType fromJson(String value) {
    return CallType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => CallType.audio,
    );
  }
}

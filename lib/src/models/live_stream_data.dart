/// Immutable data model representing a live stream session
class LiveStreamData {
  /// Unique room ID for this stream
  final String roomId;

  /// User ID of the host/broadcaster
  final String hostId;

  /// Display name of the host
  final String hostName;

  /// Avatar URL of the host
  final String? hostImage;

  /// Stream ID for ZEGO
  final String streamId;

  /// Current number of viewers
  final int viewerCount;

  /// Whether the stream is currently live
  final bool isLive;

  /// Timestamp when the stream started
  final DateTime? startedAt;

  /// Optional stream title
  final String? title;

  /// Optional metadata
  final Map<String, dynamic>? metadata;

  const LiveStreamData({
    required this.roomId,
    required this.hostId,
    required this.hostName,
    required this.streamId,
    this.viewerCount = 0,
    this.isLive = false,
    this.startedAt,
    this.hostImage,
    this.title,
    this.metadata,
  });

  /// Create a copy with updated fields
  LiveStreamData copyWith({
    String? roomId,
    String? hostId,
    String? hostName,
    String? hostImage,
    String? streamId,
    int? viewerCount,
    bool? isLive,
    DateTime? startedAt,
    String? title,
    Map<String, dynamic>? metadata,
  }) {
    return LiveStreamData(
      roomId: roomId ?? this.roomId,
      hostId: hostId ?? this.hostId,
      hostName: hostName ?? this.hostName,
      hostImage: hostImage ?? this.hostImage,
      streamId: streamId ?? this.streamId,
      viewerCount: viewerCount ?? this.viewerCount,
      isLive: isLive ?? this.isLive,
      startedAt: startedAt ?? this.startedAt,
      title: title ?? this.title,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() {
    return {
      'roomId': roomId,
      'hostId': hostId,
      'hostName': hostName,
      'hostImage': hostImage,
      'streamId': streamId,
      'viewerCount': viewerCount,
      'isLive': isLive,
      'startedAt': startedAt?.toIso8601String(),
      'title': title,
      'metadata': metadata,
    };
  }

  /// Create from JSON map
  factory LiveStreamData.fromJson(Map<String, dynamic> json) {
    return LiveStreamData(
      roomId: json['roomId'] as String,
      hostId: json['hostId'] as String,
      hostName: json['hostName'] as String,
      hostImage: json['hostImage'] as String?,
      streamId: json['streamId'] as String,
      viewerCount: json['viewerCount'] as int? ?? 0,
      isLive: json['isLive'] as bool? ?? false,
      startedAt: json['startedAt'] != null
          ? DateTime.parse(json['startedAt'] as String)
          : null,
      title: json['title'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LiveStreamData && other.roomId == roomId && other.streamId == streamId;
  }

  @override
  int get hashCode => Object.hash(roomId, streamId);

  @override
  String toString() {
    return 'LiveStreamData(roomId: $roomId, hostId: $hostId, streamId: $streamId, isLive: $isLive, viewers: $viewerCount)';
  }
}
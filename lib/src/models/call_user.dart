/// Immutable user data model for RTC calls
/// Represents a participant in a call (caller or receiver)
class CallUser {
  /// Unique identifier for the user
  final String userId;

  /// Display name of the user
  final String userName;

  /// Optional avatar URL for the user
  final String? avatarUrl;

  /// Optional additional metadata
  final Map<String, dynamic>? metadata;

  const CallUser({
    required this.userId,
    required this.userName,
    this.avatarUrl,
    this.metadata,
  });

  /// Create a copy with updated fields
  CallUser copyWith({
    String? userId,
    String? userName,
    String? avatarUrl,
    Map<String, dynamic>? metadata,
  }) {
    return CallUser(
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'userName': userName,
      'avatarUrl': avatarUrl,
      'metadata': metadata,
    };
  }

  /// Create from JSON map
  factory CallUser.fromJson(Map<String, dynamic> json) {
    return CallUser(
      userId: json['userId'] as String,
      userName: json['userName'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CallUser && other.userId == userId;
  }

  @override
  int get hashCode => userId.hashCode;

  @override
  String toString() {
    return 'CallUser(userId: $userId, userName: $userName, avatarUrl: $avatarUrl)';
  }
}

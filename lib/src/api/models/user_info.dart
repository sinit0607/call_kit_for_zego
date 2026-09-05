/// Public model for user information
class UserInfo {
  final String userId;
  final String userName;
  final String? userImage;
  final String? role;
  final Map<String, dynamic>? metadata;

  const UserInfo({
    required this.userId,
    required this.userName,
    this.userImage,
    this.role,
    this.metadata,
  });

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'userName': userName,
        'userImage': userImage,
        'role': role,
        'metadata': metadata,
      };

  factory UserInfo.fromJson(Map<String, dynamic> json) => UserInfo(
        userId: json['userId'] as String,
        userName: json['userName'] as String,
        userImage: json['userImage'] as String?,
        role: json['role'] as String?,
        metadata: json['metadata'] as Map<String, dynamic>?,
      );

  UserInfo copyWith({
    String? userId,
    String? userName,
    String? userImage,
    String? role,
    Map<String, dynamic>? metadata,
  }) {
    return UserInfo(
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      userImage: userImage ?? this.userImage,
      role: role ?? this.role,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() => 'UserInfo(userId: $userId, userName: $userName, role: $role)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserInfo &&
          runtimeType == other.runtimeType &&
          userId == other.userId;

  @override
  int get hashCode => userId.hashCode;
}

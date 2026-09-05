/// Status of a chat message
enum MessageStatus {
  /// Message is being sent
  sending,

  /// Message successfully sent to server
  sent,

  /// Message delivered to recipient
  delivered,

  /// Message read by recipient
  read,

  /// Message failed to send
  failed,
}

/// Represents a chat message
class ChatMessage {
  /// Unique message identifier
  final String messageId;

  /// Session this message belongs to
  final String sessionId;

  /// ID of the sender
  final String senderId;

  /// Name of the sender
  final String senderName;

  /// Image URL of the sender (optional)
  final String? senderImage;

  /// Message content
  final String content;

  /// When the message was created
  final DateTime timestamp;

  /// Current status of the message
  MessageStatus status;

  /// Additional metadata
  final Map<String, dynamic>? metadata;

  ChatMessage({
    required this.messageId,
    required this.sessionId,
    required this.senderId,
    required this.senderName,
    this.senderImage,
    required this.content,
    required this.timestamp,
    this.status = MessageStatus.sent,
    this.metadata,
  });

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'sessionId': sessionId,
        'senderId': senderId,
        'senderName': senderName,
        'senderImage': senderImage,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'status': status.name,
        'metadata': metadata,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      messageId: json['messageId'] as String,
      sessionId: json['sessionId'] as String,
      senderId: json['senderId'] as String,
      senderName: json['senderName'] as String,
      senderImage: json['senderImage'] as String?,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      status: MessageStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => MessageStatus.sent,
      ),
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  ChatMessage copyWith({
    String? messageId,
    String? sessionId,
    String? senderId,
    String? senderName,
    String? senderImage,
    String? content,
    DateTime? timestamp,
    MessageStatus? status,
    Map<String, dynamic>? metadata,
  }) {
    return ChatMessage(
      messageId: messageId ?? this.messageId,
      sessionId: sessionId ?? this.sessionId,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      senderImage: senderImage ?? this.senderImage,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() =>
      'ChatMessage(messageId: $messageId, sender: $senderName, content: ${content.substring(0, content.length > 20 ? 20 : content.length)}...)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          runtimeType == other.runtimeType &&
          messageId == other.messageId;

  @override
  int get hashCode => messageId.hashCode;
}

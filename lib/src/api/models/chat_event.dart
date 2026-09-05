import 'user_info.dart';
import 'chat_message.dart';

/// Types of chat events that can occur
enum ChatEventType {
  /// Chat session started
  sessionStarted,

  /// Chat session ended
  sessionEnded,

  /// New message received
  messageReceived,

  /// Message successfully sent
  messageSent,

  /// Message delivered to server
  messageDelivered,

  /// Message read by recipient
  messageRead,

  /// Message failed to send
  messageFailed,

  /// Remote user is typing
  typingIndicator,

  /// Connection status changed
  connectionStatusChanged,
}

/// Event emitted by the communication service for chat-related events
class ChatEvent {
  /// Type of the event
  final ChatEventType type;

  /// Session identifier
  final String sessionId;

  /// Message (if applicable)
  final ChatMessage? message;

  /// User involved in the event (if applicable)
  final UserInfo? user;

  /// When the event occurred
  final DateTime timestamp;

  /// Additional metadata
  final Map<String, dynamic>? metadata;

  const ChatEvent({
    required this.type,
    required this.sessionId,
    this.message,
    this.user,
    required this.timestamp,
    this.metadata,
  });

  // Convenience constructors

  factory ChatEvent.sessionStarted({
    required String sessionId,
    UserInfo? remoteUser,
  }) {
    return ChatEvent(
      type: ChatEventType.sessionStarted,
      sessionId: sessionId,
      user: remoteUser,
      timestamp: DateTime.now(),
    );
  }

  factory ChatEvent.sessionEnded({
    required String sessionId,
    String? reason,
  }) {
    return ChatEvent(
      type: ChatEventType.sessionEnded,
      sessionId: sessionId,
      timestamp: DateTime.now(),
      metadata: {'reason': reason},
    );
  }

  factory ChatEvent.messageReceived({
    required String sessionId,
    required ChatMessage message,
  }) {
    return ChatEvent(
      type: ChatEventType.messageReceived,
      sessionId: sessionId,
      message: message,
      timestamp: DateTime.now(),
    );
  }

  factory ChatEvent.messageSent({
    required String sessionId,
    required ChatMessage message,
  }) {
    return ChatEvent(
      type: ChatEventType.messageSent,
      sessionId: sessionId,
      message: message,
      timestamp: DateTime.now(),
    );
  }

  factory ChatEvent.messageDelivered({
    required String sessionId,
    required String messageId,
  }) {
    return ChatEvent(
      type: ChatEventType.messageDelivered,
      sessionId: sessionId,
      timestamp: DateTime.now(),
      metadata: {'messageId': messageId},
    );
  }

  factory ChatEvent.messageRead({
    required String sessionId,
    required List<String> messageIds,
  }) {
    return ChatEvent(
      type: ChatEventType.messageRead,
      sessionId: sessionId,
      timestamp: DateTime.now(),
      metadata: {'messageIds': messageIds},
    );
  }

  factory ChatEvent.messageFailed({
    required String sessionId,
    required ChatMessage message,
    required String error,
  }) {
    return ChatEvent(
      type: ChatEventType.messageFailed,
      sessionId: sessionId,
      message: message,
      timestamp: DateTime.now(),
      metadata: {'error': error},
    );
  }

  factory ChatEvent.typingIndicator({
    required String sessionId,
    required UserInfo user,
    required bool isTyping,
  }) {
    return ChatEvent(
      type: ChatEventType.typingIndicator,
      sessionId: sessionId,
      user: user,
      timestamp: DateTime.now(),
      metadata: {'isTyping': isTyping},
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'sessionId': sessionId,
        'message': message?.toJson(),
        'user': user?.toJson(),
        'timestamp': timestamp.toIso8601String(),
        'metadata': metadata,
      };

  @override
  String toString() =>
      'ChatEvent(type: ${type.name}, sessionId: $sessionId, message: ${message?.messageId})';
}

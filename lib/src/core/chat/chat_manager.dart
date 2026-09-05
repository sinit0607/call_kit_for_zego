import 'dart:async';
import 'dart:collection';
import 'dart:math';
import '../../adapters/socket_adapter.dart';
import '../../api/models/chat_event.dart';
import '../../api/models/chat_message.dart';
import '../../api/models/user_info.dart';
import '../../utils/rtc_logger.dart';
import '../session/session_manager.dart';

/// Manages chat messaging and socket events
///
/// This manager:
/// - Accepts socket instance as dependency (does NOT create it)
/// - Registers chat-related socket listeners
/// - Handles message sending/receiving
/// - Emits normalized ChatEvent stream for main app
/// - Handles duplicate messages and reconnection
class ChatManager {
  static const String _tag = 'ChatManager';
  static final Random _secureRandom = Random.secure();

  final SocketAdapter _socket;
  final SessionManager _sessionManager;

  final _eventController = StreamController<ChatEvent>.broadcast();
  Stream<ChatEvent> get events => _eventController.stream;

  // Track processed messages to prevent duplicates (FIFO queue for bounded memory)
  final Queue<String> _processedMessagesQueue = Queue<String>();
  final Set<String> _processedMessagesSet = {};
  static const int _maxProcessedMessages = 200;

  // Current session state
  String? _currentSessionId;
  final Map<String, ChatMessage> _pendingMessages = {};

  ChatManager({
    required SocketAdapter socket,
    required SessionManager sessionManager,
  })  : _socket = socket,
        _sessionManager = sessionManager {
    _registerSocketListeners();
  }

  /// Register socket listeners for chat events
  ///
  /// IMPORTANT: This only ATTACHES listeners, does NOT call socket.connect()
  void _registerSocketListeners() {
    RtcLogger.info('[$_tag] Registering chat socket listeners');

    // Message received
    _socket.on('receiveMessage', _handleMessageReceived);

    // Session events (already handled by CallManager, but we listen too for chat state)
    _socket.on('sessionStarted', _handleSessionStarted);
    _socket.on('sessionEnded', _handleSessionEnded);

    // Message delivery/read status (optional, if backend supports)
    _socket.on('messageDelivered', _handleMessageDelivered);
    _socket.on('messageRead', _handleMessageRead);

    // Typing indicator (optional, if backend supports)
    _socket.on('typing', _handleTypingIndicator);
  }

  /// Handle incoming message
  void _handleMessageReceived(dynamic data) {
    try {
      final eventData = data as Map<String, dynamic>;

      // Extract message data
      final messageId = eventData['messageId'] as String? ??
          eventData['_id'] as String? ??
          _generateMessageId();
      final sessionId = eventData['sessionId'] as String? ?? _currentSessionId;
      final senderId = eventData['senderId'] as String? ?? eventData['userId'] as String?;
      final senderName = eventData['senderName'] as String? ?? 'Unknown';
      final senderImage = eventData['senderImage'] as String?;
      final content = eventData['message'] as String? ?? eventData['content'] as String? ?? '';
      final timestamp = _parseTimestamp(eventData['timestamp'] ?? eventData['createdAt']);

      if (_isDuplicate(messageId)) {
        RtcLogger.warning('[$_tag] Duplicate message ignored: $messageId');
        return;
      }

      if (sessionId == null || senderId == null) {
        RtcLogger.warning('[$_tag] Invalid message data, missing sessionId or senderId');
        return;
      }

      RtcLogger.info('[$_tag] Message received', {
        'messageId': messageId,
        'sessionId': sessionId,
        'senderId': senderId,
      });

      // Create ChatMessage
      final message = ChatMessage(
        messageId: messageId,
        sessionId: sessionId,
        senderId: senderId,
        senderName: senderName,
        senderImage: senderImage,
        content: content,
        timestamp: timestamp,
        status: MessageStatus.delivered,
        metadata: eventData,
      );

      // Emit event
      _eventController.add(ChatEvent.messageReceived(
        sessionId: sessionId,
        message: message,
      ));

      _markProcessed(messageId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling message received', e, stack);
    }
  }

  /// Handle session started
  void _handleSessionStarted(dynamic data) {
    try {
      final eventData = data as Map<String, dynamic>;
      final sessionId = eventData['sessionId'] as String?;

      if (sessionId == null) {
        RtcLogger.warning('[$_tag] Session started without sessionId');
        return;
      }

      RtcLogger.info('[$_tag] Session started', {'sessionId': sessionId});

      _currentSessionId = sessionId;

      // Extract user info from event
      final remoteUserId = eventData['userId'] as String? ?? eventData['listenerId'] as String?;
      final remoteUserName = eventData['userName'] as String? ?? eventData['listenerName'] as String?;
      final remoteUserImage = eventData['userImage'] as String? ?? eventData['listenerImage'] as String?;

      UserInfo? remoteUser;
      if (remoteUserId != null) {
        remoteUser = UserInfo(
          userId: remoteUserId,
          userName: remoteUserName ?? 'Unknown',
          userImage: remoteUserImage,
        );
      }

      _eventController.add(ChatEvent.sessionStarted(
        sessionId: sessionId,
        remoteUser: remoteUser,
      ));
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling session started', e, stack);
    }
  }

  /// Handle session ended
  void _handleSessionEnded(dynamic data) {
    try {
      final eventData = data as Map<String, dynamic>;
      final sessionId = eventData['sessionId'] as String? ?? _currentSessionId;

      if (sessionId == null) {
        RtcLogger.warning('[$_tag] Session ended without sessionId');
        return;
      }

      RtcLogger.info('[$_tag] Session ended', {'sessionId': sessionId});

      _eventController.add(ChatEvent.sessionEnded(
        sessionId: sessionId,
        reason: eventData['reason']?.toString() ?? 'ended',
      ));

      // Clear current session if it matches
      if (_currentSessionId == sessionId) {
        _currentSessionId = null;
      }

      // Clear pending messages for this session
      _pendingMessages.removeWhere((key, msg) => msg.sessionId == sessionId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling session ended', e, stack);
    }
  }

  /// Handle message delivered status
  void _handleMessageDelivered(dynamic data) {
    try {
      final eventData = data as Map<String, dynamic>;
      final messageId = eventData['messageId'] as String?;

      if (messageId == null) return;

      RtcLogger.info('[$_tag] Message delivered', {'messageId': messageId});

      // Update pending message status
      if (_pendingMessages.containsKey(messageId)) {
        _pendingMessages[messageId]!.status = MessageStatus.delivered;

        _eventController.add(ChatEvent.messageDelivered(
          sessionId: _pendingMessages[messageId]!.sessionId,
          messageId: messageId,
        ));
      }
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling message delivered', e, stack);
    }
  }

  /// Handle message read status
  void _handleMessageRead(dynamic data) {
    try {
      final eventData = data as Map<String, dynamic>;
      final messageId = eventData['messageId'] as String?;

      if (messageId == null) return;

      RtcLogger.info('[$_tag] Message read', {'messageId': messageId});

      // Update pending message status
      if (_pendingMessages.containsKey(messageId)) {
        _pendingMessages[messageId]!.status = MessageStatus.read;

        _eventController.add(ChatEvent.messageRead(
          sessionId: _pendingMessages[messageId]!.sessionId,
          messageIds: [messageId],
        ));

        // Remove from pending
        _pendingMessages.remove(messageId);
      }
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling message read', e, stack);
    }
  }

  /// Handle typing indicator
  void _handleTypingIndicator(dynamic data) {
    try {
      final eventData = data as Map<String, dynamic>;
      final sessionId = eventData['sessionId'] as String? ?? _currentSessionId;
      final userId = eventData['userId'] as String?;
      final isTyping = eventData['isTyping'] as bool? ?? true;

      if (sessionId == null || userId == null) return;

      RtcLogger.info('[$_tag] Typing indicator', {
        'sessionId': sessionId,
        'userId': userId,
        'isTyping': isTyping,
      });

      final user = UserInfo(
        userId: userId,
        userName: eventData['userName'] ?? 'Unknown',
        userImage: eventData['userImage'],
      );

      _eventController.add(ChatEvent.typingIndicator(
        sessionId: sessionId,
        user: user,
        isTyping: isTyping,
      ));
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling typing indicator', e, stack);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // PUBLIC API METHODS
  // ══════════════════════════════════════════════════════════════════════

  /// Send a message
  Future<MessageResult> sendMessage({
    required String sessionId,
    required String content,
    String? recipientId,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final currentUser = _sessionManager.currentUser;
      if (currentUser == null) {
        return MessageResult(
          success: false,
          error: 'No authenticated user',
        );
      }

      final messageId = _generateMessageId();
      final timestamp = DateTime.now();

      RtcLogger.info('[$_tag] Sending message', {
        'messageId': messageId,
        'sessionId': sessionId,
      });

      // Create message object
      final message = ChatMessage(
        messageId: messageId,
        sessionId: sessionId,
        senderId: currentUser.userId,
        senderName: currentUser.userName,
        senderImage: currentUser.userImage,
        content: content,
        timestamp: timestamp,
        status: MessageStatus.sending,
        metadata: metadata,
      );

      // Track as pending
      _pendingMessages[messageId] = message;

      // Emit via socket
      await _socket.emit('sendMessage', {
        'messageId': messageId,
        'sessionId': sessionId,
        'userId': currentUser.userId,
        'senderName': currentUser.userName,
        'senderImage': currentUser.userImage,
        'message': content,
        'timestamp': timestamp.toIso8601String(),
        if (recipientId != null) 'recipientId': recipientId,
        if (metadata != null) ...metadata,
      });

      // Update status to sent
      message.status = MessageStatus.sent;

      // Emit event
      _eventController.add(ChatEvent.messageSent(
        sessionId: sessionId,
        message: message,
      ));

      return MessageResult(
        success: true,
        message: message,
      );
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to send message', e, stack);
      return MessageResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Send typing indicator
  Future<void> sendTypingIndicator({
    required String sessionId,
    required bool isTyping,
  }) async {
    try {
      final currentUser = _sessionManager.currentUser;
      if (currentUser == null) return;

      await _socket.emit('typing', {
        'sessionId': sessionId,
        'userId': currentUser.userId,
        'userName': currentUser.userName,
        'isTyping': isTyping,
      });
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to send typing indicator', e, stack);
    }
  }

  /// Get current session ID
  String? get currentSessionId => _currentSessionId;

  /// Set current session ID (when session starts via call)
  void setCurrentSession(String sessionId) {
    _currentSessionId = sessionId;
  }

  /// Check if message is duplicate
  bool _isDuplicate(String messageId) {
    return _processedMessagesSet.contains(messageId);
  }

  /// Mark message as processed with FIFO eviction
  void _markProcessed(String messageId) {
    // Add to both queue (for FIFO order) and set (for O(1) lookup)
    _processedMessagesQueue.addLast(messageId);
    _processedMessagesSet.add(messageId);

    // Enforce hard cap with FIFO eviction
    while (_processedMessagesQueue.length > _maxProcessedMessages) {
      final oldest = _processedMessagesQueue.removeFirst();
      _processedMessagesSet.remove(oldest);
    }
  }

  /// Parse timestamp from various formats
  DateTime _parseTimestamp(dynamic timestamp) {
    if (timestamp == null) return DateTime.now();

    if (timestamp is DateTime) return timestamp;

    if (timestamp is String) {
      try {
        return DateTime.parse(timestamp);
      } catch (e) {
        return DateTime.now();
      }
    }

    if (timestamp is int) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    }

    return DateTime.now();
  }

  /// Generate unique message ID
  String _generateMessageId() {
    return 'msg_${DateTime.now().millisecondsSinceEpoch}_${_randomString(6)}';
  }

  /// Generate cryptographically secure random string
  String _randomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      length,
      (index) => chars[_secureRandom.nextInt(chars.length)],
    ).join();
  }

  /// Dispose resources
  ///
  /// IMPORTANT: This removes socket listeners but does NOT dispose the socket
  void dispose() {
    RtcLogger.info('[$_tag] Disposing ChatManager');

    // Remove all socket listeners with safe cleanup
    _safeRemoveListener('receiveMessage');
    _safeRemoveListener('sessionStarted');
    _safeRemoveListener('sessionEnded');
    _safeRemoveListener('messageDelivered');
    _safeRemoveListener('messageRead');
    _safeRemoveListener('typing');

    // Clear state
    _processedMessagesQueue.clear();
    _processedMessagesSet.clear();
    _pendingMessages.clear();
    _currentSessionId = null;

    // Close event stream
    _eventController.close();
  }

  /// Safely remove socket listener (no throw on error)
  void _safeRemoveListener(String event) {
    try {
      _socket.off(event);
    } catch (e) {
      RtcLogger.warning('[$_tag] Failed to remove listener: $event', e);
    }
  }
}

/// Result of a message operation
class MessageResult {
  final bool success;
  final ChatMessage? message;
  final String? error;

  MessageResult({
    required this.success,
    this.message,
    this.error,
  });
}

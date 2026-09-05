import 'dart:async';
import 'package:flutter/material.dart';
import 'package:call_kit_for_zego/call_kit_for_zego.dart';

/// A production-ready chat screen widget for real-time messaging.
///
/// Drop this widget into your app to get a full-featured chat UI:
/// - Message bubbles with send/delivered/read status
/// - Typing indicators
/// - Auto-scroll to new messages
/// - Session header with remote user info
///
/// Example:
/// ```dart
/// Navigator.of(context).push(
///   MaterialPageRoute(
///     builder: (_) => ChatScreen(
///       sessionId: sessionId,
///       remoteUser: remoteUser,
///     ),
///   ),
/// );
/// ```
class ChatScreen extends StatefulWidget {
  /// The chat session ID
  final String sessionId;

  /// Optional remote user info for header display
  final UserInfo? remoteUser;

  /// Called when the session ends (for navigation control).
  /// If not provided, the widget pops the Navigator on session end.
  final VoidCallback? onSessionEnded;

  /// Whether to show the session header (default: true)
  final bool showSessionHeader;

  const ChatScreen({
    super.key,
    required this.sessionId,
    this.remoteUser,
    this.onSessionEnded,
    this.showSessionHeader = true,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  StreamSubscription<ChatEvent>? _chatSubscription;
  String? _typingUserName;
  Timer? _typingDebounce;
  bool _isTyping = false;

  @override
  void initState() {
    super.initState();
    RtcCommunicationService.instance.setCurrentChatSession(widget.sessionId);
    _setupChatListener();
  }

  @override
  void dispose() {
    _chatSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _typingDebounce?.cancel();
    if (_isTyping) {
      RtcCommunicationService.instance.sendTypingIndicator(
        sessionId: widget.sessionId,
        isTyping: false,
      );
    }
    super.dispose();
  }

  void _setupChatListener() {
    _chatSubscription = RtcCommunicationService.instance.chatEvents.listen((event) {
      switch (event.type) {
        case ChatEventType.messageReceived:
        case ChatEventType.messageSent:
          if (event.message != null) {
            setState(() => _messages.add(event.message!));
            _scrollToBottom();
          }
          break;

        case ChatEventType.messageDelivered:
        case ChatEventType.messageRead:
        case ChatEventType.messageFailed:
          final msgId = _extractMessageId(event);
          if (msgId != null) {
            setState(() {
              final idx = _messages.indexWhere((m) => m.messageId == msgId);
              if (idx != -1) {
                _messages[idx].status = _mapStatus(event.type);
              }
            });
          }
          break;

        case ChatEventType.typingIndicator:
          final isTyping = event.metadata?['isTyping'] as bool? ?? false;
          setState(() {
            _typingUserName = isTyping ? event.user?.userName : null;
          });
          break;

        case ChatEventType.sessionEnded:
          if (mounted) {
            if (widget.onSessionEnded != null) {
              widget.onSessionEnded!();
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Session ended')),
              );
              Navigator.of(context).pop();
            }
          }
          break;

        default:
          break;
      }
    });
  }

  String? _extractMessageId(ChatEvent event) {
    if (event.message != null) return event.message!.messageId;
    return event.metadata?['messageId'] as String? ??
        (event.metadata?['messageIds'] as List?)?.firstOrNull?.toString();
  }

  MessageStatus _mapStatus(ChatEventType type) {
    switch (type) {
      case ChatEventType.messageDelivered:
        return MessageStatus.delivered;
      case ChatEventType.messageRead:
        return MessageStatus.read;
      case ChatEventType.messageFailed:
        return MessageStatus.failed;
      default:
        return MessageStatus.sent;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onTextChanged(String text) {
    final shouldType = text.isNotEmpty;
    if (shouldType != _isTyping) {
      _isTyping = shouldType;
      RtcCommunicationService.instance.sendTypingIndicator(
        sessionId: widget.sessionId,
        isTyping: _isTyping,
      );
    }

    _typingDebounce?.cancel();
    if (_isTyping) {
      _typingDebounce = Timer(const Duration(seconds: 3), () {
        if (_isTyping) {
          _isTyping = false;
          RtcCommunicationService.instance.sendTypingIndicator(
            sessionId: widget.sessionId,
            isTyping: false,
          );
        }
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();

    if (_isTyping) {
      _isTyping = false;
      RtcCommunicationService.instance.sendTypingIndicator(
        sessionId: widget.sessionId,
        isTyping: false,
      );
    }

    final result = await RtcCommunicationService.instance.sendMessage(
      sessionId: widget.sessionId,
      content: text,
    );

    if (!result.success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send: ${result.error}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = RtcCommunicationService.instance.currentUser?.userId;

    return Scaffold(
      appBar: widget.showSessionHeader
          ? AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.remoteUser?.userName ?? 'Chat'),
                  Text(
                    'Session: ${widget.sessionId.length > 8 ? widget.sessionId.substring(0, 8) : widget.sessionId}...',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
                  ),
                ],
              ),
              actions: [
                if (widget.remoteUser?.userImage != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundImage: NetworkImage(widget.remoteUser!.userImage!),
                    ),
                  ),
              ],
            )
          : null,
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'No messages yet.\nSend a message to start chatting.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isMe = message.senderId == currentUserId;
                      return _MessageBubble(message: message, isMe: isMe);
                    },
                  ),
          ),
          if (_typingUserName != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              alignment: Alignment.centerLeft,
              child: Text(
                '$_typingUserName is typing...',
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          _buildInputRow(context),
        ],
      ),
    );
  }

  Widget _buildInputRow(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                onChanged: _onTextChanged,
                onSubmitted: (_) => _sendMessage(),
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.grey[200],
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _sendMessage,
              icon: const Icon(Icons.send),
              color: Theme.of(context).primaryColor,
            ),
          ],
        ),
      ),
    );
  }
}

/// Individual message bubble widget
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;

  const _MessageBubble({required this.message, required this.isMe});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isMe) ...[
            _buildAvatar(),
            const SizedBox(width: 8),
          ],
          Flexible(child: _buildBubble(context)),
          if (isMe) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    return CircleAvatar(
      radius: 16,
      backgroundImage:
          message.senderImage != null ? NetworkImage(message.senderImage!) : null,
      child: message.senderImage == null
          ? Text(
              message.senderName.isNotEmpty ? message.senderName[0].toUpperCase() : '?',
              style: const TextStyle(fontSize: 14),
            )
          : null,
    );
  }

  Widget _buildBubble(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? Colors.blue[600] : Colors.grey[200],
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                message.senderName,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[700],
                ),
              ),
            ),
          Text(
            message.content,
            style: TextStyle(color: isMe ? Colors.white : Colors.black87),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatTime(message.timestamp),
                style: TextStyle(
                  fontSize: 10,
                  color: isMe ? Colors.white70 : Colors.grey,
                ),
              ),
              if (isMe) ...[
                const SizedBox(width: 4),
                _StatusIcon(status: message.status),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// Message status icon (sent, delivered, read)
class _StatusIcon extends StatelessWidget {
  final MessageStatus status;

  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MessageStatus.sending:
        return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: Colors.white70,
          ),
        );
      case MessageStatus.sent:
        return const Icon(Icons.check, size: 14, color: Colors.white70);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all, size: 14, color: Colors.white70);
      case MessageStatus.read:
        return const Icon(Icons.done_all, size: 14, color: Colors.lightBlueAccent);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline, size: 14, color: Colors.redAccent);
    }
  }
}
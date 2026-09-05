import 'package:flutter/foundation.dart';
import 'package:call_kit_for_zego/call_kit_for_zego.dart';

/// Example custom SignalingMapper for your backend
///
/// Implement this to map your backend's socket event format
/// to the generic RtcSignalingEvent format used by the package.
///
/// This example shows how to map a typical backend format:
/// - `receiveChatRequest` for incoming calls
/// - `requestAccepted` for call accepted
/// - `requestRejected` for call rejected
/// - `sessionStarted` for session confirmation
/// - `sessionEnded` for call ended
class MySignalingMapper implements SignalingMapper {
  @override
  List<String> get incomingEventNames => [
    'receiveChatRequest',
    'requestAccepted',
    'requestRejected',
    'sessionStarted',
    'sessionEnded',
    'callCancelled',
    'callTimeout',
  ];

  @override
  RtcSignalingEvent? mapIncomingEvent(
    String eventName,
    Map<String, dynamic> data,
  ) {
    try {
      switch (eventName) {
        case 'receiveChatRequest':
          return _mapIncomingCall(data);

        case 'requestAccepted':
          return _mapCallAccepted(data);

        case 'requestRejected':
          return _mapCallRejected(data);

        case 'sessionStarted':
          return _mapSessionStarted(data);

        case 'sessionEnded':
          return _mapCallEnded(data);

        case 'callCancelled':
          return _mapCallCancelled(data);

        case 'callTimeout':
          return _mapCallTimeout(data);

        default:
          debugPrint('[MySignalingMapper] Unknown event: $eventName');
          return null;
      }
    } catch (e) {
      debugPrint('[MySignalingMapper] Error mapping event $eventName: $e');
      return null;
    }
  }

  @override
  SignalingEmitData mapOutgoingEvent(
    RtcSignalingEvent event, {
    required String currentUserId,
    String? senderName,
    String? senderImage,
    String? receiverName,
    String? receiverImage,
    String? userRole,
  }) {
    final eventName = getEventName(event.type);

    // Build base data structure matching your backend's expected format
    final data = <String, dynamic>{
      'userId': userRole == 'listener' ? event.toUserId : event.fromUserId,
      'listenerId': userRole == 'listener' ? event.fromUserId : event.toUserId,
      'requestId': event.callId,
      'type': _mapCallType(event.callType),
      if (event.roomId != null) 'roomId': event.roomId,
      if (senderName != null) 'requestByUserName': senderName,
      if (senderImage != null) 'requestByImage': senderImage,
    };

    // Add event-specific fields
    switch (event.type) {
      case RtcSignalingEventType.callReject:
        data['rejectedBy'] = userRole ?? 'user';
        break;
      case RtcSignalingEventType.callCancel:
        data['cancelledBy'] = userRole ?? 'user';
        break;
      case RtcSignalingEventType.callEnd:
        data['sessionEndedBy'] = userRole ?? 'user';
        data['sessionId'] = event.metadata?['sessionId'];
        break;
      default:
        break;
    }

    return SignalingEmitData(eventName: eventName, data: data);
  }

  @override
  String getEventName(RtcSignalingEventType type) {
    switch (type) {
      case RtcSignalingEventType.callOffer:
        return 'chat-request';
      case RtcSignalingEventType.callAnswer:
        return 'accept-request';
      case RtcSignalingEventType.callReject:
        return 'reject-request';
      case RtcSignalingEventType.callCancel:
        return 'cancel-request';
      case RtcSignalingEventType.callEnd:
        return 'session-end';
      case RtcSignalingEventType.callTimeout:
        return 'call-timeout';
      default:
        return 'unknown';
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PRIVATE MAPPING METHODS
  // ════════════════════════════════════════════════════════════════════════════

  RtcSignalingEvent _mapIncomingCall(Map<String, dynamic> data) {
    // Your backend format:
    // {
    //   "userId": "user123",
    //   "listenerId": "listener456",
    //   "requestBy": "user123",
    //   "userName": "John",
    //   "userImage": "https://...",
    //   "type": "video",
    //   "roomId": "room_123"
    // }

    final userId = data['userId'] as String?;
    final listenerId = data['listenerId'] as String?;
    final requestBy = data['requestBy'] as String? ?? data['requestedBy'] as String?;

    // Determine who is calling whom
    final String callerId;
    final String calleeId;

    if (requestBy == listenerId) {
      // Listener is calling user
      callerId = listenerId!;
      calleeId = userId!;
    } else {
      // User is calling listener
      callerId = userId!;
      calleeId = listenerId!;
    }

    return RtcSignalingEvent.callOffer(
      callId: data['requestId'] as String? ?? _generateCallId(data),
      fromUserId: callerId,
      toUserId: calleeId,
      callType: _parseCallType(data['type'] as String?),
      roomId: data['roomId'] as String?,
      metadata: {
        'caller': {
          'userId': callerId,
          'userName': data['userName'] ?? data['requestByUserName'] ?? 'Unknown',
          'avatarUrl': data['userImage'] ?? data['requestByImage'],
        },
        'sessionId': data['sessionId'],
      },
    );
  }

  RtcSignalingEvent _mapCallAccepted(Map<String, dynamic> data) {
    return RtcSignalingEvent.callAnswer(
      callId: data['requestId'] as String? ?? '',
      fromUserId: data['userId'] as String? ?? '',
      toUserId: data['listenerId'] as String? ?? '',
      roomId: data['roomId'] as String?,
      metadata: {
        'sessionId': data['sessionId'],
      },
    );
  }

  RtcSignalingEvent _mapCallRejected(Map<String, dynamic> data) {
    return RtcSignalingEvent.callReject(
      callId: data['requestId'] as String? ?? _generateCallId(data),
      fromUserId: data['rejectedBy'] as String? ?? data['userId'] as String? ?? '',
      toUserId: data['listenerId'] as String? ?? '',
    );
  }

  RtcSignalingEvent _mapSessionStarted(Map<String, dynamic> data) {
    // sessionStarted is the server's confirmation that call is active
    // Treat it like a call answer with session info
    final sessionId = data['sessionId'] as String?;
    final roomId = data['roomID'] as String? ?? data['roomId'] as String?;

    // Try to extract user IDs from roomId (format: userId-listenerId-timestamp)
    String? extractedUserId = data['userId'] as String?;
    String? extractedListenerId = data['listenerId'] as String?;

    if ((extractedUserId == null || extractedListenerId == null) && roomId != null) {
      final parts = roomId.split('-');
      if (parts.length >= 2) {
        extractedUserId ??= parts[0];
        extractedListenerId ??= parts[1];
      }
    }

    return RtcSignalingEvent.callAnswer(
      callId: sessionId ?? '',
      fromUserId: extractedUserId ?? 'server',
      toUserId: extractedListenerId ?? 'unknown',
      roomId: roomId ?? sessionId,
      metadata: {
        'sessionId': sessionId,
        'roomID': roomId,
        'type': data['type'],
        'isSessionStarted': true,
        'userId': extractedUserId,
        'listenerId': extractedListenerId,
        'userName': data['userName'],
        'listenerName': data['display_name'],
        'userImage': data['userImage'],
        'listenerImage': data['display_image'],
      },
    );
  }

  RtcSignalingEvent _mapCallEnded(Map<String, dynamic> data) {
    return RtcSignalingEvent.callEnd(
      callId: data['sessionId'] as String? ?? data['requestId'] as String? ?? '',
      fromUserId: data['sessionEndedBy'] as String? ?? data['endedBy'] as String? ?? '',
      toUserId: '',
      metadata: {
        'reason': data['reason'] ?? 'ended',
        'sessionId': data['sessionId'],
      },
    );
  }

  RtcSignalingEvent _mapCallCancelled(Map<String, dynamic> data) {
    return RtcSignalingEvent.callCancel(
      callId: data['requestId'] as String? ?? _generateCallId(data),
      fromUserId: data['cancelledBy'] as String? ?? data['userId'] as String? ?? '',
      toUserId: data['listenerId'] as String? ?? '',
    );
  }

  RtcSignalingEvent _mapCallTimeout(Map<String, dynamic> data) {
    return RtcSignalingEvent.callTimeout(
      callId: data['requestId'] as String? ?? _generateCallId(data),
      fromUserId: data['userId'] as String? ?? '',
      toUserId: data['listenerId'] as String? ?? '',
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // HELPER METHODS
  // ════════════════════════════════════════════════════════════════════════════

  String _generateCallId(Map<String, dynamic> data) {
    final userId = data['userId'] ?? 'unknown';
    final listenerId = data['listenerId'] ?? 'unknown';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'call_${userId}_${listenerId}_$timestamp';
  }

  String _parseCallType(String? type) {
    if (type == null) return 'audio';
    final normalized = type.toLowerCase();
    if (normalized.contains('video')) return 'video';
    if (normalized.contains('audio') || normalized == 'call') return 'audio';
    if (normalized.contains('chat')) return 'chat';
    return 'audio';
  }

  String _mapCallType(String? callType) {
    // Map package call type to your backend's expected format
    switch (callType?.toLowerCase()) {
      case 'video':
        return 'video';
      case 'audio':
        return 'call'; // Your backend might use 'call' for audio
      case 'chat':
        return 'chat';
      default:
        return 'call';
    }
  }
}

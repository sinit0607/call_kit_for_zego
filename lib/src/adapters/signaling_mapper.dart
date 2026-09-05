import '../signaling/rtc_signaling_event.dart';

/// Abstract interface for mapping socket events to RtcSignalingEvent
///
/// Implement this interface to map your backend's socket event format
/// to the generic RtcSignalingEvent format used by the package.
///
/// Example implementation:
/// ```dart
/// class MyBackendMapper implements SignalingMapper {
///   @override
///   RtcSignalingEvent? mapIncomingEvent(String eventName, Map<String, dynamic> data) {
///     switch (eventName) {
///       case 'incoming_call':
///         return RtcSignalingEvent.callOffer(
///           callId: data['id'],
///           fromUserId: data['caller_id'],
///           toUserId: data['receiver_id'],
///           callType: data['type'],
///           roomId: data['room'],
///         );
///       // ... other cases
///     }
///   }
/// }
/// ```
abstract class SignalingMapper {
  /// Map an incoming socket event to RtcSignalingEvent
  ///
  /// Returns null if the event is not recognized
  RtcSignalingEvent? mapIncomingEvent(
    String eventName,
    Map<String, dynamic> data,
  );

  /// Map an RtcSignalingEvent to socket emit format
  ///
  /// Returns the event name and data to emit
  SignalingEmitData mapOutgoingEvent(
    RtcSignalingEvent event, {
    required String currentUserId,
    String? senderName,
    String? senderImage,
    String? receiverName,
    String? receiverImage,
    String? userRole,
  });

  /// Get the socket event name for a given signaling event type
  String getEventName(RtcSignalingEventType type);

  /// List of incoming event names this mapper handles
  List<String> get incomingEventNames;
}

/// Data class for socket emit
class SignalingEmitData {
  final String eventName;
  final Map<String, dynamic> data;

  const SignalingEmitData({
    required this.eventName,
    required this.data,
  });
}

/// Default generic signaling mapper
///
/// Uses standard event names and data format.
/// Override for custom backend integration.
class DefaultSignalingMapper implements SignalingMapper {
  @override
  List<String> get incomingEventNames => [
    'call_offer',
    'call_answer',
    'call_reject',
    'call_cancel',
    'call_end',
    'call_timeout',
    'call_busy',
  ];

  @override
  RtcSignalingEvent? mapIncomingEvent(
    String eventName,
    Map<String, dynamic> data,
  ) {
    try {
      switch (eventName) {
        case 'call_offer':
        case 'incoming_call':
          return _mapCallOffer(data);

        case 'call_answer':
        case 'call_accepted':
          return _mapCallAnswer(data);

        case 'call_reject':
        case 'call_rejected':
          return _mapCallReject(data);

        case 'call_cancel':
        case 'call_cancelled':
          return _mapCallCancel(data);

        case 'call_end':
        case 'call_ended':
          return _mapCallEnd(data);

        case 'call_timeout':
          return _mapCallTimeout(data);

        case 'call_busy':
          return _mapCallBusy(data);

        default:
          return null;
      }
    } catch (e) {
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
    final data = <String, dynamic>{
      'callId': event.callId,
      'fromUserId': event.fromUserId,
      'toUserId': event.toUserId,
      if (event.callType != null) 'callType': event.callType,
      if (event.roomId != null) 'roomId': event.roomId,
      if (senderName != null) 'senderName': senderName,
      if (senderImage != null) 'senderImage': senderImage,
      if (receiverName != null) 'receiverName': receiverName,
      if (receiverImage != null) 'receiverImage': receiverImage,
      if (event.metadata != null) ...event.metadata!,
    };

    // Add event-specific fields
    switch (event.type) {
      case RtcSignalingEventType.callReject:
        data['rejectedBy'] = currentUserId;
        break;
      case RtcSignalingEventType.callCancel:
        data['cancelledBy'] = currentUserId;
        break;
      case RtcSignalingEventType.callEnd:
        data['endedBy'] = currentUserId;
        data['endedByRole'] = userRole ?? 'user';
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
        return 'call_offer';
      case RtcSignalingEventType.callAnswer:
        return 'call_answer';
      case RtcSignalingEventType.callReject:
        return 'call_reject';
      case RtcSignalingEventType.callCancel:
        return 'call_cancel';
      case RtcSignalingEventType.callEnd:
        return 'call_end';
      case RtcSignalingEventType.callTimeout:
        return 'call_timeout';
      case RtcSignalingEventType.callBusy:
        return 'call_busy';
      default:
        return 'unknown';
    }
  }

  RtcSignalingEvent _mapCallOffer(Map<String, dynamic> data) {
    return RtcSignalingEvent.callOffer(
      callId: data['callId'] ?? data['id'] ?? _generateCallId(data),
      fromUserId: data['fromUserId'] ?? data['callerId'] ?? '',
      toUserId: data['toUserId'] ?? data['calleeId'] ?? '',
      callType: data['callType'] ?? data['type'] ?? 'audio',
      roomId: data['roomId'] ?? data['room'],
      metadata: _extractMetadata(data),
    );
  }

  RtcSignalingEvent _mapCallAnswer(Map<String, dynamic> data) {
    return RtcSignalingEvent.callAnswer(
      callId: data['callId'] ?? data['id'] ?? '',
      fromUserId: data['fromUserId'] ?? data['calleeId'] ?? '',
      toUserId: data['toUserId'] ?? data['callerId'] ?? '',
      roomId: data['roomId'] ?? data['room'],
      metadata: _extractMetadata(data),
    );
  }

  RtcSignalingEvent _mapCallReject(Map<String, dynamic> data) {
    return RtcSignalingEvent.callReject(
      callId: data['callId'] ?? data['id'] ?? '',
      fromUserId: data['fromUserId'] ?? data['rejectedBy'] ?? '',
      toUserId: data['toUserId'] ?? '',
      metadata: _extractMetadata(data),
    );
  }

  RtcSignalingEvent _mapCallCancel(Map<String, dynamic> data) {
    return RtcSignalingEvent.callCancel(
      callId: data['callId'] ?? data['id'] ?? '',
      fromUserId: data['fromUserId'] ?? data['cancelledBy'] ?? '',
      toUserId: data['toUserId'] ?? '',
      metadata: _extractMetadata(data),
    );
  }

  RtcSignalingEvent _mapCallEnd(Map<String, dynamic> data) {
    return RtcSignalingEvent.callEnd(
      callId: data['callId'] ?? data['id'] ?? '',
      fromUserId: data['fromUserId'] ?? data['endedBy'] ?? '',
      toUserId: data['toUserId'] ?? '',
      metadata: {
        'reason': data['reason'] ?? 'ended',
        ..._extractMetadata(data),
      },
    );
  }

  RtcSignalingEvent _mapCallTimeout(Map<String, dynamic> data) {
    return RtcSignalingEvent.callTimeout(
      callId: data['callId'] ?? data['id'] ?? '',
      fromUserId: data['fromUserId'] ?? '',
      toUserId: data['toUserId'] ?? '',
      metadata: _extractMetadata(data),
    );
  }

  RtcSignalingEvent _mapCallBusy(Map<String, dynamic> data) {
    return RtcSignalingEvent.callBusy(
      callId: data['callId'] ?? data['id'] ?? '',
      fromUserId: data['fromUserId'] ?? '',
      toUserId: data['toUserId'] ?? '',
      metadata: _extractMetadata(data),
    );
  }

  String _generateCallId(Map<String, dynamic> data) {
    final from = data['fromUserId'] ?? data['callerId'] ?? 'unknown';
    final to = data['toUserId'] ?? data['calleeId'] ?? 'unknown';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'call_${from}_${to}_$timestamp';
  }

  Map<String, dynamic> _extractMetadata(Map<String, dynamic> data) {
    final metadata = <String, dynamic>{};

    // Extract common metadata fields
    final metadataFields = [
      'sessionId', 'senderName', 'senderImage',
      'receiverName', 'receiverImage', 'extra',
    ];

    for (final field in metadataFields) {
      if (data.containsKey(field)) {
        metadata[field] = data[field];
      }
    }

    // Include nested metadata if present
    if (data['metadata'] is Map) {
      metadata.addAll(data['metadata'] as Map<String, dynamic>);
    }

    return metadata;
  }
}

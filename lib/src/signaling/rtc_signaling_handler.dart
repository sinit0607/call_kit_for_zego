import '../models/call_user.dart';
import '../utils/rtc_logger.dart';
import 'rtc_signaling_event.dart';

/// Callback to send signaling events through your socket/signaling channel
///
/// When the controller needs to signal the remote peer, it calls this.
/// Your app should send the event via socket/HTTP/etc.
typedef OnSendSignalingEvent = Future<void> Function(RtcSignalingEvent event);

/// Handles signaling integration for RtcCallController
///
/// This bridges the gap between the call engine and your signaling system.
/// The controller uses this to send/receive signaling events.
class RtcSignalingHandler {
  static const String _tag = 'RtcSignalingHandler';

  /// Callback to send events to remote peer
  OnSendSignalingEvent? onSendEvent;

  /// Current user ID (needed for from/to mapping)
  String? currentUserId;

  /// Callback when a signaling event is successfully sent
  Function(RtcSignalingEvent event)? onEventSent;

  /// Callback when sending a signaling event fails
  Function(RtcSignalingEvent event, dynamic error)? onEventSendFailed;

  RtcSignalingHandler({
    this.onSendEvent,
    this.currentUserId,
  });

  /// Send a call reject to remote peer
  ///
  /// Call this when rejecting an incoming call.
  Future<void> sendCallReject({
    required String callId,
    required String toUserId,
    Map<String, dynamic>? metadata,
  }) async {
    if (currentUserId == null) {
      RtcLogger.error('[$_tag] Cannot send call reject: currentUserId is null');
      return;
    }

    // AUDIO CALL LOGGING: Log outgoing reject for audio calls
    final isAudioCall = metadata?['isAudio'] == true || metadata?['callType'] == 'audio';
    if (isAudioCall) {
      RtcLogger.audioSignaling(
        event: 'CALL_REJECT',
        direction: 'emit',
        metadata: {
          'callId': callId,
          'toUserId': toUserId,
          'metadataKeys': metadata?.keys.toList() ?? [],
        },
      );
    }

    final event = RtcSignalingEvent.callReject(
      callId: callId,
      fromUserId: currentUserId!,
      toUserId: toUserId,
      metadata: metadata,
    );

    await _sendEvent(event);
  }

  /// Send a call cancel to remote peer
  ///
  /// Call this when canceling an outgoing call before it's answered.
  Future<void> sendCallCancel({
    required String callId,
    required String toUserId,
    Map<String, dynamic>? metadata,
  }) async {
    if (currentUserId == null) {
      RtcLogger.error('[$_tag] Cannot send call cancel: currentUserId is null');
      return;
    }

    // AUDIO CALL LOGGING: Log outgoing cancel for audio calls
    final isAudioCall = metadata?['isAudio'] == true || metadata?['callType'] == 'audio';
    if (isAudioCall) {
      RtcLogger.audioSignaling(
        event: 'CALL_CANCEL',
        direction: 'emit',
        metadata: {
          'callId': callId,
          'toUserId': toUserId,
          'metadataKeys': metadata?.keys.toList() ?? [],
        },
      );
    }

    final event = RtcSignalingEvent.callCancel(
      callId: callId,
      fromUserId: currentUserId!,
      toUserId: toUserId,
      metadata: metadata,
    );

    await _sendEvent(event);
  }

  /// Send a call end to remote peer
  ///
  /// Call this when ending an active call.
  Future<void> sendCallEnd({
    required String callId,
    required String toUserId,
    Map<String, dynamic>? metadata,
  }) async {
    if (currentUserId == null) {
      RtcLogger.error('[$_tag] Cannot send call end: currentUserId is null');
      return;
    }

    // AUDIO CALL LOGGING: Log outgoing call end for audio calls
    final isAudioCall = metadata?['isAudio'] == true || metadata?['callType'] == 'audio';
    if (isAudioCall) {
      RtcLogger.audioSignaling(
        event: 'CALL_END',
        direction: 'emit',
        metadata: {
          'callId': callId,
          'toUserId': toUserId,
          'sessionId': metadata?['sessionId'],
          'metadataKeys': metadata?.keys.toList() ?? [],
        },
      );
    }

    final event = RtcSignalingEvent.callEnd(
      callId: callId,
      fromUserId: currentUserId!,
      toUserId: toUserId,
      metadata: metadata,
    );

    await _sendEvent(event);
  }

  /// Internal method to send event via callback
  Future<void> _sendEvent(RtcSignalingEvent event) async {
    if (onSendEvent == null) {
      RtcLogger.warning(
          '[$_tag] onSendEvent not set, cannot send: ${event.type.name}');
      return;
    }

    // AUDIO CALL LOGGING: Record outgoing signaling event for audio calls
    final isAudioCall = event.metadata?['isAudio'] == true ||
                        event.metadata?['callType'] == 'audio' ||
                        event.callType == 'audio';
    if (isAudioCall) {
      // Record to trace for debugging
    }

    try {
      RtcLogger.info(
          '[$_tag] Sending signaling event: ${event.type.name} for call ${event.callId}');
      await onSendEvent!(event);
      onEventSent?.call(event);
      RtcLogger.success('[$_tag] Successfully sent: ${event.type.name}');
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to send signaling event', e, stack);
      onEventSendFailed?.call(event, e);
      rethrow;
    }
  }

  /// Helper to create CallUser from signaling event metadata
  static CallUser? userFromMetadata(Map<String, dynamic>? metadata) {
    if (metadata == null) return null;

    final userId = metadata['userId'] as String?;
    final userName = metadata['userName'] as String?;

    if (userId == null || userName == null) return null;

    return CallUser(
      userId: userId,
      userName: userName,
      avatarUrl: metadata['avatarUrl'] as String?,
    );
  }

  /// Helper to add user data to metadata
  static Map<String, dynamic> userToMetadata(CallUser user) {
    return {
      'userId': user.userId,
      'userName': user.userName,
      if (user.avatarUrl != null) 'avatarUrl': user.avatarUrl,
    };
  }

  /// Dispose and cleanup
  void dispose() {
    RtcLogger.info('[$_tag] Disposing signaling handler');
    onSendEvent = null;
    onEventSent = null;
    onEventSendFailed = null;
    currentUserId = null;
  }
}

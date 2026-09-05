import 'dart:async';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import '../utils/rtc_logger.dart';

/// Handles CallKit events and forwards them to the appropriate handlers
///
/// This is the bridge between native CallKit events and your call engine.
/// It listens to events from flutter_callkit_incoming and delegates them
/// to registered handlers.
class CallKitEventHandler {
  static const String _tag = 'CallKitEventHandler';

  StreamSubscription<CallEvent?>? _eventSubscription;
  bool _isListening = false;

  // Event callbacks
  Function(String callId)? onAcceptCall;
  Function(String callId)? onDeclineCall;
  Function(String callId)? onEndCall;
  Function(String callId)? onTimeout;
  Function(String callId)? onMissedCallCallback;

  // Track processed events to ensure idempotency
  final Set<String> _processedEvents = {};

  /// Start listening to CallKit events
  void startListening(Stream<CallEvent?> eventStream) {
    if (_isListening) {
      RtcLogger.warning('[$_tag] Already listening to events');
      return;
    }

    RtcLogger.info('[$_tag] Starting to listen to CallKit events');
    _isListening = true;

    _eventSubscription = eventStream.listen(
      _handleEvent,
      onError: (error, stackTrace) {
        RtcLogger.error('[$_tag] Event stream error', error, stackTrace);
      },
      onDone: () {
        RtcLogger.info('[$_tag] Event stream closed');
        _isListening = false;
      },
    );
  }

  /// Stop listening to events
  void stopListening() {
    if (!_isListening) return;

    RtcLogger.info('[$_tag] Stopping event listener');
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _isListening = false;
    _processedEvents.clear();
  }

  /// Handle incoming CallKit event
  ///
  /// [CallEvent] is a sealed hierarchy, so the switch below IS the event
  /// mapping — no string table needed, and adding a new event type in the
  /// plugin becomes a compile error here rather than a silent fallthrough.
  void _handleEvent(CallEvent? event) {
    if (event == null) {
      RtcLogger.warning('[$_tag] Received null event');
      return;
    }

    // NOTE: timeout/callback events carry only the CallKit UUID (the
    // plugin dropped `extra` from them in 3.1.x). Both consumers ignore the
    // id today; if one starts using it, resolve via
    // NativeCallKitService.getOriginalCallId().
    final action = switch (event) {
      CallEventActionCallAccept(:final callKitParams) =>
        (onAcceptCall, _callIdOf(callKitParams)),
      CallEventActionCallDecline(:final callKitParams) =>
        (onDeclineCall, _callIdOf(callKitParams)),
      CallEventActionCallEnded(:final callKitParams) =>
        (onEndCall, _callIdOf(callKitParams)),
      CallEventActionCallTimeout(:final id) => (onTimeout, id),
      CallEventActionCallCallback(:final id) => (onMissedCallCallback, id),
      _ => null,
    };

    if (action == null) {
      RtcLogger.info('[$_tag] Ignoring event: ${event.eventName}');
      return;
    }

    final (callback, callId) = action;
    if (callId == null || callId.isEmpty) {
      RtcLogger.warning('[$_tag] Event missing call ID: ${event.eventName}');
      return;
    }

    // Idempotency: same event for same call within a 1-second bucket.
    final eventKey =
        '$callId:${event.eventName}:${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    if (_isDuplicate(eventKey)) {
      RtcLogger.info('[$_tag] Skipping duplicate event: ${event.eventName} for call $callId');
      return;
    }
    _processedEvents.add(eventKey);

    RtcLogger.info('[$_tag] Handling ${event.eventName} for call: $callId');
    try {
      callback?.call(callId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error executing ${event.eventName}', e, stack);
    }
  }

  /// Our own callId, stored in `extra` when the call was shown; the CallKit
  /// UUID is the fallback.
  String? _callIdOf(CallKitParams params) =>
      params.extra?['originalCallId'] as String? ?? params.id;

  /// Check if event is a duplicate within time window
  bool _isDuplicate(String eventKey) {
    // Clean up old events (older than 5 seconds)
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _processedEvents.removeWhere((key) {
      final timestamp = int.tryParse(key.split(':').last) ?? 0;
      return now - timestamp > 5;
    });

    return _processedEvents.contains(eventKey);
  }

  /// Dispose and cleanup
  void dispose() {
    RtcLogger.info('[$_tag] Disposing CallKit event handler');
    stopListening();
    _processedEvents.clear();
  }
}

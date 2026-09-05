import 'dart:async';
import 'dart:collection';

import '../../adapters/socket_adapter.dart';
import '../../adapters/signaling_mapper.dart';
import '../../controllers/rtc_call_controller.dart';
import '../../api/models/call_event.dart';
import '../../api/models/user_info.dart';
import '../../models/call_data.dart';
import '../../models/call_user.dart';
import '../../models/call_state.dart';
import '../../models/call_end_reason.dart';
import '../../signaling/rtc_signaling_event.dart';
import '../../utils/rtc_logger.dart';
import '../session/session_manager.dart';
import '../../plugins/call_storage_plugin.dart';

import '../../models/call_type.dart';

/// Manages call lifecycle and socket events
///
/// This manager:
/// - Accepts socket instance as dependency (does NOT create it)
/// - Registers call-related socket listeners
/// - Wraps RtcCallController for call operations
/// - Emits normalized CallEvent stream for main app
/// - Handles duplicate events and reconnection
class CallManager {
  static const String _tag = 'CallManager';
  static const int _millisecondsPerSecond = 1000;
  static const Duration _sessionStartedTimeout = Duration(seconds: 30);

  final SocketAdapter _socket;
  final RtcCallController _rtcController;
  final SessionManager _sessionManager;
  final SignalingMapper _signalingMapper;

  /// Optional call storage plugin for FCM data recovery
  CallStoragePlugin? callStoragePlugin;

  final _eventController = StreamController<CallEvent>.broadcast();

  Stream<CallEvent> get events => _eventController.stream;

  // Track processed events to prevent duplicates (FIFO queue for bounded memory)
  final Queue<String> _processedEventsQueue = Queue<String>();
  final Set<String> _processedEventsSet = {};
  static const int _maxProcessedEvents = 100;

  // Current call state
  String? _currentCallId;
  CallState _currentState = CallState.idle;
  CallState? _previousEmittedState; // Track previous state to prevent duplicate events

  // Session started timeout handling
  Timer? _sessionStartedTimer;
  bool _sessionStartedReceived = false;

  CallManager({
    required SocketAdapter socket,
    required RtcCallController rtcController,
    required SessionManager sessionManager,
    required SignalingMapper signalingMapper,
    this.callStoragePlugin,
  }) : _socket = socket,
       _rtcController = rtcController,
       _sessionManager = sessionManager,
       _signalingMapper = signalingMapper {
    _registerSocketListeners();
    _setupRtcCallbacks();
    _setupSignalingHandler();
  }

  /// Register socket listeners for call events
  ///
  /// IMPORTANT: This only ATTACHES listeners, does NOT call socket.connect()
  void _registerSocketListeners() {
    RtcLogger.info('[$_tag] Registering call socket listeners');

    // Register listeners for all event names the mapper handles
    for (final eventName in _signalingMapper.incomingEventNames) {
      RtcLogger.info('[$_tag] 📡 Registering socket listener for: $eventName');
      _socket.on(eventName, (data) => _handleIncomingSocketEvent(eventName, data));
    }
  }

  /// Handle incoming socket event
  void _handleIncomingSocketEvent(String eventName, dynamic data) async {
    try {
      RtcLogger.info('[$_tag] 📥 RAW SOCKET EVENT: $eventName | data: $data');
      final eventData = data as Map<String, dynamic>;

      // Map the event using the signaling mapper
      final signalingEvent = _signalingMapper.mapIncomingEvent(eventName, eventData);

      if (signalingEvent == null) {
        RtcLogger.warning('[$_tag] Failed to map event: $eventName');
        return;
      }

      // Route to appropriate handler based on event type
      switch (signalingEvent.type) {
        case RtcSignalingEventType.callOffer:
          await _handleIncomingCall(signalingEvent, eventData);
          break;
        case RtcSignalingEventType.callAnswer:
          // Check if this is a sessionStarted event
          final isSessionStarted = signalingEvent.metadata?['isSessionStarted'] == true;
          if (isSessionStarted) {
            await _handleSessionStarted(signalingEvent, eventData);
          } else {
            await _handleCallAccepted(signalingEvent, eventData);
          }
          break;
        case RtcSignalingEventType.callReject:
          await _handleCallRejected(signalingEvent, eventData);
          break;
        case RtcSignalingEventType.callCancel:
          await _handleCallCancelled(signalingEvent, eventData);
          break;
        case RtcSignalingEventType.callEnd:
          await _handleCallEnded(signalingEvent, eventData);
          break;
        case RtcSignalingEventType.callTimeout:
          await _handleCallTimeout(signalingEvent, eventData);
          break;
        case RtcSignalingEventType.callBusy:
          await _handleCallBusy(signalingEvent, eventData);
          break;
        default:
          RtcLogger.warning('[$_tag] Unhandled event type: ${signalingEvent.type}');
      }
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling socket event: $eventName', e, stack);
    }
  }

  /// Setup callbacks from RtcCallController
  void _setupRtcCallbacks() {
    _rtcController.onCallStateChanged = (callData) {
      _currentCallId = callData.callId;
      _currentState = callData.state;
      _emitCallStateEvent(callData);
    };

    _rtcController.onUserJoined = (user) {
      _eventController.add(
        CallEvent.remoteUserJoined(
          callId: _currentCallId ?? 'unknown',
          remoteUser: UserInfo(
            userId: user.userId,
            userName: user.userName,
            userImage: user.avatarUrl,
          ),
        ),
      );
    };

    _rtcController.onUserLeft = (user) {
      _eventController.add(
        CallEvent.remoteUserLeft(
          callId: _currentCallId ?? 'unknown',
          remoteUser: UserInfo(
            userId: user.userId,
            userName: user.userName,
            userImage: user.avatarUrl,
          ),
        ),
      );
    };

    _rtcController.onError = (error) {
      _eventController.add(
        CallEvent.callFailed(
          callId: _currentCallId ?? 'unknown',
          error: error.message,
        ),
      );
    };

    // ════════════════════════════════════════════════════════════════════
    // CRITICAL: CallKit event handlers
    // When user accepts/declines via native CallKit UI, we need to emit
    // the socket events (accept-request/reject-request)
    // ════════════════════════════════════════════════════════════════════
    // These run fire-and-forget from a native callback, so nothing is awaiting
    // them: an escaping error becomes an unhandled zone exception rather than
    // something the app can react to. Catch here and report it instead.
    _rtcController.onCallKitAccept = (callId) {
      RtcLogger.info('[$_tag] CallKit accept callback triggered for: $callId');
      // Call our acceptCall() which emits socket event
      acceptCall(callId).catchError((Object e, StackTrace stack) {
        RtcLogger.error('[$_tag] CallKit accept failed for $callId', e, stack);
        // The native UI is already showing an active call. Tear it down, or the
        // user is left with a phantom ongoing call they cannot dismiss.
        _abandonCall(callId, 'Could not accept call: $e');
      });
    };

    _rtcController.onCallKitDecline = (callId) {
      RtcLogger.info('[$_tag] CallKit decline callback triggered for: $callId');
      // Call our rejectCall() which emits socket event
      rejectCall(callId).catchError((Object e, StackTrace stack) {
        RtcLogger.error('[$_tag] CallKit decline failed for $callId', e, stack);
        _abandonCall(callId, 'Could not decline call: $e');
      });
    };
  }

  /// Setup signaling handler to emit socket events
  ///
  /// This configures the RTC controller to emit socket events when call state changes.
  void _setupSignalingHandler() {
    final signalingHandler = _rtcController.signalingHandler;
    if (signalingHandler == null) {
      RtcLogger.warning('[$_tag] Signaling handler not available (useSignaling=false?)');
      return;
    }

    // Configure the signaling handler to emit socket events
    signalingHandler.onSendEvent = (event) async {
      RtcLogger.info('[$_tag] 📤 Signaling event to emit: ${event.type.name}');

      // Get current user info for event mapping
      final currentUser = _sessionManager.currentUser;
      if (currentUser == null) {
        RtcLogger.error('[$_tag] Cannot emit signaling event: No current user set');
        return;
      }

      // Convert RTC signaling event to socket format using mapper
      final emitData = _signalingMapper.mapOutgoingEvent(
        event,
        currentUserId: currentUser.userId,
        senderName: currentUser.userName,
        senderImage: currentUser.userImage,
        userRole: currentUser.role,
      );

      // Add additional metadata from the RTC event
      if (event.metadata != null) {
        emitData.data.addAll(event.metadata!);
      }

      RtcLogger.info('[$_tag] 📡 Emitting socket event: ${emitData.eventName}', emitData.data);

      // Emit via socket adapter
      await _socket.emit(emitData.eventName, emitData.data);

      RtcLogger.success('[$_tag] ✅ Socket event emitted: ${emitData.eventName}');
    };

    // Set current user ID for the signaling handler
    signalingHandler.currentUserId = _sessionManager.currentUser?.userId;

    RtcLogger.success('[$_tag] ✅ Signaling handler configured to emit socket events');
  }

  /// Handle incoming call from socket
  Future<void> _handleIncomingCall(RtcSignalingEvent signalingEvent, Map<String, dynamic> eventData) async {
    try {
      // ════════════════════════════════════════════════════════════════════
      // PHASE 1: EARLY VALIDATION - Before any processing
      // ════════════════════════════════════════════════════════════════════

      // Check for current user FIRST (before any processing)
      final currentUser = _sessionManager.currentUser;
      if (currentUser == null) {
        RtcLogger.warning(
          '[$_tag] ❌ REJECTED: No current user session - ignoring incoming call',
        );
        return;
      }

      final callerId = signalingEvent.fromUserId;
      final receiverId = signalingEvent.toUserId;

      RtcLogger.info('[$_tag] 📥 Incoming call event received', {
        'callerId': callerId,
        'receiverId': receiverId,
        'currentUserId': currentUser.userId,
        'callType': signalingEvent.callType,
      });

      // CRITICAL PRE-FILTER: Reject if current user initiated the call
      if (callerId == currentUser.userId) {
        RtcLogger.warning(
          '[$_tag] ❌❌❌ REJECTED: Current user initiated this call - this is an echo/broadcast',
        );
        return;
      }

      // CRITICAL PRE-FILTER: Reject if call is not for current user
      if (receiverId != currentUser.userId) {
        RtcLogger.info('[$_tag] ❌ REJECTED: Call not for current user');
        return;
      }

      // ════════════════════════════════════════════════════════════════════
      // PHASE 2: DUPLICATE CHECK - After ID validation
      // ════════════════════════════════════════════════════════════════════

      final eventId = _generateEventId('incoming', eventData);
      if (_isDuplicate(eventId)) {
        RtcLogger.warning('[$_tag] ❌ REJECTED: Duplicate incoming call event');
        return;
      }

      // FINAL CHECK: Prevent incoming call if already in active call
      if (_currentCallId != null &&
          _currentState != CallState.idle &&
          _currentState != CallState.ended &&
          _currentState != CallState.missed) {
        RtcLogger.warning('[$_tag] ❌ REJECTED: Already in active call');
        return;
      }

      RtcLogger.success(
        '[$_tag] ✅✅✅ ALL FILTERS PASSED - Showing incoming call UI',
      );

      // Extract caller info
      final callerInfo = signalingEvent.metadata?['caller'] as Map<String, dynamic>?;
      final remoteUser = UserInfo(
        userId: signalingEvent.fromUserId,
        userName: callerInfo?['userName'] ?? 'Unknown',
        userImage: callerInfo?['avatarUrl'],
      );

      // Parse call type
      final callTypeStr = signalingEvent.callType ?? 'audio';
      final callType = _parseCallTypeFromString(callTypeStr);

      // Receive incoming call via RTC controller
      await _rtcController.receiveIncomingCall(
        callId: signalingEvent.callId,
        remoteUser: CallUser(
          userId: remoteUser.userId,
          userName: remoteUser.userName,
          avatarUrl: remoteUser.userImage,
        ),
        localUser: CallUser(
          userId: currentUser.userId,
          userName: currentUser.userName,
          avatarUrl: currentUser.userImage,
        ),
        callType: callType,
        roomId: signalingEvent.roomId,
        sessionId: signalingEvent.metadata?['sessionId'],
        metadata: signalingEvent.metadata,
      );

      // Emit public event
      _eventController.add(
        CallEvent.incomingCall(
          callId: signalingEvent.callId,
          remoteUser: remoteUser,
          callType: callType,
          metadata: signalingEvent.metadata,
        ),
      );

      _markProcessed(eventId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling incoming call', e, stack);
    }
  }

  /// Handle call accepted from socket
  Future<void> _handleCallAccepted(RtcSignalingEvent signalingEvent, Map<String, dynamic> eventData) async {
    try {
      final eventId = _generateEventId('accepted', eventData);

      if (_isDuplicate(eventId)) {
        RtcLogger.warning('[$_tag] Duplicate call accepted event ignored');
        return;
      }

      RtcLogger.info('[$_tag] Call accepted', eventData);

      // Pass to RTC controller
      await _rtcController.receiveSignalingEvent(signalingEvent);

      // Emit public event
      _eventController.add(
        CallEvent.callAccepted(callId: signalingEvent.callId),
      );

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: Start timeout for sessionStarted event
      // When remote user accepts call, we must wait for backend's sessionStarted
      // ════════════════════════════════════════════════════════════════════
      _startSessionStartedTimeout(signalingEvent.callId);

      _markProcessed(eventId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling call accepted', e, stack);
    }
  }

  /// Handle call rejected from socket
  Future<void> _handleCallRejected(RtcSignalingEvent signalingEvent, Map<String, dynamic> eventData) async {
    try {
      final eventId = _generateEventId('rejected', eventData);

      if (_isDuplicate(eventId)) {
        RtcLogger.warning('[$_tag] Duplicate call rejected event ignored');
        return;
      }

      RtcLogger.info('[$_tag] Call rejected', eventData);

      // Pass to RTC controller
      await _rtcController.receiveSignalingEvent(signalingEvent);

      // Emit public event
      _eventController.add(
        CallEvent.callDeclined(callId: signalingEvent.callId),
      );

      // CRITICAL: Clear local state when call is rejected by remote
      _clearLocalCallState();

      _markProcessed(eventId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling call rejected', e, stack);
      _clearLocalCallState();
    }
  }

  /// The peer on the current call, as public [UserInfo].
  ///
  /// The app needs this to address the peer's media stream, so it has to ride
  /// along on sessionStarted rather than only on the incoming-call event.
  UserInfo? _remoteUserInfo() {
    final peer = _rtcController.currentCall?.remoteUser;
    if (peer == null) return null;
    return UserInfo(
      userId: peer.userId,
      userName: peer.userName,
      userImage: peer.avatarUrl,
    );
  }

  /// Whether a teardown event refers to the call we are actually on.
  ///
  /// Such events arrive keyed on either our own callId or the server's
  /// sessionId. Anything else is a late event from an earlier call, and acting
  /// on it ends a live call and bounces the user out of the call screen.
  bool _isForCurrentCall(RtcSignalingEvent event) {
    final active = _rtcController.currentCall;
    if (active == null && _currentCallId == null) return true;
    return event.callId == active?.callId ||
        event.callId == active?.sessionId ||
        event.callId == _currentCallId;
  }

  /// Handle call cancelled from socket
  Future<void> _handleCallCancelled(RtcSignalingEvent signalingEvent, Map<String, dynamic> eventData) async {
    try {
      final eventId = _generateEventId('cancelled', eventData);

      if (_isDuplicate(eventId)) {
        RtcLogger.warning('[$_tag] Duplicate call cancelled event ignored');
        return;
      }

      RtcLogger.info('[$_tag] Call cancelled', eventData);

      if (!_isForCurrentCall(signalingEvent)) {
        RtcLogger.warning(
          '[$_tag] ⏭️ IGNORING cancel for a different call',
          {'eventCallId': signalingEvent.callId, 'currentCallId': _currentCallId},
        );
        _markProcessed(eventId);
        return;
      }

      // Pass to RTC controller
      await _rtcController.receiveSignalingEvent(signalingEvent);

      // Emit public event
      _eventController.add(
        CallEvent.callEnded(callId: signalingEvent.callId, reason: 'cancelled'),
      );

      // CRITICAL: Clear local state when call is cancelled
      _clearLocalCallState();

      _markProcessed(eventId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling call cancelled', e, stack);
      _clearLocalCallState();
    }
  }

  /// Handle call ended from socket
  Future<void> _handleCallEnded(RtcSignalingEvent signalingEvent, Map<String, dynamic> eventData) async {
    try {
      final eventId = _generateEventId('ended', eventData);

      if (_isDuplicate(eventId)) {
        RtcLogger.warning('[$_tag] Duplicate call ended event ignored');
        return;
      }

      RtcLogger.info('[$_tag] 🔴🔴🔴 SESSION ENDED EVENT RECEIVED FROM SOCKET', eventData);

      // CRITICAL: Check if we're the one who ended the call
      final currentUser = _sessionManager.currentUser;
      if (currentUser != null) {
        final endedBy = eventData['endedBy'] as String? ??
                        eventData['sessionEndedBy'] as String? ??
                        signalingEvent.fromUserId;

        if (endedBy == currentUser.userId) {
          RtcLogger.info('[$_tag] ⏭️ IGNORING: Session ended by us ($endedBy), already handled locally');
          _markProcessed(eventId);
          return;
        }

        RtcLogger.info('[$_tag] ✅ Session ended by remote peer ($endedBy), processing...');
      }

      // Only tear down if this end belongs to the call we are actually on.
      // It may be keyed on our callId or on the server's sessionId; anything
      // else is a late event from a previous call, and acting on it ended a
      // live call and bounced the user out of the call screen.
      if (!_isForCurrentCall(signalingEvent)) {
        RtcLogger.warning(
          '[$_tag] ⏭️ IGNORING session end for a different call',
          {'eventCallId': signalingEvent.callId, 'currentCallId': _currentCallId},
        );
        _markProcessed(eventId);
        return;
      }

      // Pass to RTC controller
      await _rtcController.receiveSignalingEvent(signalingEvent);

      // Emit public event
      _eventController.add(
        CallEvent.callEnded(
          callId: signalingEvent.callId,
          reason: signalingEvent.metadata?['reason'] ?? 'ended',
        ),
      );

      // CRITICAL: Clear local state when session ends
      _clearLocalCallState();

      RtcLogger.success('[$_tag] ✅ Session ended handling complete');

      _markProcessed(eventId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling call ended', e, stack);
      _clearLocalCallState();
    }
  }

  /// Handle call timeout from socket
  Future<void> _handleCallTimeout(RtcSignalingEvent signalingEvent, Map<String, dynamic> eventData) async {
    try {
      final eventId = _generateEventId('timeout', eventData);

      if (_isDuplicate(eventId)) {
        RtcLogger.warning('[$_tag] Duplicate call timeout event ignored');
        return;
      }

      // CRITICAL: Ignore timeout if session has already started
      if (_sessionStartedReceived) {
        RtcLogger.warning(
          '[$_tag] ⚠️ IGNORING timeout event - Session already started and call is active',
        );
        _markProcessed(eventId);
        return;
      }

      RtcLogger.info('[$_tag] Call timeout', eventData);

      // Pass to RTC controller
      await _rtcController.receiveSignalingEvent(signalingEvent);

      // Emit public event
      _eventController.add(
        CallEvent.callTimeout(callId: signalingEvent.callId),
      );

      // CRITICAL: Clear local state when call times out
      _clearLocalCallState();

      _markProcessed(eventId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling call timeout', e, stack);
      _clearLocalCallState();
    }
  }

  /// Handle call busy from socket
  Future<void> _handleCallBusy(RtcSignalingEvent signalingEvent, Map<String, dynamic> eventData) async {
    try {
      final eventId = _generateEventId('busy', eventData);

      if (_isDuplicate(eventId)) {
        RtcLogger.warning('[$_tag] Duplicate call busy event ignored');
        return;
      }

      RtcLogger.info('[$_tag] Call busy', eventData);

      // Pass to RTC controller
      await _rtcController.receiveSignalingEvent(signalingEvent);

      // Emit public event
      _eventController.add(
        CallEvent.callDeclined(callId: signalingEvent.callId),
      );

      _clearLocalCallState();
      _markProcessed(eventId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Error handling call busy', e, stack);
      _clearLocalCallState();
    }
  }

  /// Handle session started from socket
  ///
  /// CRITICAL: This is THE SINGLE SOURCE OF TRUTH to navigate to call screen.
  /// Backend emits this AFTER accept-request to confirm session is active.
  Future<void> _handleSessionStarted(RtcSignalingEvent signalingEvent, Map<String, dynamic> eventData) async {
    try {
      final eventId = _generateEventId('session_started', eventData);

      if (_isDuplicate(eventId)) {
        RtcLogger.warning('[$_tag] ❌ Duplicate session started event ignored');
        return;
      }

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: Cancel timeout - sessionStarted arrived successfully
      // ════════════════════════════════════════════════════════════════════
      _cancelSessionStartedTimeout();
      _sessionStartedReceived = true;

      RtcLogger.info('[$_tag] 🎉 Session started event received', eventData);

      // Extract critical session data from metadata
      final metadata = signalingEvent.metadata;
      final sessionId = metadata?['sessionId'] as String? ?? signalingEvent.callId;
      final roomId = signalingEvent.roomId ??
                     metadata?['roomID'] as String? ??
                     metadata?['roomId'] as String?;
      final callTypeStr = metadata?['callType'] as String? ?? metadata?['type'] as String?;

      if (roomId == null) {
        RtcLogger.error(
          '[$_tag] ❌ Missing roomId in session started event',
          metadata,
        );
        return;
      }

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: Get current call data BEFORE processing event
      // ════════════════════════════════════════════════════════════════════
      final currentCall = _rtcController.currentCall;

      // AUDIO CALL LOGGING: Add audio-specific logging for session_started events
      final isAudioCall = currentCall?.callType.isAudio ?? (callTypeStr?.toLowerCase() == 'audio');
      if (isAudioCall) {
        RtcLogger.audioCall(
          step: 'AUDIO_SESSION_STARTED_RECEIVED',
          detail: 'Flow: event_received -> processing -> forwarding',
        );
        RtcLogger.audioCall(
          userId: currentCall?.localUser.userId,
          peerId: currentCall?.remoteUser.userId,
          roomId: roomId,
          streamId: null,
          callType: 'audio',
          step: 'SESSION_EXTRACT',
          detail: 'sessionId=$sessionId',
        );
      }

      RtcLogger.success('[$_tag] ✅ Session confirmed by backend', {
        'sessionId': sessionId,
        'roomId': roomId,
        'callType': callTypeStr,
      });

      RtcLogger.info('[$_tag] State transition: accepted -> connecting');

      // Parse call type for event
      final callType = _parseCallTypeFromString(callTypeStr);

      final enrichedMetadata = <String, dynamic>{
        'roomID': roomId,
        'sessionId': sessionId,
        'roomId': roomId,
        ...?metadata,
      };

      // Add user information if we have current call data
      if (currentCall != null) {
        enrichedMetadata['remoteUserId'] = currentCall.remoteUser.userId;
        enrichedMetadata['remoteUserName'] = currentCall.remoteUser.userName;
        enrichedMetadata['remoteUserImage'] = currentCall.remoteUser.avatarUrl ?? '';
        enrichedMetadata['localUserId'] = currentCall.localUser.userId;
        enrichedMetadata['localUserName'] = currentCall.localUser.userName;
        enrichedMetadata['localUserImage'] = currentCall.localUser.avatarUrl ?? '';
      }

      // Now update the signaling event with enriched metadata before processing
      final enrichedSignalingEvent = signalingEvent.copyWith(
        metadata: enrichedMetadata,
      );

      // Pass to RTC controller with enriched metadata
      await _rtcController.receiveSignalingEvent(enrichedSignalingEvent);

      // AUDIO CALL LOGGING: Log forwarding to RTC controller for audio calls
      if (isAudioCall) {
        RtcLogger.audioCall(
          userId: currentCall?.localUser.userId,
          peerId: currentCall?.remoteUser.userId,
          roomId: roomId,
          streamId: null,
          callType: 'audio',
          step: 'SIGNALING_FORWARDED_TO_RTC',
          detail: 'isAudioCall=$isAudioCall',
        );
      }

      // Emit PUBLIC event - THIS IS WHERE THE MAIN APP SHOULD NAVIGATE TO CALL SCREEN
      _eventController.add(
        CallEvent.sessionStarted(
          // The client's own callId, not the server's sessionId: consumers use
          // event.callId to address the call (markCallConnected, CallKit UUID
          // lookup), and those are all keyed on the id we generated. sessionId
          // is carried separately below.
          callId: _currentCallId ?? sessionId,
          sessionId: sessionId,
          roomId: roomId,
          callType: callType,
          remoteUser: _remoteUserInfo(),
          metadata: enrichedMetadata,
        ),
      );

      RtcLogger.success(
        '[$_tag] ✅✅✅ Session started event emitted - Main app should navigate to call screen now',
      );

      _markProcessed(eventId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] ❌ Error handling session started', e, stack);
    }
  }

  /// Emit call state change event
  /// Only emits when state actually changes (prevents duplicate events from duration updates)
  void _emitCallStateEvent(CallData callData) {
    // Skip if state hasn't changed (e.g., duration updates emit state but shouldn't re-emit events)
    if (callData.state == _previousEmittedState) {
      return;
    }
    _previousEmittedState = callData.state;

    switch (callData.state) {
      case CallState.connecting:
        _eventController.add(CallEvent.callConnecting(callId: callData.callId));
        break;
      case CallState.connected:
        _eventController.add(CallEvent.callConnected(callId: callData.callId));
        break;
      case CallState.ended:
        // Handle ended state if needed
        break;
      case CallState.failed:
        // Handle failed state if needed
        break;
      default:
        // Other states handled by specific events
        break;
    }
  }

  /// Generate unique event ID for deduplication
  String _generateEventId(String type, Map<String, dynamic> data) {
    final callId =
        data['requestId'] ?? data['callId'] ?? data['sessionId'] ?? '';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '$type-$callId-${timestamp ~/ _millisecondsPerSecond}'; // Group by second
  }

  /// Check if event was already processed
  bool _isDuplicate(String eventId) {
    return _processedEventsSet.contains(eventId);
  }

  /// Mark event as processed with FIFO eviction
  void _markProcessed(String eventId) {
    // Add to both queue (for FIFO order) and set (for O(1) lookup)
    _processedEventsQueue.addLast(eventId);
    _processedEventsSet.add(eventId);

    // Enforce hard cap with FIFO eviction
    while (_processedEventsQueue.length > _maxProcessedEvents) {
      final oldest = _processedEventsQueue.removeFirst();
      _processedEventsSet.remove(oldest);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // PUBLIC API METHODS
  // ══════════════════════════════════════════════════════════════════════

  /// Start an outgoing call
  Future<CallResult> startCall({
    required String targetUserId,
    required String targetUserName,
    String? targetUserImage,
    required CallType callType,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final currentUser = _sessionManager.currentUser;
      if (currentUser == null) {
        return CallResult(success: false, error: 'No authenticated user');
      }

      // DEFENSIVE CHECK: Log current state before attempting new call
      if (_currentCallId != null || _currentState != CallState.idle) {
        RtcLogger.warning('[$_tag] ⚠️ Attempting to start call while in non-idle state', {
          'existingCallId': _currentCallId,
          'currentState': _currentState.name,
          'newTargetUserId': targetUserId,
        });
      }

      final callId = _generateCallId();
      final roomId =
          '${currentUser.userId}_${targetUserId}_${DateTime.now().millisecondsSinceEpoch}';

      RtcLogger.info('[$_tag] Starting call', {
        'callId': callId,
        'targetUserId': targetUserId,
        'callType': callType.name,
      });

      // Create signaling event for outgoing call
      final signalingEvent = RtcSignalingEvent.callOffer(
        callId: callId,
        fromUserId: currentUser.userId,
        toUserId: targetUserId,
        callType: callType.name,
        roomId: roomId,
        metadata: {
          'caller': {
            'userId': currentUser.userId,
            'userName': currentUser.userName,
            'avatarUrl': currentUser.userImage,
          },
          'callee': {
            'userId': targetUserId,
            'userName': targetUserName,
            'avatarUrl': targetUserImage,
          },
          ...?metadata,
        },
      );

      // Use mapper to emit via socket
      final emitData = _signalingMapper.mapOutgoingEvent(
        signalingEvent,
        currentUserId: currentUser.userId,
        senderName: currentUser.userName,
        senderImage: currentUser.userImage,
        receiverName: targetUserName,
        userRole: currentUser.role,
        receiverImage: targetUserImage,
      );

      await _socket.emit(emitData.eventName, emitData.data);

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: Create the call in RTC controller BEFORE emitting socket
      // ════════════════════════════════════════════════════════════════════
      final localUser = CallUser(
        userId: currentUser.userId,
        userName: currentUser.userName,
        avatarUrl: currentUser.userImage,
      );

      final remoteUser = CallUser(
        userId: targetUserId,
        userName: targetUserName,
        avatarUrl: targetUserImage,
      );

      await _rtcController.startOutgoingCall(
        callId: callId,
        remoteUser: remoteUser,
        localUser: localUser,
        callType: callType,
        roomId: roomId,
        metadata: metadata,
      );

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: Start timeout for sessionStarted event for outgoing calls
      // ════════════════════════════════════════════════════════════════════
      _startSessionStartedTimeout(callId);

      return CallResult(
        success: true,
        callId: callId,
        state: CallState.calling,
      );
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to start call', e, stack);
      return CallResult(success: false, error: e.toString());
    }
  }

  /// Give up on a call that could not be accepted or declined.
  ///
  /// Clears local state, dismisses the native CallKit UI and tells the app,
  /// so a failure from a native callback cannot leave a phantom ongoing call.
  void _abandonCall(String callId, String reason) {
    _eventController.add(CallEvent.callFailed(callId: callId, error: reason));
    _clearLocalCallState();
    _rtcController.endCall(CallEndReason.ended).catchError((Object e) {
      RtcLogger.warning('[$_tag] Cleanup after failed CallKit action: $e');
    });
  }

  /// Accept incoming call
  Future<void> acceptCall(String callId) async {
    try {
      RtcLogger.info('[$_tag] Accepting call', {'callId': callId});

      // Get current call data to extract caller/receiver info
      CallData? currentCallData = _rtcController.currentCall;

      if (currentCallData == null) {
        RtcLogger.warning('[$_tag] No call data yet, waiting for socket event to be processed...');

        // Wait up to 3 seconds for the call data to be available
        const maxWaitMs = 3000;
        const checkIntervalMs = 100;
        var waited = 0;

        while (currentCallData == null && waited < maxWaitMs) {
          await Future.delayed(const Duration(milliseconds: checkIntervalMs));
          waited += checkIntervalMs;
          currentCallData = _rtcController.currentCall;

          if (currentCallData != null) {
            RtcLogger.success('[$_tag] Call data available after ${waited}ms wait');
            break;
          }
        }

        // ════════════════════════════════════════════════════════════════════
        // CRITICAL FIX: If socket event never arrives, initialize from pending data
        // ════════════════════════════════════════════════════════════════════
        if (currentCallData == null) {
          RtcLogger.warning('[$_tag] Socket event never arrived, trying to initialize from pending data...');

          currentCallData = await _initializeCallFromPendingData(callId);

          if (currentCallData == null) {
            RtcLogger.error('[$_tag] Could not initialize call from pending data either');
            throw Exception('No active call to accept (socket event never arrived and no pending data)');
          }

          RtcLogger.success('[$_tag] ✅ Successfully initialized call from pending data');
        }
      }

      await _rtcController.acceptCall();

      // Emit acceptance via socket
      final currentUser = _sessionManager.currentUser;
      if (currentUser != null) {
        final caller = currentCallData.caller;

        RtcLogger.info('[$_tag] Emitting accept-request', {
          'callId': callId,
          'caller': caller.userId,
          'acceptedBy': currentUser.userId,
        });

        // Create signaling event for accept
        final signalingEvent = RtcSignalingEvent(
          type: RtcSignalingEventType.callAnswer,
          callId: callId,
          fromUserId: currentUser.userId,
          toUserId: caller.userId,
          callType: currentCallData.callType.name,
          roomId: currentCallData.roomId,
          metadata: {
            if (currentCallData.sessionId != null)
              'sessionId': currentCallData.sessionId,
          },
        );

        // Use mapper to build socket data
        final emitData = _signalingMapper.mapOutgoingEvent(
          signalingEvent,
          currentUserId: currentUser.userId,
          senderName: currentUser.userName,
          senderImage: currentUser.userImage,
          receiverName: caller.userName,
          receiverImage: caller.avatarUrl,
          userRole: currentUser.role,
        );

        // Add acceptedBy field
        emitData.data['acceptedBy'] = currentUser.userId;

        // Emit accept-request event
        await _socket.emit(emitData.eventName, emitData.data);

        RtcLogger.success(
          '[$_tag] ✅ Accept-request emitted, waiting for sessionStarted...',
        );

        // ════════════════════════════════════════════════════════════════════
        // CRITICAL: Start timeout for sessionStarted event
        // ════════════════════════════════════════════════════════════════════
        _startSessionStartedTimeout(callId);
      }
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to accept call', e, stack);
      rethrow;
    }
  }

  /// Reject incoming call
  Future<void> rejectCall(String callId) async {
    try {
      RtcLogger.info('[$_tag] Rejecting call', {'callId': callId});

      // RTC controller handles reject signaling emission
      await _rtcController.rejectCall();

      // CRITICAL: Clear local state after rejecting
      _clearLocalCallState();

      RtcLogger.info('[$_tag] Call rejected successfully');
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to reject call', e, stack);
      _clearLocalCallState();
      rethrow;
    }
  }

  /// End current call
  Future<void> endCall() async {
    try {
      RtcLogger.info('[$_tag] Ending call', {'callId': _currentCallId});

      // RTC controller handles end signaling emission
      await _rtcController.endCall(CallEndReason.ended);

      // CRITICAL: Always clear local state after ending call
      _clearLocalCallState();

      RtcLogger.success('[$_tag] Call ended successfully');
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to end call', e, stack);
      _clearLocalCallState();
      rethrow;
    }
  }

  /// Toggle microphone mute
  Future<void> toggleMute() async {
    await _rtcController.toggleMute();
  }

  /// Toggle camera on/off
  Future<void> toggleCamera() async {
    await _rtcController.toggleCamera();
  }

  /// Switch camera (front/back)
  Future<void> switchCamera() async {
    await _rtcController.switchCamera();
  }

  /// Toggle speaker
  Future<void> toggleSpeaker() async {
    await _rtcController.switchSpeaker();
  }

  /// Mark call as connected in native CallKit
  Future<void> markCallConnected(String callId) async {
    await _rtcController.markCallConnected(callId);
  }

  /// Get current call ID
  String? get currentCallId => _currentCallId;

  /// Get current call state
  CallState get currentState => _currentState;

  /// Check if there's an active call
  bool get hasActiveCall => _currentState.isActive;

  /// Check if microphone is muted
  bool get isMicrophoneMuted => _rtcController.isMicrophoneMuted;

  /// Check if camera is enabled
  bool get isCameraEnabled => _rtcController.isCameraEnabled;

  /// Check if speaker is enabled
  bool get isSpeakerEnabled => _rtcController.isSpeakerEnabled;

  /// Check if using front camera
  bool get isFrontCamera => _rtcController.isFrontCamera;

  /// Generate unique call ID
  String _generateCallId() {
    return 'call_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Parse CallType from string
  CallType _parseCallTypeFromString(String? callTypeStr) {
    if (callTypeStr == null) return CallType.audio;

    final normalized = callTypeStr.toLowerCase();
    if (normalized == 'video') return CallType.video;
    if (normalized == 'chat') return CallType.chat;
    if (normalized == 'audio') return CallType.audio;

    RtcLogger.warning('[$_tag] Unknown call type: $callTypeStr, defaulting to audio');
    return CallType.audio;
  }

  // ══════════════════════════════════════════════════════════════════════
  // STATE MANAGEMENT HELPERS
  // ══════════════════════════════════════════════════════════════════════

  /// Clear local call state variables
  void _clearLocalCallState() {
    if (_currentCallId != null || _currentState != CallState.idle) {
      RtcLogger.info('[$_tag] 🧹 Clearing CallManager local state', {
        'previousCallId': _currentCallId,
        'previousState': _currentState.name,
      });

      _currentCallId = null;
      _currentState = CallState.idle;
      _previousEmittedState = null;
      _sessionStartedReceived = false;

      RtcLogger.success('[$_tag] ✅ CallManager local state cleared - ready for new calls');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // SESSION STARTED TIMEOUT HANDLING
  // ══════════════════════════════════════════════════════════════════════

  /// Start timeout for sessionStarted event
  void _startSessionStartedTimeout(String callId) {
    _cancelSessionStartedTimeout();
    _sessionStartedReceived = false;

    RtcLogger.info(
      '[$_tag] ⏱️ Starting sessionStarted timeout (${_sessionStartedTimeout.inSeconds}s)',
      {'callId': callId},
    );

    _sessionStartedTimer = Timer(_sessionStartedTimeout, () {
      if (!_sessionStartedReceived) {
        RtcLogger.error(
          '[$_tag] ⏰ Session started timeout - Backend did not emit sessionStarted event',
          {'callId': callId, 'timeout': '${_sessionStartedTimeout.inSeconds}s'},
        );

        // Emit error event
        _eventController.add(
          CallEvent.callFailed(
            callId: callId,
            error: 'Session start timeout - Backend did not respond',
          ),
        );

        // End the call
        endCall();
      }
    });
  }

  /// Cancel sessionStarted timeout
  void _cancelSessionStartedTimeout() {
    if (_sessionStartedTimer != null) {
      RtcLogger.info('[$_tag] ✅ Canceling sessionStarted timeout');
      _sessionStartedTimer?.cancel();
      _sessionStartedTimer = null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // PENDING DATA RECOVERY
  // ══════════════════════════════════════════════════════════════════════

  /// Initialize call from pending data stored via CallStoragePlugin
  ///
  /// This handles the race condition where user accepts call via CallKit notification
  /// before the socket event arrives.
  Future<CallData?> _initializeCallFromPendingData(String callId) async {
    try {
      if (callStoragePlugin == null) {
        RtcLogger.warning('[$_tag] No call storage plugin configured');
        return null;
      }

      RtcLogger.info('[$_tag] 📱 Attempting to recover call data from storage');

      // Get pending call record from storage
      final pendingRecords = await callStoragePlugin!.getCallHistory(limit: 1);

      if (pendingRecords.isEmpty) {
        RtcLogger.warning('[$_tag] No pending call data in storage');
        return null;
      }

      final pendingRecord = pendingRecords.first;
      RtcLogger.info('[$_tag] 📦 Found pending call data', {
        'callId': pendingRecord.callId,
        'remoteUserId': pendingRecord.remoteUserId,
      });

      // Get current user info
      final currentUser = _sessionManager.currentUser;
      if (currentUser == null) {
        RtcLogger.error('[$_tag] No current user session');
        return null;
      }

      // Create remote user from pending record
      final remoteUser = CallUser(
        userId: pendingRecord.remoteUserId,
        userName: pendingRecord.remoteUserName,
        avatarUrl: pendingRecord.remoteUserAvatar,
      );

      // Create local user
      final localUser = CallUser(
        userId: currentUser.userId,
        userName: currentUser.userName,
        avatarUrl: currentUser.userImage,
      );

      // Parse call type
      final callType = _parseCallTypeFromString(pendingRecord.callType);

      // Initialize the call via RTC controller
      await _rtcController.receiveIncomingCall(
        callId: callId,
        remoteUser: remoteUser,
        localUser: localUser,
        callType: callType,
        roomId: 'pending_$callId',
        metadata: {'initializedFromStorage': true},
      );

      RtcLogger.success('[$_tag] ✅ Successfully initialized call from storage');

      return _rtcController.currentCall;
    } catch (e, stack) {
      RtcLogger.error('[$_tag] ❌ Failed to initialize call from pending data', e, stack);
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════

  /// Dispose resources
  ///
  /// IMPORTANT: This removes socket listeners but does NOT dispose the socket
  void dispose() {
    RtcLogger.info('[$_tag] Disposing CallManager');

    // Cancel any active timeouts
    _cancelSessionStartedTimeout();

    // Remove all socket listeners
    for (final eventName in _signalingMapper.incomingEventNames) {
      try {
        _socket.off(eventName);
      } catch (e) {
        RtcLogger.warning('[$_tag] Failed to remove listener: $eventName', e);
      }
    }

    // Clear state
    _processedEventsQueue.clear();
    _processedEventsSet.clear();
    _clearLocalCallState();
    _sessionStartedReceived = false;

    // Close event stream
    _eventController.close();
  }
}

/// Result of a call operation
class CallResult {
  final bool success;
  final String? callId;
  final String? error;
  final CallState? state;

  CallResult({required this.success, this.callId, this.error, this.state});
}

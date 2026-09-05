import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import '../config/rtc_call_config.dart';
import '../models/call_data.dart';
import '../models/call_error.dart';
import '../models/call_state.dart';
import '../models/call_end_reason.dart';
import '../models/call_type.dart';
import '../models/call_user.dart';
import '../services/zego_service.dart';
import '../services/call_state_manager.dart';
import '../services/call_timeout_manager.dart';
import '../services/network_monitor.dart';
import '../utils/rtc_logger.dart';
import '../native_callkit/native_callkit_service.dart';
import '../native_callkit/native_callkit_config.dart';
import '../native_callkit/callkit_event_handler.dart';
import '../signaling/rtc_signaling_handler.dart';
import '../signaling/rtc_signaling_event.dart';
import '../plugins/analytics_plugin.dart';
import '../plugins/crash_reporting_plugin.dart';
import '../plugins/call_storage_plugin.dart';
import '../core/chat/chat_manager.dart';
import '../api/models/chat_event.dart';
import '../api/models/chat_message.dart';
import '../api/models/user_info.dart';

/// Main controller for RTC calling functionality
/// This is the primary API that host apps will interact with
///
/// Features:
/// - Start/receive/end calls
/// - WhatsApp-like call timeouts
/// - Network reconnection
/// - State management
/// - UI injection via callbacks
class RtcCallController {
  final RtcCallConfig config;
  final int zegoAppId;
  final String zegoAppSign;

  late final ZegoService _zegoService;
  late final CallStateManager _stateManager;
  late final CallTimeoutManager _timeoutManager;
  late final NetworkMonitor _networkMonitor;

  // Optional native CallKit support
  NativeCallKitService? _nativeCallKit;
  CallKitEventHandler? _callKitEventHandler;
  final NativeCallKitConfig? nativeCallKitConfig;
  final bool useCallKit; // Flag to enable/disable CallKit

  // Optional socket signaling support
  RtcSignalingHandler? _signalingHandler;
  final bool useSignaling;

  // Optional plugins for analytics, crash reporting, etc.
  AnalyticsPlugin? analyticsPlugin;
  CrashReportingPlugin? crashReportingPlugin;
  CallStoragePlugin? callStoragePlugin;

  // Chat support - injected by RtcCommunicationService (non-owning reference)
  ChatManager? chatManager;

  // Performance tracking (internal)
  DateTime? _callStartTime;
  DateTime? _callConnectedTime;

  bool _isInitialized = false;
  Timer? _durationTimer;

  // ══════════════════════════════════════════════════════════════════════
  // UI INJECTION CALLBACKS
  // Host app provides these to control UI rendering
  // ══════════════════════════════════════════════════════════════════════

  /// Called when call state changes
  Function(CallData callData)? onCallStateChanged;

  /// Called when an incoming call is received
  Function(CallData callData)? onIncomingCall;

  /// Called when remote user accepts the call
  Function(CallData callData)? onCallAccepted;

  /// Called when remote user rejects the call
  Function(CallData callData, CallEndReason reason)? onCallRejected;

  /// Called when call ends
  Function(CallData callData, CallEndReason reason)? onCallEnded;

  /// Called when call times out
  Function(CallData callData)? onCallTimeout;

  /// Called when a call is missed
  Function(CallData callData)? onMissedCall;

  /// Called when remote user joins the call
  Function(CallUser user)? onUserJoined;

  /// Called when remote user leaves the call
  Function(CallUser user)? onUserLeft;

  /// Called when an error occurs
  Function(CallError error)? onError;

  /// Called when network is reconnecting
  VoidCallback? onReconnecting;

  /// Called when network reconnects successfully
  VoidCallback? onReconnected;

  /// Called when user accepts call via native CallKit UI
  /// Callback should handle emitting socket events (accept-request)
  Function(String callId)? onCallKitAccept;

  /// Called when user declines call via native CallKit UI
  /// Callback should handle emitting socket events (reject-request)
  Function(String callId)? onCallKitDecline;

  // ══════════════════════════════════════════════════════════════════════
  // CHAT CALLBACKS (bridged from ChatManager)
  // ══════════════════════════════════════════════════════════════════════

  /// Called when a chat message is received
  Function(ChatMessage message)? onChatMessageReceived;

  /// Called when a chat session starts
  Function(String sessionId, UserInfo? remoteUser)? onChatSessionStarted;

  /// Called when a chat session ends
  Function(String sessionId, String? reason)? onChatSessionEnded;

  /// Called when a message status changes (delivered, read, failed)
  Function(String messageId, MessageStatus status)? onChatMessageStatusChanged;

  RtcCallController({
    required this.zegoAppId,
    required this.zegoAppSign,
    RtcCallConfig? config,
    this.nativeCallKitConfig,
    this.useCallKit = true, // Default: true (use CallKit if config provided)
    this.useSignaling = false,
    this.chatManager,
  }) : config = config ?? const RtcCallConfig() {
    _zegoService = ZegoService(this.config);
    _stateManager = CallStateManager();
    _timeoutManager = CallTimeoutManager(this.config);
    _networkMonitor = NetworkMonitor();

    // Initialize native CallKit if config is provided AND useCallKit is true
    if (nativeCallKitConfig != null && useCallKit) {
      _nativeCallKit = NativeCallKitService(config: nativeCallKitConfig!);
      _callKitEventHandler = CallKitEventHandler();
    }

    // Initialize signaling handler if enabled
    if (useSignaling) {
      _signalingHandler = RtcSignalingHandler();
    }
  }

  /// Initialize the RTC service
  /// Must be called before any other operations
  Future<void> init() async {
    if (_isInitialized) {
      RtcLogger.warning('RtcCallController already initialized');
      return;
    }

    try {
      RtcLogger.init(config);
      RtcLogger.info('Initializing RtcCallController', {
        'appId': zegoAppId,
        'config': config.toString(),
      });

      // Initialize ZEGO engine
      await _zegoService.initialize(
        appId: zegoAppId,
        appSign: zegoAppSign,
      );

      // Setup ZEGO callbacks
      _setupZegoCallbacks();

      // Setup state manager listener
      _stateManager.stateStream.listen(_handleStateChange);

      // Start network monitoring
      _networkMonitor.startMonitoring();
      _networkMonitor.onConnectivityChanged = _handleNetworkChange;

      // Initialize native CallKit if enabled AND useCallKit flag is true
      if (useCallKit && _nativeCallKit != null && _callKitEventHandler != null) {
        RtcLogger.info('Initializing native CallKit support');
        await _nativeCallKit!.initialize();
        _setupCallKitEventHandlers();
        _callKitEventHandler!.startListening(_nativeCallKit!.eventStream);
        RtcLogger.success('Native CallKit initialized successfully');
      } else if (!useCallKit && nativeCallKitConfig != null) {
        RtcLogger.info('CallKit disabled by useCallKit flag - app will handle call UI');
      }

      // Subscribe to ChatManager events if injected
      if (chatManager != null) {
        _setupChatEventSubscription();
      }

      _isInitialized = true;
      RtcLogger.success('RtcCallController initialized successfully');
    } catch (e, stackTrace) {
      RtcLogger.error('Failed to initialize RtcCallController', e, stackTrace);
      onError?.call(CallError.unknown(
        message: 'Initialization failed',
        exception: e,
        stackTrace: stackTrace,
      ));
      rethrow;
    }
  }

  /// Setup ZEGO service callbacks
  void _setupZegoCallbacks() {
    _zegoService.onUserJoined = (userId) {
      final currentCall = _stateManager.currentCall;
      if (currentCall != null) {
        onUserJoined?.call(currentCall.remoteUser);
      }
    };

    _zegoService.onUserLeft = (userId) {
      final currentCall = _stateManager.currentCall;
      if (currentCall != null) {
        onUserLeft?.call(currentCall.remoteUser);
        _handleRemoteUserLeft();
      }
    };

    // ════════════════════════════════════════════════════════════════════
    // CRITICAL: Auto-play remote streams when they're added
    // ════════════════════════════════════════════════════════════════════
    _zegoService.onStreamAdded = (streamId) async {
      RtcLogger.info('🔔🔔🔔 onStreamAdded callback FIRED - streamId: $streamId');

      final currentCall = _stateManager.currentCall;
      if (currentCall == null) {
        RtcLogger.warning('⚠️ Stream added but no current call');
        return;
      }

      RtcLogger.info('🔔 Current call details:', {
        'callId': currentCall.callId,
        'callType': currentCall.callType.name,
        'isVideo': currentCall.callType.isVideo,
        'isAudio': currentCall.callType.isAudio,
        'requiresMedia': currentCall.callType.requiresMedia,
        'isIncoming': currentCall.isIncoming,
        'roomId': currentCall.roomId,
      });

      // For AUDIO calls: auto-play the stream (no canvas needed)
      // For VIDEO calls: DON'T auto-play, let the video widget handle it with canvas
      if (currentCall.callType.isVideo) {
        RtcLogger.info('📹 Video call detected - video widget will handle stream playback with canvas');
        RtcLogger.info('   Stream ID: $streamId');
        RtcLogger.info('   ⚠️ Make sure RtcRemoteVideoView is displayed in UI to render this stream');
      } else {
        // Audio call - safe to auto-play without canvas
        RtcLogger.info('🎙️🎙️🎙️ AUDIO CALL DETECTED - AUTO-PLAYING STREAM NOW');
        RtcLogger.info('🎙️ About to call: await _zegoService.playStream(streamId: $streamId)');

        // ════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log audio subscribe attempt from onStreamAdded
        // ════════════════════════════════════════════════════════════════════
        RtcLogger.audioSubscribe(
          streamId: streamId,
          success: true,
          userId: currentCall.localUser.userId,
          roomId: currentCall.roomId,
          peerId: currentCall.remoteUser.userId,
        );

        try {
          await _zegoService.playStream(streamId: streamId);
          RtcLogger.success('✅✅✅ Audio stream playback started successfully for audio call');

          // ════════════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log audio subscribe success from onStreamAdded
          // ════════════════════════════════════════════════════════════════════
          RtcLogger.audioSubscribe(
            streamId: streamId,
            success: true,
            userId: currentCall.localUser.userId,
            roomId: currentCall.roomId,
            peerId: currentCall.remoteUser.userId,
          );
        } catch (e, stackTrace) {
          RtcLogger.error('❌❌❌ Failed to start playing audio stream', e, stackTrace);

          // ════════════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log audio subscribe failure from onStreamAdded
          // ════════════════════════════════════════════════════════════════════
          RtcLogger.audioSubscribe(
            streamId: streamId,
            success: false,
            userId: currentCall.localUser.userId,
            roomId: currentCall.roomId,
            peerId: currentCall.remoteUser.userId,
            error: e.toString(),
          );
        }
      }
    };

    _zegoService.onStreamRemoved = (streamId) {
      RtcLogger.info('Remote stream removed', streamId);
      // No need to stop playback, ZEGO handles it automatically
    };

    // CRITICAL: Track when stream playback actually starts/fails
    _zegoService.onStreamPlaying = (streamId) {
      RtcLogger.success('✅ REMOTE STREAM IS NOW PLAYING — audio should be audible!');
    };

    _zegoService.onStreamPlayingFailed = (streamId, errorCode) {
      RtcLogger.error('❌ REMOTE STREAM PLAYBACK FAILED — audio will NOT be audible! Error: $errorCode');
      RtcLogger.error('   This explains why the other party cannot hear anything.');
      RtcLogger.error('   Try: (1) Ensure audio route is set, (2) Check if stream has audio track, (3) Check ZEGO dashboard');
    };

    _zegoService.onError = (error) {
      onError?.call(error);
    };

    _zegoService.onRoomError = (errorCode) {
      RtcLogger.error('ZEGO Room error occurred', errorCode);

      // Critical errors that should end the call immediately
      // NOTE: 1001005 (Network disconnected) is NOT here - we let ZEGO attempt reconnection
      // instead of immediately ending the call on network switch (WiFi ↔ Mobile)
      final criticalErrors = [
        1002001, // Already logged in to another room
        1002004, // Room not exist
        1002005, // Room authentication failed
        1002053, // Room connection failed
        1003023, // Not logged in to room
      ];

      if (criticalErrors.contains(errorCode)) {
        RtcLogger.error(
          'CRITICAL ZEGO ERROR $errorCode - Ending call and notifying remote peer',
        );

        // Emit error to main app
        onError?.call(CallError.roomJoinFailed(
          message: 'Critical room error: $errorCode',
        ));

        // End the call with emission to notify remote peer
        // Use a delayed call to ensure the error callback completes first
        Future.microtask(() async {
          try {
            await endCall(CallEndReason.failed, emitSignalingEvent: true);
          } catch (e) {
            RtcLogger.error('Failed to end call after room error', e);
          }
        });
      } else {
        // Non-critical error, just notify
        onError?.call(CallError.roomJoinFailed(
          message: 'Room error: $errorCode',
        ));
      }
    };

    _zegoService.onReconnecting = () {
      onReconnecting?.call();
      _stateManager.transitionToReconnecting();
    };

    _zegoService.onReconnected = () async {
      RtcLogger.info('🔄 ZEGO reconnected - reinitializing media tracks...');
      onReconnected?.call();
      _stateManager.transitionToConnected();

      // CRITICAL: Re-negotiate streams to restore audio/video after network recovery
      // This fixes Issue #1: Video & audio not resuming after network reconnect
      final success = await _zegoService.reNegotiateStreams();
      if (success) {
        RtcLogger.success('✅ Media tracks reinitialized after reconnect');
      } else {
        RtcLogger.warning('⚠️ Failed to reinitialize media tracks - call may have no audio/video');
      }
    };
  }

  /// Setup native CallKit event handlers
  void _setupCallKitEventHandlers() {
    if (_callKitEventHandler == null) return;

    // Accept call event
    _callKitEventHandler!.onAcceptCall = (callId) {
      RtcLogger.info('CallKit: User accepted call via native UI');

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: Use callback if provided (for socket event emission)
      // Otherwise fall back to local acceptCall()
      // ════════════════════════════════════════════════════════════════════
      if (onCallKitAccept != null) {
        RtcLogger.info('CallKit: Calling onCallKitAccept callback (emits socket event)');
        onCallKitAccept!(callId);
      } else {
        RtcLogger.warning('CallKit: No callback set, using local acceptCall (NO socket event!)');
        acceptCall();
      }
    };

    // Decline call event
    _callKitEventHandler!.onDeclineCall = (callId) {
      RtcLogger.info('CallKit: User declined call via native UI');

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: Use callback if provided (for socket event emission)
      // ════════════════════════════════════════════════════════════════════
      if (onCallKitDecline != null) {
        RtcLogger.info('CallKit: Calling onCallKitDecline callback (emits socket event)');
        onCallKitDecline!(callId);
        return; // Callback handles everything
      }

      // Fallback to local handling if no callback
      RtcLogger.warning('CallKit: No callback set, using local reject/cancel (NO socket event!)');

      // CRITICAL: Check if this is incoming or outgoing call
      // - Incoming call: User declines = reject the call
      // - Outgoing call: User cancels = cancel the call
      final currentData = _stateManager.currentCall;
      if (currentData != null) {
        if (currentData.isIncoming) {
          // Incoming call - reject it
          RtcLogger.info('Declining incoming call');
          rejectCall();
        } else {
          // Outgoing call - cancel it
          RtcLogger.info('Cancelling outgoing call');
          endCall(CallEndReason.cancelled);
        }
      } else {
        // No active call data - just end the call
        RtcLogger.warning('No call data found, ending call');
        endCall(CallEndReason.ended);
      }
    };

    // End call event
    _callKitEventHandler!.onEndCall = (callId) {
      RtcLogger.info('CallKit: User ended call via native UI');
      // Call endCall() which handles the full end flow
      endCall(CallEndReason.ended);
    };

    // Timeout event
    _callKitEventHandler!.onTimeout = (callId) {
      RtcLogger.info('CallKit: Call timed out');
      // Let timeout manager handle this (already set up)
    };

    // Missed call callback
    _callKitEventHandler!.onMissedCallCallback = (callId) {
      RtcLogger.info('CallKit: User tapped callback on missed call');
      // Host app can listen to onMissedCall and handle callback
    };
  }

  /// Subscribe to ChatManager's event stream
  void _setupChatEventSubscription() {
    if (chatManager == null) return;

    RtcLogger.info('[RtcCallController] Subscribing to ChatManager events');

    chatManager!.events.listen((event) {
      switch (event.type) {
        case ChatEventType.messageReceived:
          if (event.message != null) {
            onChatMessageReceived?.call(event.message!);
          }
          break;
        case ChatEventType.sessionStarted:
          onChatSessionStarted?.call(event.sessionId, event.user);
          break;
        case ChatEventType.sessionEnded:
          onChatSessionEnded?.call(event.sessionId, event.metadata?['reason'] as String?);
          break;
        case ChatEventType.messageDelivered:
        case ChatEventType.messageRead:
          final msgId = event.metadata?['messageId'] as String? ??
              (event.metadata?['messageIds'] as List?)?.firstOrNull?.toString();
          if (msgId != null) {
            final status = event.type == ChatEventType.messageDelivered
                ? MessageStatus.delivered
                : MessageStatus.read;
            onChatMessageStatusChanged?.call(msgId, status);
          }
          break;
        case ChatEventType.messageFailed:
          if (event.message != null) {
            onChatMessageStatusChanged?.call(event.message!.messageId, MessageStatus.failed);
          }
          break;
        default:
          break;
      }
    });
  }

  /// Start an outgoing call
  Future<void> startOutgoingCall({
    required String callId,
    required CallUser localUser,
    required CallUser remoteUser,
    required CallType callType,
    String? roomId,
    String? sessionId,
    Map<String, dynamic>? metadata,
    bool skipCallKit = false, // Added parameter to skip CallKit UI
  }) async {
    _assertInitialized();

    // Input validation
    if (callId.trim().isEmpty) {
      throw CallError.invalidInput(
        message: 'callId cannot be empty',
        details: {'field': 'callId'},
      );
    }

    if (localUser.userId.trim().isEmpty) {
      throw CallError.invalidInput(
        message: 'localUser.userId cannot be empty',
        details: {'field': 'localUser.userId'},
      );
    }

    if (remoteUser.userId.trim().isEmpty) {
      throw CallError.invalidInput(
        message: 'remoteUser.userId cannot be empty',
        details: {'field': 'remoteUser.userId'},
      );
    }

    if (localUser.userId == remoteUser.userId) {
      throw CallError.invalidInput(
        message: 'Cannot call yourself: localUser and remoteUser must be different',
        details: {
          'localUserId': localUser.userId,
          'remoteUserId': remoteUser.userId,
        },
      );
    }

    try {
      RtcLogger.flowStep('OUTGOING_CALL', 'Starting outgoing call', {
        'callId': callId,
        'remoteUser': remoteUser.userName,
        'type': 'call',
        'skipCallKit': skipCallKit,
      });

      // ════════════════════════════════════════════════════════════════════════
      // OBSERVABILITY: Log call initiated + start performance tracking
      // ════════════════════════════════════════════════════════════════════════
      _callStartTime = DateTime.now();
      // Analytics: call initiated
      analyticsPlugin?.logCallStarted(
        callId: callId,
        callType: callType.name,
        callerId: localUser.userId,
        calleeId: remoteUser.userId,
        isOutgoing: true,
      );

      // Create call data
      final callData = CallData(
        callId: callId,
        caller: localUser,
        receiver: remoteUser,
        callType: callType,
        state: CallState.calling,
        startTime: DateTime.now(),
        isIncoming: false,
        roomId: roomId ?? _generateRoomId(callId),
        sessionId: sessionId,
        metadata: metadata,
      );

      // Initialize state
      final initializedCall = await _stateManager.initializeOutgoingCall(callData);
      if (initializedCall == null) {
        throw CallError.invalidState(
          message: 'Cannot start outgoing call: Already in active call',
        );
      }

      // // Show native CallKit UI if enabled and not skipped
      // if (_nativeCallKit != null && !skipCallKit) {
      //   await _nativeCallKit!.showOutgoingCall(initializedCall);
      // } else if (skipCallKit) {
      //   RtcLogger.info('Skipping CallKit UI as requested');
      // }

      // Start timeout timer
      _timeoutManager.startTimeout(
        callId: callId,
        onTimeout: _handleCallTimeout,
      );

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: DO NOT JOIN ZEGO ROOM HERE!
      // ════════════════════════════════════════════════════════════════════
      // For riko_talk flow:
      // 1. User initiates call → socket emits call request to server
      // 2. Remote user accepts → socket emits accept-request to server
      // 3. Server validates and emits sessionStarted with authoritative roomId
      // 4. ONLY THEN do we join ZEGO room (in _handleCallAnswerEvent)
      //
      // Joining ZEGO here would use a generated roomId (room_${callId})
      // which is different from server's roomId, causing users to be in
      // different rooms and unable to see/hear each other!
      // ════════════════════════════════════════════════════════════════════

      RtcLogger.success('Outgoing call started successfully - waiting for sessionStarted to join ZEGO room');
    } catch (e, stackTrace) {
      RtcLogger.error('Failed to start outgoing call', e, stackTrace);
      await _cleanupFailedCall(callId);
      onError?.call(CallError.unknown(
        message: 'Failed to start call',
        exception: e,
        stackTrace: stackTrace,
      ));
      rethrow;
    }
  }

  /// Receive an incoming call
  Future<void> receiveIncomingCall({
    required String callId,
    required CallUser remoteUser,
    required CallUser localUser,
    required CallType callType,
    String? roomId,
    String? sessionId,
    Map<String, dynamic>? metadata,
  }) async {
    _assertInitialized();

    // Input validation
    if (callId.trim().isEmpty) {
      throw CallError.invalidInput(
        message: 'callId cannot be empty',
        details: {'field': 'callId'},
      );
    }

    if (remoteUser.userId.trim().isEmpty) {
      throw CallError.invalidInput(
        message: 'remoteUser.userId cannot be empty',
        details: {'field': 'remoteUser.userId'},
      );
    }

    if (localUser.userId.trim().isEmpty) {
      throw CallError.invalidInput(
        message: 'localUser.userId cannot be empty',
        details: {'field': 'localUser.userId'},
      );
    }

    try {
      // CRITICAL VALIDATION: Prevent caller from receiving their own incoming call
      if (remoteUser.userId == localUser.userId) {
        RtcLogger.warning(
          '❌ BLOCKED: Current user is the caller - ignoring incoming call',
          {
            'callerId': remoteUser.userId,
            'currentUserId': localUser.userId,
            'callId': callId,
          }
        );
        return; // Do NOT show incoming call UI
      }

      RtcLogger.flowStep('INCOMING_CALL', 'Receiving incoming call', {
        'callId': callId,
        'remoteUser': remoteUser.userName,
        'type': callType.name,
      });

      // ════════════════════════════════════════════════════════════════════════
      // OBSERVABILITY: Log call received + start performance tracking
      // ════════════════════════════════════════════════════════════════════════
      _callStartTime = DateTime.now();
      // Analytics: call received
      analyticsPlugin?.logCallStarted(
        callId: callId,
        callType: callType.name,
        callerId: remoteUser.userId,
        calleeId: localUser.userId,
        isOutgoing: false,
      );

      // Create call data
      final callData = CallData(
        callId: callId,
        caller: remoteUser,
        receiver: localUser,
        callType: callType,
        state: CallState.ringing,
        startTime: DateTime.now(),
        isIncoming: true,
        roomId: roomId ?? _generateRoomId(callId),
        sessionId: sessionId,
        metadata: metadata,
      );

      // Initialize state
      final initializedCall = await _stateManager.initializeIncomingCall(callData);
      if (initializedCall == null) {
        RtcLogger.warning('Cannot accept incoming call: Already in active call');
        // Could notify caller that user is busy
        return;
      }

      // Show native CallKit UI if enabled AND useCallKit flag is true
      if (useCallKit && _nativeCallKit != null) {
        RtcLogger.info('Showing native CallKit incoming call UI');
        await _nativeCallKit!.showIncomingCall(initializedCall);
      } else {
        RtcLogger.info('CallKit disabled - app will handle incoming call UI via onIncomingCall callback');
      }

      // Start timeout timer for incoming call
      _timeoutManager.startTimeout(
        callId: callId,
        onTimeout: (cId) {
          _handleIncomingCallTimeout(cId);
        },
      );

      // Notify host app - ALWAYS called regardless of useCallKit flag
      // This allows app to show custom UI when CallKit is disabled
      onIncomingCall?.call(initializedCall);

      RtcLogger.success('Incoming call received');
    } catch (e, stackTrace) {
      RtcLogger.error('Failed to receive incoming call', e, stackTrace);
      await _cleanupFailedCall(callId);
      onError?.call(CallError.unknown(
        message: 'Failed to receive call',
        exception: e,
        stackTrace: stackTrace,
      ));
      rethrow;
    }
  }

  /// Accept an incoming call
  Future<void> acceptCall() async {
    _assertInitialized();

    final currentCall = _stateManager.currentCall;

    if (currentCall == null) {
      RtcLogger.error('No active call to accept');
      throw CallError.invalidState(message: 'No active call to accept');
    }

    if (!currentCall.isIncoming) {
      RtcLogger.error('Cannot accept: Not an incoming call', {'isIncoming': currentCall.isIncoming});
      throw CallError.invalidState(message: 'Can only accept incoming calls');
    }

    if (currentCall.state != CallState.ringing) {
      // If call is already connected, just return silently - this can happen when:
      // 1. CallKit fires accept again during network reconnection
      // 2. User taps accept multiple times quickly
      // 3. Network transition causes duplicate events
      if (currentCall.state == CallState.connected || currentCall.state == CallState.connecting) {
        RtcLogger.warning('Call already accepted/connected, ignoring duplicate accept', {'state': currentCall.state.name});
        return; // Silently return - call is already in progress
      }

      RtcLogger.error('Cannot accept: Call not in ringing state', {'state': currentCall.state.name});
      throw CallError.invalidState(
        message: 'Call must be in ringing state to accept',
      );
    }

    try {
      RtcLogger.flowStep('ACCEPT_CALL', 'Accepting call');

      // ════════════════════════════════════════════════════════════════════════
      // OBSERVABILITY: Log call accepted + record performance
      // ════════════════════════════════════════════════════════════════════════
      _callConnectedTime = DateTime.now();
      analyticsPlugin?.trackFunnelStep(
        callId: currentCall.callId,
        stepName: 'call_accepted',
        metadata: {'timeToAcceptMs': _getTimeToAcceptMs()},
      );

      // Cancel timeout
      _timeoutManager.cancelTimeout();

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: DO NOT JOIN ZEGO ROOM HERE!
      // ════════════════════════════════════════════════════════════════════
      // For riko_talk flow:
      // 1. User accepts call → socket emits accept-request to server
      // 2. Server validates and emits sessionStarted with authoritative roomId
      // 3. ONLY THEN do we join ZEGO room (in _handleCallAnswerEvent)
      //
      // The roomId stored in currentCall might be a placeholder or wrong value.
      // The server's roomId in sessionStarted is the SINGLE SOURCE OF TRUTH.
      // Joining ZEGO here would cause users to be in different rooms!
      // ════════════════════════════════════════════════════════════════════

      // Just notify that call was accepted - actual ZEGO join happens in sessionStarted
      onCallAccepted?.call(currentCall);

      RtcLogger.success('Call accepted - waiting for sessionStarted to join ZEGO room');
    } catch (e, stackTrace) {
      RtcLogger.error('Failed to accept call', e, stackTrace);
      await endCall(CallEndReason.failed);
      onError?.call(CallError.unknown(
        message: 'Failed to accept call',
        exception: e,
        stackTrace: stackTrace,
      ));
      rethrow;
    }
  }

  /// Reject an incoming call
  Future<void> rejectCall() async {
    _assertInitialized();

    final currentCall = _stateManager.currentCall;
    if (currentCall == null) {
      throw CallError.invalidState(message: 'No active call to reject');
    }

    if (!currentCall.isIncoming) {
      throw CallError.invalidState(message: 'Can only reject incoming calls');
    }

    try {
      RtcLogger.flowStep('REJECT_CALL', 'Rejecting call');

      // ════════════════════════════════════════════════════════════════════════
      // OBSERVABILITY: Log call rejected
      // ════════════════════════════════════════════════════════════════════════
      // Analytics tracking via plugin (if configured)

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: Emit reject signaling event FIRST (before cleanup)
      // ════════════════════════════════════════════════════════════════════
      // This notifies the remote peer that the call was rejected
      if (_signalingHandler != null) {
        try {
          RtcLogger.info('📤 Emitting reject-request signaling event to remote peer');
          await _signalingHandler!.sendCallReject(
            callId: currentCall.callId,
            toUserId: currentCall.remoteUser.userId,
            metadata: {
              'reason': 'rejected',
              'rejectedBy': currentCall.localUser.userId,
            },
          );
          RtcLogger.success('✅ Reject-request event emitted successfully');
        } catch (e) {
          RtcLogger.error('Failed to emit reject-request event (continuing with cleanup)', e);
          // Continue with cleanup even if signaling fails
        }
      }

      // Cancel timeout
      _timeoutManager.cancelTimeout();

      // Logout from ZEGO room (in case we joined)
      await _zegoService.logoutRoom();

      // End native CallKit if enabled AND useCallKit flag is true
      if (useCallKit && _nativeCallKit != null) {
        await _nativeCallKit!.endCall(currentCall.callId);
      }

      // End call
      await _stateManager.endCall(CallEndReason.rejected);

      // Notify host app
      onCallRejected?.call(currentCall, CallEndReason.rejected);

      RtcLogger.success('Call rejected');
    } catch (e) {
      RtcLogger.error('Failed to reject call', e);
      onError?.call(CallError.unknown(
        message: 'Failed to reject call',
        exception: e,
      ));
    }
  }

  /// End the current call
  ///
  /// [emitSignalingEvent] - If false, will NOT emit session-end to remote peer.
  /// Use false when ending due to receiving remote's session-end event.
  Future<void> endCall(CallEndReason reason, {bool emitSignalingEvent = true}) async {
    _assertInitialized();

    final currentCall = _stateManager.currentCall;
    if (currentCall == null) {
      // This is expected if remote peer already ended the call and cleared our state
      // CallKit's delayed ACTION_CALL_ENDED can trigger after the call is already ended
      RtcLogger.info('⏭️ No active call to end (likely already ended by remote peer or timeout)');

      // ════════════════════════════════════════════════════════════════════════
      // CRITICAL: Still try to end CallKit even if no active call in state
      // This handles cases where CallKit was shown but call state was cleared
      // (e.g., chat sessions, race conditions, etc.)
      // ════════════════════════════════════════════════════════════════════════
      if (useCallKit && _nativeCallKit != null) {
        RtcLogger.info('🧹 Ending all CallKit calls (cleanup even without active call state)');
        await _nativeCallKit!.endAllCalls();
      }
      return;
    }

    try {
      RtcLogger.flowStep('END_CALL', 'Ending call', {
        'reason': reason.name,
        'emitSignalingEvent': emitSignalingEvent,
        'sessionId': currentCall.sessionId ?? 'null',
      });
      RtcLogger.info('State transition');

      // ════════════════════════════════════════════════════════════════════════
      // OBSERVABILITY: Log call ended + report performance metrics
      // ════════════════════════════════════════════════════════════════════════
      // Analytics: call ended
      final totalDuration = _getTotalDurationMs();
      final connectedDuration = 0;

      // Map CallEndReason to analytics reason string
      final endReasonStr = switch (reason) {
        CallEndReason.ended => 'user_ended',
        CallEndReason.remoteEnded => 'remote_ended',
        CallEndReason.rejected => 'rejected',
        CallEndReason.cancelled => 'cancelled',
        CallEndReason.busy => 'busy',
        CallEndReason.timeout => 'timeout',
        CallEndReason.missed => 'missed',
        CallEndReason.failed => 'failed',
        CallEndReason.networkLost => 'network_lost',
        CallEndReason.unknown => 'unknown',
      };

      await analyticsPlugin?.logCallEnded(
        callId: currentCall.callId,
        callType: currentCall.callType.name,
        endReason: endReasonStr,
        durationSeconds: connectedDuration ~/ 1000,
        totalDurationMs: totalDuration,
      );
      crashReportingPlugin?.setCustomKey('call_state', 'idle');

      // AUDIO CALL LOGGING: Log audio call end with final state snapshot
      if (currentCall.callType.isAudio) {
        RtcLogger.audioCall(
          userId: currentCall.localUser.userId,
          peerId: currentCall.remoteUser.userId,
          roomId: currentCall.roomId,
          streamId: null,
          callType: 'audio',
          step: 'AUDIO_CALL_END',
          detail: 'endReason=${reason.name} duration=${totalDuration}ms',
        );

        // Record audio signaling trace for call end
      }

      // ════════════════════════════════════════════════════════════════════
      // CRITICAL: Emit signaling event FIRST (before cleaning up)
      // ════════════════════════════════════════════════════════════════════
      // This notifies the remote peer that the call is ending
      // Only emit if:
      // 1. emitSignalingEvent is true (not responding to remote's end event)
      // 2. Signaling is enabled and we have the necessary info
      if (emitSignalingEvent && _signalingHandler != null) {
        // Check if session has actually started (sessionId is set)
        if (currentCall.sessionId != null) {
          // Session is active - send session-end
          try {
            RtcLogger.info('📤 Emitting session-end signaling event to remote peer');
            await _signalingHandler!.sendCallEnd(
              callId: currentCall.callId,
              toUserId: currentCall.remoteUser.userId,
              metadata: {
                'reason': reason.name,
                'sessionId': currentCall.sessionId,  // SocketMapper extracts this
              },
            );
            RtcLogger.success('✅ Session-end event emitted successfully');
          } catch (e) {
            RtcLogger.error('Failed to emit session-end event (continuing with cleanup)', e);
            // Continue with cleanup even if signaling fails
          }
        } else {
          // Session hasn't started yet (sessionStarted not received)
          // Send reject or cancel instead based on whether this was incoming or outgoing
          try {
            if (currentCall.isIncoming) {
              RtcLogger.info('📤 Session not started yet - sending reject-request instead');
              await _signalingHandler!.sendCallReject(
                callId: currentCall.callId,
                toUserId: currentCall.remoteUser.userId,
                metadata: {
                  'reason': reason.name,
                  'rejectedBy': currentCall.localUser.userId,
                },
              );
              RtcLogger.success('✅ Reject-request event emitted successfully');
            } else {
              RtcLogger.info('📤 Session not started yet - sending cancel-request instead');
              await _signalingHandler!.sendCallCancel(
                callId: currentCall.callId,
                toUserId: currentCall.remoteUser.userId,
                metadata: {
                  'reason': reason.name,
                },
              );
              RtcLogger.success('✅ Cancel-request event emitted successfully');
            }
          } catch (e) {
            RtcLogger.error('Failed to emit reject/cancel event (continuing with cleanup)', e);
            // Continue with cleanup even if signaling fails
          }
        }
      } else if (!emitSignalingEvent) {
        RtcLogger.info('⏭️ Skipping signaling emission (responding to remote end event)');
      }

      // Cancel timeout
      _timeoutManager.cancelTimeout();

      // Stop duration timer
      _stopDurationTimer();

      // Logout from ZEGO room
      await _zegoService.logoutRoom();

      // ════════════════════════════════════════════════════════════════════════
      // HARDENING: Reset iOS audio session after call ends
      // ════════════════════════════════════════════════════════════════════════
      if (Platform.isIOS) {
        RtcLogger.info('Call info');
        // iOS audio session reset (handled by platform)
      }

      // End native CallKit if enabled AND useCallKit flag is true
      if (useCallKit && _nativeCallKit != null) {
        await _nativeCallKit!.endCall(currentCall.callId);
      }

      // End call state
      await _stateManager.endCall(reason);

      // Notify host app
      onCallEnded?.call(currentCall, reason);

      RtcLogger.success('Call operation completed');
      RtcLogger.success('Call ended');
    } catch (e) {
      RtcLogger.error('Failed to end call', e);
      onError?.call(CallError.unknown(
        message: 'Failed to end call',
        exception: e,
      ));
    }
  }

  /// Toggle microphone mute
  Future<void> toggleMute() async {
    _assertInitialized();
    final currentCall = _stateManager.currentCall;
    final currentStreamId = _zegoService.currentStreamId;

    // ════════════════════════════════════════════════════════════════════
    // AUDIO DEBUG: Log toggle mute
    // ════════════════════════════════════════════════════════════════════
    if (currentCall != null && currentCall.callType.isAudio) {
      RtcLogger.audioTrackState(
        trackId: 'mic_${currentCall.localUser.userId}',
        enabled: true,
        muted: !_zegoService.isMicrophoneMuted,  // toggling state
        streamId: currentStreamId,
        userId: currentCall.localUser.userId,
      );
    }

    await _zegoService.toggleMicrophone();
  }

  /// Toggle camera on/off
  Future<void> toggleCamera() async {
    _assertInitialized();
    await _zegoService.toggleCamera();
  }

  /// Switch between front and back camera
  Future<void> switchCamera() async {
    _assertInitialized();
    await _zegoService.switchCamera();
  }

  /// Toggle speaker on/off
  Future<void> switchSpeaker() async {
    _assertInitialized();
    final currentCall = _stateManager.currentCall;
    final currentStreamId = _zegoService.currentStreamId;

    // ════════════════════════════════════════════════════════════════════
    // AUDIO DEBUG: Log toggle speaker
    // ════════════════════════════════════════════════════════════════════
    if (currentCall != null && currentCall.callType.isAudio) {
      RtcLogger.audioRouting(
        fromRoute: _zegoService.isSpeakerEnabled ? 'earpiece' : 'speaker',
        toRoute: _zegoService.isSpeakerEnabled ? 'speaker' : 'earpiece',
        streamId: currentStreamId,
      );
    }

    await _zegoService.toggleSpeaker();
  }

  /// Mark call as connected in native CallKit
  /// This stops the ringtone and transitions to "in call" state
  Future<void> markCallConnected(String callId) async {
    if (useCallKit && _nativeCallKit != null) {
      await _nativeCallKit!.markCallConnected(callId);
    }
  }

  /// Handle state changes
  void _handleStateChange(CallData callData) {
    onCallStateChanged?.call(callData);

    // Auto-transition to connected when both users joined
    if (callData.state == CallState.connecting) {
      // Automatically move to connected after a short delay
      // This gives time for streams to stabilize
      Future.delayed(const Duration(milliseconds: 500), () {
        if (_stateManager.currentCall?.state == CallState.connecting) {
          _stateManager.transitionToConnected();
          _startDurationTimer();
        }
      });
    }
  }

  /// Handle remote user leaving
  void _handleRemoteUserLeft() {
    endCall(CallEndReason.remoteEnded);
  }

  /// Handle call timeout
  void _handleCallTimeout(String callId) async {
    RtcLogger.warning('Call timeout', callId);

    // Cleanup ZEGO resources
    await _zegoService.logoutRoom();

    _stateManager.endCall(CallEndReason.timeout);

    final currentCall = _stateManager.currentCall;
    if (currentCall != null) {
      onCallTimeout?.call(currentCall);
    }
  }

  /// Handle incoming call timeout (missed call)
  void _handleIncomingCallTimeout(String callId) async {
    RtcLogger.warning('Incoming call timeout (missed)', callId);

    // Cleanup ZEGO resources (in case we joined)
    await _zegoService.logoutRoom();

    _stateManager.endCall(CallEndReason.missed);

    final currentCall = _stateManager.currentCall;
    if (currentCall != null) {
      onMissedCall?.call(currentCall);
    }
  }

  /// Handle network connectivity change
  void _handleNetworkChange(bool isConnected) {
    if (!isConnected) {
      RtcLogger.warning('Network disconnected');
      RtcLogger.info('Network change');
      if (_stateManager.hasActiveCall) {
        _stateManager.transitionToReconnecting();
        onReconnecting?.call();

        // OBSERVABILITY: Log reconnecting state
        // Analytics tracking via plugin (if configured)
      }
    } else {
      RtcLogger.info('Network reconnected');
      RtcLogger.info('Network change');

      // ════════════════════════════════════════════════════════════════════════
      // HARDENING: Re-negotiate streams after network reconnect
      // This fixes the "silent call" bug where audio doesn't work after reconnect
      // ════════════════════════════════════════════════════════════════════════
      if (_stateManager.hasActiveCall) {
        _reNegotiateStreamsAfterReconnect();
      }
    }
  }

  /// Re-negotiate streams after network reconnect
  ///
  /// CRITICAL: This fixes the "silent call" bug where audio stops working
  /// after a network reconnection. We need to stop and restart the streams
  /// to re-establish the audio/video paths.
  Future<void> _reNegotiateStreamsAfterReconnect() async {
    try {
      RtcLogger.info('Call info');

      // Wait a bit for ZEGO to stabilize after reconnect
      await Future.delayed(const Duration(milliseconds: 500));

      final success = await _zegoService.reNegotiateStreams();

      if (success) {
        RtcLogger.success('Call operation completed');
        _stateManager.transitionToConnected();
        onReconnected?.call();

        // ════════════════════════════════════════════════════════════════════════
        // OBSERVABILITY: Log reconnected + audio recovery
        // ════════════════════════════════════════════════════════════════════════
        RtcLogger.success('Stream re-negotiation successful');
        onReconnected?.call();
      } else {
        RtcLogger.warning('Stream re-negotiation returned false');
      }
    } catch (e, stackTrace) {
      RtcLogger.error('Stream re-negotiation failed', e, stackTrace);

      // Record error via crash reporting plugin if configured
      crashReportingPlugin?.recordCallFlowError(
        'reconnecting',
        'Stream re-negotiation failed',
        stackTrace,
      );

      onError?.call(CallError.unknown(
        message: 'Failed to re-establish audio after reconnect',
        exception: e,
        stackTrace: stackTrace,
      ));
    }
  }

  /// Start duration timer
  void _startDurationTimer() {
    _stopDurationTimer();

    int seconds = 0;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      seconds++;
      _stateManager.updateDuration(seconds);
    });
  }

  /// Stop duration timer
  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  /// Cleanup failed call
  Future<void> _cleanupFailedCall(String callId) async {
    _timeoutManager.cancelTimeout();
    await _zegoService.logoutRoom();
    _stateManager.clearCall();
  }

  /// Generate room ID from call ID
  String _generateRoomId(String callId) {
    return 'room_$callId';
  }


  /// Generate stream ID
  ///
  /// Format: Stream_{roomId}_{userId}_stream
  String _generateStreamId(String roomId, String userId) {
    return 'Stream_${roomId}_${userId}_stream';
  }

  /// Check if SDP is audio-only (no video tracks)
  bool _isAudioOnlySdp(Map<String, dynamic>? metadata) {
    if (metadata == null) return false;
    // Check for presence of audio/video indicators in metadata
    final hasAudio = metadata.containsKey('audioSdp') ||
                     metadata.containsKey('hasAudio') ||
                     metadata['type'] == 'audio';
    final hasVideo = metadata.containsKey('videoSdp') ||
                     metadata.containsKey('hasVideo') ||
                     metadata['type'] == 'video';
    return hasAudio && !hasVideo;
  }

  /// Assert that controller is initialized
  void _assertInitialized() {
    if (!_isInitialized) {
      throw CallError.engineNotInitialized(
        message: 'RtcCallController not initialized. Call init() first.',
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // PERFORMANCE TRACKING HELPERS
  // ══════════════════════════════════════════════════════════════════════

  /// Get time from call start to accept in milliseconds
  int _getTimeToAcceptMs() {
    if (_callStartTime == null || _callConnectedTime == null) return 0;
    return _callConnectedTime!.difference(_callStartTime!).inMilliseconds;
  }

  /// Get time from call start to connected in milliseconds
  int _getTimeToConnectMs() {
    if (_callStartTime == null || _callConnectedTime == null) return 0;
    return _callConnectedTime!.difference(_callStartTime!).inMilliseconds;
  }

  /// Get total call duration in milliseconds
  int _getTotalDurationMs() {
    if (_callStartTime == null) return 0;
    return DateTime.now().difference(_callStartTime!).inMilliseconds;
  }

  // ══════════════════════════════════════════════════════════════════════
  // SIGNALING SUPPORT
  // For socket-based call signaling
  // ══════════════════════════════════════════════════════════════════════

  /// Receive a signaling event from your socket/signaling channel
  ///
  /// Call this when you receive a signaling message from the remote peer.
  /// The controller will process the event and update the call state accordingly.
  ///
  /// Example:
  /// ```dart
  /// socket.on('call_event', (data) {
  ///   final event = RtcSignalingEvent.fromJson(data);
  ///   controller.receiveSignalingEvent(event);
  /// });
  /// ```
  Future<void> receiveSignalingEvent(RtcSignalingEvent event) async {
    if (!useSignaling) {
      RtcLogger.warning(
          'Received signaling event but useSignaling is false. Ignoring.');
      return;
    }

    RtcLogger.info(
        'Received signaling event: ${event.type.name} for call ${event.callId}');

    // AUDIO CALL LOGGING: Log incoming signaling for audio calls
    final isAudioCall = currentCall?.callType.isAudio ?? false;
    if (isAudioCall) {
      final isAudioSdp = _isAudioOnlySdp(event.metadata);
      RtcLogger.audioSignaling(
        event: 'SIGNALING_RECV',
        direction: 'recv',
        metadata: {
          'eventType': event.type.name,
          'callId': event.callId,
          'fromUserId': event.fromUserId,
          'toUserId': event.toUserId,
          'isAudioSdp': isAudioSdp,
          'metadataKeys': event.metadata?.keys.toList() ?? [],
        },
      );
    }

    try {
      switch (event.type) {
        case RtcSignalingEventType.callOffer:
          await _handleCallOfferEvent(event);
          break;

        case RtcSignalingEventType.callAnswer:
          await _handleCallAnswerEvent(event);
          break;

        case RtcSignalingEventType.callReject:
          await _handleCallRejectEvent(event);
          break;

        case RtcSignalingEventType.callCancel:
          await _handleCallCancelEvent(event);
          break;

        case RtcSignalingEventType.callEnd:
          await _handleCallEndEvent(event);
          break;

        case RtcSignalingEventType.callTimeout:
          await _handleCallTimeoutEvent(event);
          break;

        case RtcSignalingEventType.callBusy:
          await _handleCallBusyEvent(event);
          break;

        case RtcSignalingEventType.iceCandidate:
          // Not used with ZEGO
          RtcLogger.info('ICE candidate event ignored (not needed for ZEGO)');
          break;
      }
    } catch (e, stack) {
      RtcLogger.error('Failed to process signaling event', e, stack);
      onError?.call(CallError.unknown(
        message: 'Failed to process signaling event: ${event.type.name}',
        exception: e,
        stackTrace: stack,
      ));
    }
  }

  /// Handle incoming call offer (someone calling us)
  Future<void> _handleCallOfferEvent(RtcSignalingEvent event) async {
    RtcLogger.flowStep('CALL_OFFER', 'Processing call offer from socket');

    // Extract user info from metadata
    final remoteUserData = event.metadata?['caller'] as Map<String, dynamic>?;
    final localUserData = event.metadata?['callee'] as Map<String, dynamic>?;

    if (remoteUserData == null || localUserData == null) {
      RtcLogger.error('Call offer missing user data in metadata');
      return;
    }

    final remoteUser = CallUser(
      userId: remoteUserData['userId'] as String,
      userName: remoteUserData['userName'] as String,
      avatarUrl: remoteUserData['avatarUrl'] as String?,
    );

    final localUser = CallUser(
      userId: localUserData['userId'] as String,
      userName: localUserData['userName'] as String,
      avatarUrl: localUserData['avatarUrl'] as String?,
    );

    final callType = event.callType == 'video' ? CallType.video : CallType.audio;

    // Receive the incoming call (shows UI)
    await receiveIncomingCall(
      callId: event.callId,
      remoteUser: remoteUser,
      localUser: localUser,
      callType: callType,
      roomId: event.roomId,
      metadata: event.metadata,
    );
  }

  /// Handle call answer (callee accepted our call)
  ///
  /// CRITICAL: This also handles sessionStarted events from the server
  /// When isSessionStarted=true in metadata, this means backend has confirmed
  /// the session and we should NOW join the ZEGO room
  Future<void> _handleCallAnswerEvent(RtcSignalingEvent event) async {
    RtcLogger.flowStep('CALL_ANSWER', 'Processing call answer from socket');

    final currentCall = _stateManager.currentCall;

    // ════════════════════════════════════════════════════════════════════
    // CRITICAL: Check if this is a sessionStarted event from server
    // ════════════════════════════════════════════════════════════════════
    final isSessionStarted = event.metadata?['isSessionStarted'] == true;

    // For sessionStarted events, be more lenient with callId matching
    // The server generates a new sessionId that may differ from our callId
    if (currentCall == null) {
      RtcLogger.warning('Received answer event but no current call in progress');
      return;
    }

    if (!isSessionStarted && currentCall.callId != event.callId) {
      // For regular answer events (not sessionStarted), require exact match
      RtcLogger.warning('Received answer for unknown call: ${event.callId}');
      return;
    }

    if (isSessionStarted && currentCall.callId != event.callId) {
      // For sessionStarted, accept it with a warning
      RtcLogger.info('📝 SessionStarted callId mismatch (expected, server generates new ID)');
      RtcLogger.info('   Client callId: ${currentCall.callId}');
      RtcLogger.info('   Server sessionId: ${event.callId}');
      RtcLogger.info('   ✅ Accepting sessionStarted event for current call');
    }

    if (isSessionStarted) {
      RtcLogger.info('🎉 SESSION STARTED - Server confirmed, joining ZEGO room now');
      RtcLogger.info('State transition');

      // Extract sessionId, roomId, and token from event (server provides the authoritative values)
      final sessionId = event.metadata?['sessionId'] as String? ?? event.callId;
      final roomId = event.roomId ?? event.metadata?['roomID'] as String? ?? event.metadata?['roomId'] as String?;
      final token = event.metadata?['token'] as String?;

      // CRITICAL: Cancel timeout timer - session has started successfully
      // Without this, the 30-second timeout from call initiation will fire and kill the active call
      _timeoutManager.cancelTimeout();
      RtcLogger.info('✅ Cancelled call timeout - session is now active');

      // ════════════════════════════════════════════════════════════════════════
      // OBSERVABILITY: Log session started
      // ════════════════════════════════════════════════════════════════════════
      analyticsPlugin?.trackFunnelStep(
        callId: currentCall.callId,
        stepName: 'session_started',
        metadata: {'sessionId': sessionId},
      );

      // Set crash reporting context for this session
      crashReportingPlugin?.setUserId(currentCall.localUser.userId);
      crashReportingPlugin?.setCustomKey('sessionId', sessionId);
      crashReportingPlugin?.setCustomKey('callId', currentCall.callId);
      crashReportingPlugin?.setCustomKey('callType', currentCall.callType.name);

      if (roomId == null) {
        RtcLogger.error('❌ No roomId in sessionStarted event, cannot join ZEGO room');
        return;
      }

      // ════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Initialize AudioDebugState and log audio call start
      // ════════════════════════════════════════════════════════════════════
      if (currentCall.callType.isAudio) {
        // Reset and initialize audio debug state

        // Log initial audio call start with all IDs
        RtcLogger.audioCall(
          userId: currentCall.localUser.userId,
          peerId: currentCall.remoteUser.userId,
          roomId: roomId,
          streamId: _generateStreamId(roomId, currentCall.localUser.userId),
          callType: 'audio',
          step: 'AUDIO_CALL_STARTED',
          detail: 'sessionId=$sessionId',
        );
      }

      // CRITICAL: Cancel timeout timer - session has started successfully
      // Without this, the 30-second timeout from call initiation will fire and kill the active call
      _timeoutManager.cancelTimeout();
      RtcLogger.info('✅ Cancelled call timeout - session is now active');

      // ════════════════════════════════════════════════════════════════════════
      // OBSERVABILITY: Log session started
      // ════════════════════════════════════════════════════════════════════════
      analyticsPlugin?.trackFunnelStep(
        callId: currentCall.callId,
        stepName: 'session_started',
        metadata: {'sessionId': sessionId},
      );

      // Set crash reporting context for this session
      crashReportingPlugin?.setUserId(currentCall.localUser.userId);
      crashReportingPlugin?.setCustomKey('sessionId', sessionId);
      crashReportingPlugin?.setCustomKey('callId', currentCall.callId);
      crashReportingPlugin?.setCustomKey('callType', currentCall.callType.name);

      try {
        // CRITICAL: Update the call with sessionId and roomId from backend
        // This ensures sessionId is always available for session-end events
        _stateManager.updateSessionInfo(
          sessionId: sessionId,
          roomId: roomId,
        );

        // Transition to connecting
        await _stateManager.transitionToConnecting();

        // CRITICAL: Only join ZEGO room for audio/video calls, NOT for chat
        if (currentCall.callType.requiresMedia) {
          // ══════════════════════════════════════════════════════════════════════
          // HARDENING: iOS audio session configuration
          // ══════════════════════════════════════════════════════════════════════
          // Note: iOS audio session is typically configured by the ZEGO SDK
          // If custom audio session management is needed, the host app should
          // handle it before calling startOutgoingCall/receiveIncomingCall
          if (Platform.isIOS) {
            RtcLogger.info('📱 iOS detected - ZEGO SDK will handle audio session');
          }

          // JOIN THE ZEGO ROOM NOW (audio/video calls only)
          RtcLogger.info('╔════════════════════════════════════════════════════════════╗');
          RtcLogger.info('║  🔗 ZEGO ROOM LOGIN - SESSION STARTED                     ║');
          RtcLogger.info('╚════════════════════════════════════════════════════════════╝');
          RtcLogger.info('  👤 User:      ${currentCall.localUser.userName} (${currentCall.localUser.userId})');
          RtcLogger.info('  🏠 Room ID:   $roomId');
          RtcLogger.info('  📱 Call Type: ${currentCall.callType.name}');
          RtcLogger.info('  🎯 Is Incoming: ${currentCall.isIncoming}');
          RtcLogger.info('  🎙️ isAudio: ${currentCall.callType.isAudio}  isVideo: ${currentCall.callType.isVideo}');
          RtcLogger.info('  🔊 requiresMedia: ${currentCall.callType.requiresMedia}');
          RtcLogger.info('════════════════════════════════════════════════════════════');

          // AUDIO CALL LOGGING: Log login attempt for audio calls
          if (currentCall.callType.isAudio) {
            RtcLogger.audioCall(
              userId: currentCall.localUser.userId,
              peerId: currentCall.remoteUser.userId,
              roomId: roomId,
              streamId: null,
              callType: 'audio',
              step: 'AUDIO_LOGIN_ATTEMPT',
              detail: 'tokenPresent=${token != null}',
            );
          }

          await _zegoService.loginRoom(
            roomId: roomId,
            userId: currentCall.localUser.userId,
            userName: currentCall.localUser.userName,
            callType: currentCall.callType,
            token: token,
          );

          // AUDIO CALL LOGGING: Log login success for audio calls
          if (currentCall.callType.isAudio) {
            RtcLogger.audioCall(
              userId: currentCall.localUser.userId,
              peerId: currentCall.remoteUser.userId,
              roomId: roomId,
              streamId: null,
              callType: 'audio',
              step: 'AUDIO_LOGIN_SUCCESS',
              detail: null,
            );
          }

          // ════════════════════════════════════════════════════════════════════
          // CRITICAL: Check if call was ended during room login (race condition)
          // During the 500ms stabilization wait, sessionEnded might have arrived
          // ════════════════════════════════════════════════════════════════════
          if (_stateManager.currentCall == null || _stateManager.currentCall!.hasEnded) {
            RtcLogger.warning('⚠️ Call was ended during ZEGO room login, aborting stream publish');
            return;
          }

          // Start publishing stream
          final streamId = _generateStreamId(roomId, currentCall.localUser.userId);

          // ════════════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log publish attempt for audio calls
          // ════════════════════════════════════════════════════════════════════
          if (currentCall.callType.isAudio) {
            RtcLogger.audioPublish(
              streamId: streamId,
              success: true,
              userId: currentCall.localUser.userId,
              roomId: roomId,
            );
          }

          RtcLogger.info('📤 Starting to publish stream: $streamId');
          await _zegoService.startPublishing(
            streamId: streamId,
            callType: currentCall.callType,
          );

          // ════════════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log publish success for audio calls
          // ════════════════════════════════════════════════════════════════════
          if (currentCall.callType.isAudio) {
            RtcLogger.audioPublish(
              streamId: streamId,
              success: true,
              userId: currentCall.localUser.userId,
              roomId: roomId,
            );
          }

          // Record audio signaling trace

          RtcLogger.success('✅ Successfully joined ZEGO room: $roomId and started media stream');

          // ════════════════════════════════════════════════════════════════════
          // CRITICAL FIX: Proactively play remote stream after publishing
          // The onStreamAdded callback may not fire due to event channel issues,
          // and _scheduleRemoteStreamPlay may fail silently. So after publishing
          // our own stream, we proactively try to play the remote stream with
          // a small delay to give the remote party time to publish theirs.
          // ════════════════════════════════════════════════════════════════════
          if (currentCall.callType.isAudio) {
            final remoteStreamId = _generateStreamId(roomId, currentCall.remoteUser.userId);
            RtcLogger.info('🎯 Proactively playing remote stream after publish: $remoteStreamId');

            // Small delay to let remote party start publishing first
            Future.delayed(const Duration(milliseconds: 500), () async {
              try {
                if (_stateManager.currentCall == null || _stateManager.currentCall!.hasEnded) {
                  RtcLogger.info('Call ended before proactive play - skipping');
                  return;
                }
                RtcLogger.info('🔊 Attempting proactive remote stream play: $remoteStreamId');
                await _zegoService.playStream(streamId: remoteStreamId);
                RtcLogger.success('✅ Proactive remote stream play SUCCESS: $remoteStreamId');

                // Also trigger the fallback mechanism in parallel
                _zegoService.scheduleFallbackStreamPlay(currentCall.remoteUser.userId);
              } catch (e) {
                RtcLogger.warning('⚠️ Proactive remote stream play failed: $e (will rely on fallback)');
              }
            });
          }

          // ════════════════════════════════════════════════════════════════════════
          // OBSERVABILITY: Log call connected + record performance
          // ════════════════════════════════════════════════════════════════════════
          _callConnectedTime = DateTime.now();
          final timeToConnect = _getTimeToConnectMs();
          await analyticsPlugin?.logCallConnected(
            callId: currentCall.callId,
            callType: currentCall.callType.name,
            timeToConnectMs: timeToConnect,
          );
          crashReportingPlugin?.setCustomKey('call_state', 'connected');
        } else {
          // Chat session - no media, just session tracking
          RtcLogger.info('💬 CHAT SESSION STARTED - Skipping ZEGO room (text chat only)');
          RtcLogger.info('  👤 User:      ${currentCall.localUser.userName}');
          RtcLogger.info('  📱 Type:      Chat (no media)');
          RtcLogger.info('  📋 Session ID: $sessionId');

          // Still mark as connected for chat sessions
          _callConnectedTime = DateTime.now();
          crashReportingPlugin?.setCustomKey('call_state', 'chat_connected');
        }

        // Transition to connected
        await _stateManager.transitionToConnected();

        // Mark call as connected in native CallKit if enabled
        if (useCallKit && _nativeCallKit != null) {
          await _nativeCallKit!.markCallConnected(currentCall.callId);
        }

        // Start call duration timer
        _startDurationTimer();
      } catch (zegoError, zegoStackTrace) {
        // AUDIO CALL LOGGING: Log login failure for audio calls
        if (currentCall.callType.isAudio) {
          RtcLogger.audioCall(
            userId: currentCall.localUser.userId,
            peerId: currentCall.remoteUser.userId,
            roomId: roomId,
            streamId: null,
            callType: 'audio',
            step: 'AUDIO_LOGIN_FAILED',
            detail: 'error=${zegoError.toString()}',
          );
        }

        RtcLogger.error('❌ Failed to join ZEGO room after sessionStarted', zegoError, zegoStackTrace);

        // ════════════════════════════════════════════════════════════════════════
        // OBSERVABILITY: Record non-fatal error + log call failed
        // ════════════════════════════════════════════════════════════════════════
        crashReportingPlugin?.recordCallFlowError(
          'session_started',
          'Failed to join ZEGO room',
          zegoStackTrace,
        );
        analyticsPlugin?.logCallFailed(
          callId: currentCall.callId,
          failureStage: 'session_started',
          failureReason: 'zego_room_join_failed',
          errorCode: 'ZEGO_JOIN_ERROR',
        );

        // CRITICAL: Notify remote peer that we failed to join
        // This prevents the remote peer from being stuck in call screen
        RtcLogger.error('🚨 Room join failed - emitting session-end to notify remote peer');

        // End call with emission to notify remote peer
        await endCall(CallEndReason.failed, emitSignalingEvent: true);

        onError?.call(CallError.unknown(
          message: 'Failed to join call room',
          exception: zegoError,
          stackTrace: zegoStackTrace,
        ));
      }
    } else {
      // This is a regular call answer (not sessionStarted)
      // Transition to connecting
      await _stateManager.transitionToConnecting();

      // If we're the caller, now join the ZEGO room
      if (!currentCall.isIncoming) {
        // Room should already be set from startOutgoingCall
        // The callee will also join, establishing the connection
        RtcLogger.info('Call answered, waiting for media connection');
      }
    }
  }

  /// Handle call reject (callee declined)
  Future<void> _handleCallRejectEvent(RtcSignalingEvent event) async {
    RtcLogger.flowStep('CALL_REJECT', 'Processing call reject from socket');

    final currentCall = _stateManager.currentCall;
    if (currentCall == null) {
      RtcLogger.warning('Received reject event but no current call in progress');
      // Still try to end any CallKit calls that might be lingering
      if (_nativeCallKit != null) {
        await _nativeCallKit!.endAllCalls();
      }
      return;
    }

    // CRITICAL FIX: Be lenient with callId matching for rejection events
    // The server often doesn't provide a callId, causing the mapper to generate
    // a mismatched ID. Since we know there's only one active call at a time,
    // we should accept the rejection for the current call even if IDs don't match.
    if (currentCall.callId != event.callId) {
      RtcLogger.warning(
        '⚠️ Rejection event callId mismatch (common when server doesn\'t provide callId)',
      );
      RtcLogger.info('   Current call ID: ${currentCall.callId}');
      RtcLogger.info('   Event call ID: ${event.callId}');
      RtcLogger.info('   ✅ Accepting rejection for current active call anyway');
    }

    _timeoutManager.cancelTimeout();

    // CRITICAL: End native CallKit call to stop ringing (only if useCallKit is true)
    if (useCallKit && _nativeCallKit != null) {
      await _nativeCallKit!.endCall(currentCall.callId);
    }

    await _stateManager.endCall(CallEndReason.rejected);
    onCallRejected?.call(currentCall, CallEndReason.rejected);
  }

  /// Handle call cancel (caller cancelled before answer)
  Future<void> _handleCallCancelEvent(RtcSignalingEvent event) async {
    RtcLogger.flowStep('CALL_CANCEL', 'Processing call cancel from socket');

    final currentCall = _stateManager.currentCall;
    if (currentCall == null) {
      RtcLogger.warning('Received cancel event but no current call in progress');
      // Still try to end any CallKit calls that might be lingering (only if useCallKit is true)
      if (useCallKit && _nativeCallKit != null) {
        await _nativeCallKit!.endAllCalls();
      }
      return;
    }

    // CRITICAL FIX: Be lenient with callId matching (same as reject event)
    if (currentCall.callId != event.callId) {
      RtcLogger.warning('⚠️ Cancel event callId mismatch');
      RtcLogger.info('   Current call ID: ${currentCall.callId}');
      RtcLogger.info('   Event call ID: ${event.callId}');
      RtcLogger.info('   ✅ Accepting cancellation for current active call anyway');
    }

    _timeoutManager.cancelTimeout();

    // CRITICAL: End native CallKit call to stop ringing (only if useCallKit is true)
    if (useCallKit && _nativeCallKit != null) {
      await _nativeCallKit!.endCall(currentCall.callId);
    }

    await _stateManager.endCall(CallEndReason.cancelled);
    onCallEnded?.call(currentCall, CallEndReason.cancelled);
  }

  /// Handle call end (active call ended)
  Future<void> _handleCallEndEvent(RtcSignalingEvent event) async {
    RtcLogger.flowStep('CALL_END', 'Processing call end from remote peer');

    final currentCall = _stateManager.currentCall;
    if (currentCall == null) {
      RtcLogger.warning('Received end event but no current call in progress');
      return;
    }

    // An end event legitimately arrives keyed on EITHER our callId or the
    // server's sessionId, so accept both — but nothing else. Ending whatever
    // call happens to be active meant a stale sessionEnded from a previous call
    // tore down the live one, dropping the user out of an in-progress call.
    if (event.callId != currentCall.callId &&
        event.callId != currentCall.sessionId) {
      RtcLogger.warning(
        '⚠️ Ignoring end event for a different call',
        {
          'currentCallId': currentCall.callId,
          'currentSessionId': currentCall.sessionId,
          'eventCallId': event.callId,
        },
      );
      return;
    }

    // ════════════════════════════════════════════════════════════════════════
    // CRITICAL: Check who ended the call (sessionEndedBy: "user" or "listener")
    // If WE are the one who ended (or our side had an issue), emit session-end
    // to ensure the other side gets notified
    // ════════════════════════════════════════════════════════════════════════
    final sessionEndedBy = event.metadata?['sessionEndedBy'] as String?;
    final isListener = currentCall.isIncoming; // Listener receives incoming calls

    // Determine if this end was triggered by OUR side
    final weEndedIt = (sessionEndedBy == 'listener' && isListener) ||
                      (sessionEndedBy == 'user' && !isListener);

    if (weEndedIt) {
      // Our side ended/disconnected - emit session-end to notify other side
      RtcLogger.info('📤 Our side ended (sessionEndedBy: $sessionEndedBy), emitting session-end to notify other side');
      await endCall(CallEndReason.ended, emitSignalingEvent: true);
    } else {
      // Remote peer ended - don't emit to prevent echo
      RtcLogger.info('📥 Remote peer ended call (sessionEndedBy: $sessionEndedBy), cleaning up without emitting');
      await endCall(CallEndReason.remoteEnded, emitSignalingEvent: false);
    }
  }

  /// Handle call timeout
  Future<void> _handleCallTimeoutEvent(RtcSignalingEvent event) async {
    RtcLogger.flowStep('CALL_TIMEOUT', 'Processing call timeout from socket');

    final currentCall = _stateManager.currentCall;
    if (currentCall == null || currentCall.callId != event.callId) {
      return;
    }

    await endCall(CallEndReason.timeout);
  }

  /// Handle call busy (callee is in another call)
  Future<void> _handleCallBusyEvent(RtcSignalingEvent event) async {
    RtcLogger.flowStep('CALL_BUSY', 'Processing call busy from socket');

    final currentCall = _stateManager.currentCall;
    if (currentCall == null || currentCall.callId != event.callId) {
      return;
    }

    _timeoutManager.cancelTimeout();
    await _stateManager.endCall(CallEndReason.busy);
    onCallRejected?.call(currentCall, CallEndReason.busy);
  }

  /// Dispose and cleanup resources
  Future<void> dispose() async {
    RtcLogger.info('Disposing RtcCallController');

    _timeoutManager.dispose();
    _stopDurationTimer();
    _networkMonitor.stopMonitoring();

    // Cleanup native CallKit if enabled AND useCallKit flag is true
    if (useCallKit && _nativeCallKit != null) {
      await _nativeCallKit!.dispose();
    }
    _callKitEventHandler?.dispose();

    // Cleanup signaling if enabled
    _signalingHandler?.dispose();

    await _zegoService.destroy();
    _stateManager.dispose();

    _isInitialized = false;

    // Clear chat callbacks
    onChatMessageReceived = null;
    onChatSessionStarted = null;
    onChatSessionEnded = null;
    onChatMessageStatusChanged = null;
    chatManager = null;

    // Clear callbacks
    onCallStateChanged = null;
    onIncomingCall = null;
    onCallAccepted = null;
    onCallRejected = null;
    onCallEnded = null;
    onCallTimeout = null;
    onMissedCall = null;
    onUserJoined = null;
    onUserLeft = null;
    onError = null;
    onReconnecting = null;
    onReconnected = null;

    RtcLogger.success('RtcCallController disposed');
  }

  // ══════════════════════════════════════════════════════════════════════
  // GETTERS
  // ══════════════════════════════════════════════════════════════════════

  /// Get current call data
  CallData? get currentCall => _stateManager.currentCall;

  /// Check if there's an active call
  bool get hasActiveCall => _stateManager.hasActiveCall;

  /// Check if microphone is muted
  bool get isMicrophoneMuted => _zegoService.isMicrophoneMuted;

  /// Check if camera is enabled
  bool get isCameraEnabled => _zegoService.isCameraEnabled;

  /// Check if speaker is enabled
  bool get isSpeakerEnabled => _zegoService.isSpeakerEnabled;

  /// Check if using front camera
  bool get isFrontCamera => _zegoService.isFrontCamera;

  /// Check if controller is initialized
  bool get isInitialized => _isInitialized;

  /// Get signaling handler (for socket integration)
  ///
  /// Use this to set the onSendEvent callback:
  /// ```dart
  /// controller.signalingHandler?.onSendEvent = (event) async {
  ///   socket.emit('call_event', event.toJson());
  /// };
  ///
  /// controller.signalingHandler?.currentUserId = myUserId;
  /// ```
  RtcSignalingHandler? get signalingHandler => _signalingHandler;
}

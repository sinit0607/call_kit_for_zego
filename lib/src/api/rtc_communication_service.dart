import 'dart:async';
import '../adapters/socket_adapter.dart';
import '../adapters/signaling_mapper.dart';
import '../controllers/rtc_call_controller.dart';
import '../controllers/rtc_live_controller.dart';
import '../core/session/session_manager.dart';
import '../core/call/call_manager.dart' as call_mgr;
import '../core/chat/chat_manager.dart';
import '../utils/rtc_logger.dart';
import 'models/user_info.dart';
import 'models/call_event.dart';
import 'models/chat_event.dart';
import 'models/communication_config.dart';
import 'models/communication_error.dart';
import '../models/call_type.dart'; // Import CallType

export 'models/user_info.dart';
export 'models/call_event.dart';
export 'models/chat_event.dart';
export 'models/chat_message.dart';
export 'models/communication_config.dart';
export 'models/communication_error.dart';
export '../models/call_type.dart'; // Export CallType

/// Main communication service - single entry point for all RTC functionality
///
/// This is the primary API that main applications should use.
/// It provides a clean, high-level interface for:
/// - Audio/video calling
/// - Text chat messaging
/// - User session management
///
/// ## Key Design Principles:
///
/// 1. **Socket Ownership**: Main app owns the socket connection.
///    Socket is PASSED to this service during initialization.
///    This service ONLY registers/unregisters its listeners.
///
/// 2. **Event-Driven**: All state changes emit events through streams.
///    Main app listens to these streams for UI updates.
///
/// 3. **Lifecycle Management**: Proper init/pause/resume/dispose handling.
///
/// ## Usage Example:
///
/// ```dart
/// // 1. Initialize once in main.dart
/// await RtcCommunicationService.initialize(
///   config: CommunicationConfig(
///   ),
///   socketAdapter: mySocketAdapter,
/// );
///
/// // 2. Set user after login
/// await RtcCommunicationService.instance.setCurrentUser(
///   UserInfo(userId: '123', userName: 'John'),
/// );
///
/// // 3. Listen to events
/// RtcCommunicationService.instance.callEvents.listen((event) {
///   if (event.type == CallEventType.incomingCall) {
///     // Navigate to incoming call screen
///   }
/// });
///
/// // 4. Start a call
/// final result = await RtcCommunicationService.instance.startCall(
///   targetUserId: 'user_456',
///   targetUserName: 'Jane',
///   callType: CallType.audio,
/// );
/// ```
class RtcCommunicationService {
  static const String _tag = 'RtcCommunicationService';

  static RtcCommunicationService? _instance;

  /// Get the singleton instance
  ///
  /// Throws if not initialized. Always call [initialize] first.
  static RtcCommunicationService get instance {
    if (_instance == null) {
      throw StateError(
        'RtcCommunicationService not initialized. Call initialize() first.',
      );
    }
    return _instance!;
  }

  // Core managers
  late final SessionManager _sessionManager;
  late final call_mgr.CallManager _callManager;
  late final ChatManager _chatManager;
  late final RtcCallController _rtcController;
  late final RtcLiveController _liveController;

  // Configuration
  final CommunicationConfig _config;
  final SocketAdapter _socketAdapter;

  // Error stream
  final _errorController = StreamController<CommunicationError>.broadcast();

  // Initialization state
  bool _isInitialized = false;
  bool _isPaused = false;

  RtcCommunicationService._({
    required CommunicationConfig config,
    required SocketAdapter socketAdapter,
  })  : _config = config,
        _socketAdapter = socketAdapter;

  /// Initialize the communication service
  ///
  /// MUST be called once at app startup, before any other operations.
  ///
  /// Parameters:
  /// - [config]: Configuration for ZEGO, Socket, and CallKit
  /// - [socketAdapter]: Socket instance from main app (REQUIRED)
  ///
  /// The socket should already be connected before calling this.
  /// This service will attach its listeners to the socket.
  ///
  /// Example:
  /// ```dart
  /// final socket = IO.io('https://your-server.com');
  /// final socketAdapter = SocketIOAdapter(socket);
  ///
  /// await RtcCommunicationService.initialize(
  ///   config: CommunicationConfig(...),
  ///   socketAdapter: socketAdapter,
  /// );
  /// ```
  static Future<void> initialize({
    required CommunicationConfig config,
    required SocketAdapter socketAdapter,
  }) async {
    // Check if already initialized (not just instance exists)
    if (_instance != null && _instance!._isInitialized) {
      RtcLogger.warning('[$_tag] Already initialized');
      return;
    }

    RtcLogger.info('[$_tag] Initializing RtcCommunicationService');

    _instance = RtcCommunicationService._(
      config: config,
      socketAdapter: socketAdapter,
    );

    await _instance!._init();
  }

  /// Internal initialization
  Future<void> _init() async {
    try {
      RtcLogger.init(_config.rtcCallConfig);

      // 1. Initialize SessionManager
      _sessionManager = SessionManager();

      // 2. Initialize RtcCallController
      _rtcController = RtcCallController(
        zegoAppId: _config.zegoConfig.appId,
        zegoAppSign: _config.zegoConfig.appSign,
        config: _config.rtcCallConfig,
        nativeCallKitConfig: _config.callKitConfig?.toNativeCallKitConfig(),
        useCallKit: _config.useCallKit,
        useSignaling: true,
      );

      await _rtcController.init();

      // 3. Initialize CallManager (pass socket, rtc controller, and signaling mapper)
      _callManager = call_mgr.CallManager(
        socket: _socketAdapter,
        rtcController: _rtcController,
        sessionManager: _sessionManager,
        signalingMapper: _config.signalingMapper ?? DefaultSignalingMapper(),
      );

      // 4. Initialize ChatManager
      _chatManager = ChatManager(
        socket: _socketAdapter,
        sessionManager: _sessionManager,
      );

      // 5. Inject ChatManager into RtcCallController and wire session sync
      _rtcController.chatManager = _chatManager;
      _rtcController.onChatSessionStarted = (sessionId, remoteUser) {
        _chatManager.setCurrentSession(sessionId);
      };
      _rtcController.onChatSessionEnded = (sessionId, reason) {
        // ChatManager handles its own cleanup via socket listeners
      };

      // 6. Initialize RtcLiveController for live streaming
      _liveController = RtcLiveController();
      await _liveController.init(
        zegoAppId: _config.zegoConfig.appId,
        zegoAppSign: _config.zegoConfig.appSign,
      );

      _isInitialized = true;

      RtcLogger.success('[$_tag] Initialization complete');
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Initialization failed', e, stack);

      // CRITICAL: Reset instance on failure to allow re-initialization
      _instance = null;
      _isInitialized = false;

      _errorController.add(CommunicationError.initialization(
        message: 'Failed to initialize RtcCommunicationService',
        exception: e,
        stackTrace: stack,
      ));
      rethrow;
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // PUBLIC STREAMS
  // ══════════════════════════════════════════════════════════════════════

  /// Stream of call events
  ///
  /// Listen to this for:
  /// - Incoming calls
  /// - Call accepted/rejected/ended
  /// - Call state changes
  /// - Remote user joined/left
  ///
  /// Example:
  /// ```dart
  /// service.callEvents.listen((event) {
  ///   switch (event.type) {
  ///     case CallEventType.incomingCall:
  ///       navigateToIncomingCallScreen(event);
  ///       break;
  ///     case CallEventType.callEnded:
  ///       navigateBack();
  ///       break;
  ///   }
  /// });
  /// ```
  Stream<CallEvent> get callEvents => _callManager.events;

  /// Stream of chat events
  ///
  /// Listen to this for:
  /// - New messages received
  /// - Messages sent
  /// - Session started/ended
  /// - Typing indicators
  ///
  /// Example:
  /// ```dart
  /// service.chatEvents.listen((event) {
  ///   switch (event.type) {
  ///     case ChatEventType.messageReceived:
  ///       addMessageToUI(event.message);
  ///       break;
  ///     case ChatEventType.sessionEnded:
  ///       closeChat();
  ///       break;
  ///   }
  /// });
  /// ```
  Stream<ChatEvent> get chatEvents => _chatManager.events;

  /// Stream of errors
  ///
  /// Listen to this for error handling and logging.
  Stream<CommunicationError> get errors => _errorController.stream;

  // ══════════════════════════════════════════════════════════════════════
  // USER SESSION MANAGEMENT
  // ══════════════════════════════════════════════════════════════════════

  /// Set the current authenticated user
  ///
  /// Call this after successful login.
  /// The package needs to know who the current user is to handle calls/chats.
  ///
  /// Example:
  /// ```dart
  /// await service.setCurrentUser(UserInfo(
  ///   userId: '123',
  ///   userName: 'John Doe',
  ///   userImage: 'https://...',
  /// ));
  /// ```
  Future<void> setCurrentUser(UserInfo user) async {
    _ensureInitialized();
    await _sessionManager.setCurrentUser(user);

    // Update signaling handler's current user ID
    final signalingHandler = _rtcController.signalingHandler;
    if (signalingHandler != null) {
      signalingHandler.currentUserId = user.userId;
      RtcLogger.info('[$_tag] Updated signaling handler currentUserId: ${user.userId}');
    }

    RtcLogger.info('[$_tag] Current user set', {'userId': user.userId});
  }

  /// Clear the current user on logout
  ///
  /// Call this when the user logs out.
  /// IMPORTANT: This will automatically end any active calls/chats.
  Future<void> clearCurrentUser() async {
    _ensureInitialized();

    // End active call if any
    if (_callManager.hasActiveCall) {
      RtcLogger.warning('[$_tag] Ending active call during logout');
      try {
        await _callManager.endCall();
      } catch (e) {
        RtcLogger.error('[$_tag] Error ending call during logout', e);
      }
    }

    await _sessionManager.clearUser();
    RtcLogger.info('[$_tag] Current user cleared');
  }

  /// Get the current authenticated user
  UserInfo? get currentUser => _sessionManager.currentUser;

  /// Check if a user is authenticated
  bool get isAuthenticated => _sessionManager.isAuthenticated;

  // ══════════════════════════════════════════════════════════════════════
  // CALL OPERATIONS
  // ══════════════════════════════════════════════════════════════════════

  /// Start an outgoing call
  ///
  /// Parameters:
  /// - [targetUserId]: ID of the user to call
  /// - [targetUserName]: Name of the user to call
  /// - [targetUserImage]: Optional avatar URL
  /// - [callType]: Audio or video
  /// - [metadata]: Optional metadata to attach to the call
  ///
  /// Returns a [CallResult] with success status and call ID.
  ///
  /// Example:
  /// ```dart
  /// final result = await service.startCall(
  ///   targetUserId: 'user_123',
  ///   targetUserName: 'Jane Doe',
  ///   callType: CallType.video,
  /// );
  ///
  /// if (result.success) {
  ///   navigateToCallingScreen(result.callId);
  /// }
  /// ```
  Future<call_mgr.CallResult> startCall({
    required String targetUserId,
    required String targetUserName,
    String? targetUserImage,
    required CallType callType,
    Map<String, dynamic>? metadata,
  }) async {
    _ensureInitialized();

    try {
      return await _callManager.startCall(
        targetUserId: targetUserId,
        targetUserName: targetUserName,
        targetUserImage: targetUserImage,
        callType: callType,
        metadata: metadata,
      );
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to start call', e, stack);
      _errorController.add(CommunicationError.call(
        message: 'Failed to start call',
        exception: e,
        stackTrace: stack,
      ));
      return call_mgr.CallResult(success: false, error: e.toString());
    }
  }

  /// Accept an incoming call by its callId.
  Future<void> acceptCall(String callId) async {
    _ensureInitialized();

    try {
      await _callManager.acceptCall(callId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to accept call', e, stack);
      _errorController.add(CommunicationError.call(
        message: 'Failed to accept call',
        exception: e,
        stackTrace: stack,
      ));
      rethrow;
    }
  }




  Future<void> rejectCall(String callId) async {
    _ensureInitialized();

    try {
      await _callManager.rejectCall(callId);
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to reject call', e, stack);
      _errorController.add(CommunicationError.call(
        message: 'Failed to reject call',
        exception: e,
        stackTrace: stack,
      ));
      rethrow;
    }
  }





  Future<void> endCall() async {
    _ensureInitialized();

    try {
      await _callManager.endCall();
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to end call', e, stack);
      _errorController.add(CommunicationError.call(
        message: 'Failed to end call',
        exception: e,
        stackTrace: stack,
      ));
      rethrow;
    }
  }



  /// Toggle microphone mute/unmute
  Future<void> toggleMute() async {
    _ensureInitialized();
    await _callManager.toggleMute();
  }

  /// Toggle camera on/off
  Future<void> toggleCamera() async {
    _ensureInitialized();
    await _callManager.toggleCamera();
  }

  /// Switch between front and back camera
  Future<void> switchCamera() async {
    _ensureInitialized();
    await _callManager.switchCamera();
  }

  /// Toggle speaker on/off
  Future<void> toggleSpeaker() async {
    _ensureInitialized();
    await _callManager.toggleSpeaker();
  }

  /// Check if microphone is muted
  bool get isMicrophoneMuted => _callManager.isMicrophoneMuted;

  /// Check if camera is enabled
  bool get isCameraEnabled => _callManager.isCameraEnabled;

  /// Check if speaker is enabled
  bool get isSpeakerEnabled => _callManager.isSpeakerEnabled;

  /// Check if using front camera
  bool get isFrontCamera => _callManager.isFrontCamera;

  /// Get current call ID
  String? get currentCallId => _callManager.currentCallId;

  /// Check if there's an active call
  bool get hasActiveCall => _callManager.hasActiveCall;

  /// Mark call as connected in native CallKit
  /// This stops the ringtone and transitions CallKit to "in call" state
  Future<void> markCallConnected(String callId) async {
    _ensureInitialized();
    await _callManager.markCallConnected(callId);
  }

  // ══════════════════════════════════════════════════════════════════════
  // CHAT OPERATIONS
  // ══════════════════════════════════════════════════════════════════════

  /// Send a chat message
  ///
  /// Parameters:
  /// - [sessionId]: The chat session ID
  /// - [content]: Message text content
  /// - [recipientId]: Optional recipient user ID
  /// - [metadata]: Optional additional metadata
  ///
  /// Returns a [MessageResult] with success status and the sent message.
  ///
  /// Example:
  /// ```dart
  /// final result = await service.sendMessage(
  ///   sessionId: 'session_123',
  ///   content: 'Hello!',
  /// );
  ///
  /// if (result.success) {
  ///   print('Message sent: ${result.message?.messageId}');
  /// }
  /// ```
  Future<MessageResult> sendMessage({
    required String sessionId,
    required String content,
    String? recipientId,
    Map<String, dynamic>? metadata,
  }) async {
    _ensureInitialized();

    try {
      return await _chatManager.sendMessage(
        sessionId: sessionId,
        content: content,
        recipientId: recipientId,
        metadata: metadata,
      );
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to send message', e, stack);
      _errorController.add(CommunicationError.call(
        message: 'Failed to send message',
        exception: e,
        stackTrace: stack,
      ));
      return MessageResult(success: false, error: e.toString());
    }
  }

  /// Send a typing indicator
  ///
  /// Call this when the user starts or stops typing.
  ///
  /// Parameters:
  /// - [sessionId]: The chat session ID
  /// - [isTyping]: Whether the user is currently typing
  ///
  /// Example:
  /// ```dart
  /// // User started typing
  /// await service.sendTypingIndicator(
  ///   sessionId: 'session_123',
  ///   isTyping: true,
  /// );
  ///
  /// // User stopped typing
  /// await service.sendTypingIndicator(
  ///   sessionId: 'session_123',
  ///   isTyping: false,
  /// );
  /// ```
  Future<void> sendTypingIndicator({
    required String sessionId,
    required bool isTyping,
  }) async {
    _ensureInitialized();
    await _chatManager.sendTypingIndicator(
      sessionId: sessionId,
      isTyping: isTyping,
    );
  }

  /// Get the current chat session ID
  String? get currentChatSessionId => _chatManager.currentSessionId;

  /// Set the current chat session ID
  ///
  /// Use this when a session starts via a call or other means.
  void setCurrentChatSession(String sessionId) {
    _ensureInitialized();
    _chatManager.setCurrentSession(sessionId);
  }

  // ══════════════════════════════════════════════════════════════════════
  // LIFECYCLE MANAGEMENT
  // ══════════════════════════════════════════════════════════════════════

  /// Pause the service (e.g., when app goes to background)
  ///
  /// This does NOT disconnect the socket - that's the main app's responsibility.
  /// It only pauses internal timers and operations.
  Future<void> pause() async {
    if (!_isInitialized || _isPaused) return;

    RtcLogger.info('[$_tag] Pausing service');
    _isPaused = true;

    // Pause internal operations if needed
    // Socket listeners remain active
  }

  /// Resume the service (e.g., when app returns to foreground)
  Future<void> resume() async {
    if (!_isInitialized || !_isPaused) return;

    RtcLogger.info('[$_tag] Resuming service');
    _isPaused = false;

    // Resume internal operations if needed
  }

  /// Dispose the service and clean up resources
  ///
  /// IMPORTANT: This removes all socket listeners but does NOT dispose the socket.
  /// The main app is responsible for socket disposal.
  ///
  /// Call this when:
  /// - App is shutting down
  /// - User logs out (after ending active calls/chats)
  /// - Service needs to be re-initialized
  Future<void> dispose() async {
    if (!_isInitialized) return;

    RtcLogger.info('[$_tag] Disposing service');

    // Dispose managers (they will remove their socket listeners)
    _callManager.dispose();
    _chatManager.dispose();
    _sessionManager.dispose();

    // Dispose controllers
    _rtcController.dispose();
    await _liveController.dispose();

    // Close error stream
    await _errorController.close();

    _isInitialized = false;
    _instance = null;

    RtcLogger.info('[$_tag] Disposal complete');
  }

  /// Ensure service is initialized before operations
  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError(
        'RtcCommunicationService not initialized. Call initialize() first.',
      );
    }
  }

  // Getter for live streaming controller
  RtcLiveController get liveController => _liveController;

  /// Check if service is initialized
  bool get isInitialized => _isInitialized;

  /// Check if service is paused
  bool get isPaused => _isPaused;
}

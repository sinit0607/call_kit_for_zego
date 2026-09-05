import 'dart:async';
import 'package:flutter/widgets.dart';
import '../models/live_stream_data.dart';
import '../models/live_stream_type.dart';
import '../services/zego_live_service.dart';
import '../utils/rtc_logger.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

/// Controller for live streaming (1-to-many broadcast)
/// Manages both broadcaster (host going live) and viewer experiences
class RtcLiveController {
  static const String _tag = 'RtcLiveController';

  late final ZegoLiveService _zegoService;
  bool _isInitialized = false;

  // Current stream state
  LiveStreamType? _currentType;
  LiveStreamData? _currentStream;

  // ─── LIFECYCLE ────────────────────────────────────────────────────────────

  /// Initialize the live controller with ZEGO credentials.
  /// No-op when called from RtcCommunicationService (credentials come from config).
  Future<void> init({
    int? zegoAppId,
    String? zegoAppSign,
  }) async {
    if (_isInitialized) {
      RtcLogger.info('[$_tag] Already initialized');
      return;
    }

    if (zegoAppId == null || zegoAppSign == null) {
      RtcLogger.info('[$_tag] init() called without credentials — engine managed by RtcCommunicationService');
      _zegoService = ZegoLiveService();
      _setupCallbacks();
      _isInitialized = true;
      return;
    }

    RtcLogger.info('[$_tag] Initializing with AppID: $zegoAppId');
    _zegoService = ZegoLiveService();

    await _zegoService.init(appId: zegoAppId, appSign: zegoAppSign);
    _setupCallbacks();
    _isInitialized = true;

    RtcLogger.success('[$_tag] Initialization complete');
  }

  void _setupCallbacks() {
    _zegoService.onBroadcastStarted = () {
      RtcLogger.success('[$_tag] Broadcast started');
      onBroadcastStarted?.call();
    };

    _zegoService.onBroadcastEnded = () {
      RtcLogger.info('[$_tag] Broadcast ended');
      onBroadcastEnded?.call();
      _currentStream = null;
      _currentType = null;
    };

    _zegoService.onViewerCountUpdate = (count) {
      RtcLogger.info('[$_tag] Viewer count: $count');
      onViewerCountUpdate?.call(count);
    };

    _zegoService.onRoomStreamUpdate = (roomId, updateType, streamList, extendedData) {
      onRoomStreamUpdate?.call(roomId, updateType, streamList, extendedData);
    };

    _zegoService.onPlayerStateUpdate = (streamId, state, errorCode, extendedData) {
      onPlayerStateUpdate?.call(streamId, state, errorCode, extendedData);
    };

    _zegoService.onIMRecvBroadcastMessage = (roomId, messageList) {
      final messages = messageList.map((m) => LiveChatMessage(
        messageId: m.sendTime.toString(),
        senderId: m.fromUser.userID,
        senderName: m.fromUser.userName,
        content: m.message,
        timestamp: DateTime.fromMillisecondsSinceEpoch(m.sendTime),
        isSentByLocalUser: false,
      )).toList();
      onChatMessage?.call(messages);
    };

    _zegoService.onIMRecvBarrageMessage = (roomId, messageList) {
      final messages = messageList.map((m) => LiveChatMessage(
        messageId: m.sendTime.toString(),
        senderId: m.fromUser.userID,
        senderName: m.fromUser.userName,
        content: m.message,
        timestamp: DateTime.fromMillisecondsSinceEpoch(m.sendTime),
        isSentByLocalUser: false,
      )).toList();
      onChatMessage?.call(messages);
    };

    _zegoService.onIMRecvBarrageMessageRaw = (roomId, messageList) {
      onIMRecvBarrageMessage?.call(roomId, messageList);
    };
  }

  // ─── CALLBACKS ─────────────────────────────────────────────────────────────

  /// Called when the host starts broadcasting
  VoidCallback? onBroadcastStarted;

  /// Called when the host stops broadcasting
  VoidCallback? onBroadcastEnded;

  /// Called when viewer count changes
  void Function(int count)? onViewerCountUpdate;

  /// Called when room streams are updated
  void Function(
    String roomId,
    ZegoUpdateType updateType,
    List<ZegoStream> streamList,
    Map<String, dynamic> extendedData,
  )? onRoomStreamUpdate;

  /// Called when player state changes
  void Function(String streamId, ZegoPlayerState state, int errorCode, Map<String, dynamic>? extendedData)? onPlayerStateUpdate;

  /// Called when a chat message is received
  void Function(List<LiveChatMessage> messages)? onChatMessage;

  /// Raw barrage message callback (for advanced use)
  void Function(String roomId, List<dynamic> messageList)? onIMRecvBarrageMessage;

  /// Called on error
  void Function(String error)? onError;

  // ─── BROADCASTER ──────────────────────────────────────────────────────────

  /// Start broadcasting (go live) as a host
  Future<void> startBroadcast({
    required String roomId,
    required String streamId,
    required String token,
    required String userId,
    required String userName,
    String? hostName,
    String? hostImage,
    String? title,
  }) async {
    _ensureInitialized();

    RtcLogger.info('[$_tag] Starting broadcast: room=$roomId, stream=$streamId');
    _currentType = LiveStreamType.broadcasting;
    _currentStream = LiveStreamData(
      roomId: roomId,
      hostId: userId,
      hostName: hostName ?? userName,
      hostImage: hostImage,
      streamId: streamId,
      isLive: true,
      startedAt: DateTime.now(),
      title: title,
    );

    await _zegoService.startBroadcasting(
      roomId: roomId,
      streamId: streamId,
      token: token,
      userId: userId,
      userName: userName,
    );
  }

  /// Stop broadcasting and end the live session
  Future<void> stopBroadcast() async {
    _ensureInitialized();
    RtcLogger.info('[$_tag] Stopping broadcast');
    await _zegoService.stopBroadcasting();
    _currentStream = null;
    _currentType = null;
  }

  /// Alias for [stopBroadcast]
  Future<void> stopPublishing() => stopBroadcast();

  /// Alias for [startBroadcast] — backward compatible
  Future<void> startPublishing({
    required String roomId,
    required String streamId,
    required String token,
    required String userId,
    required String userName,
  }) =>
      startBroadcast(
        roomId: roomId,
        streamId: streamId,
        token: token,
        userId: userId,
        userName: userName,
      );

  /// Join a live stream and play it — backward compatible alias
  Future<void> playAudienceStream({
    required String roomId,
    required String streamId,
    required String token,
    required String userId,
    required String userName,
    int? viewID,
  }) async {
    await joinAsViewer(
      roomId: roomId,
      streamId: streamId,
      token: token,
      userId: userId,
      userName: userName,
    );
    if (viewID != null) {
      await playStream(streamId: streamId, viewID: viewID);
    }
  }

  // ─── VIEWER ───────────────────────────────────────────────────────────────

  /// Join a live stream as a viewer (login to the room)
  Future<void> joinAsViewer({
    required String roomId,
    required String streamId,
    required String token,
    required String userId,
    required String userName,
    String? hostId,
    String? hostName,
    String? hostImage,
  }) async {
    _ensureInitialized();

    RtcLogger.info('[$_tag] Joining as viewer: room=$roomId, stream=$streamId');
    _currentType = LiveStreamType.viewing;
    _currentStream = LiveStreamData(
      roomId: roomId,
      hostId: hostId ?? '',
      hostName: hostName ?? 'Host',
      hostImage: hostImage,
      streamId: streamId,
      isLive: true,
      startedAt: DateTime.now(),
    );

    await _zegoService.startViewing(
      roomId: roomId,
      streamId: streamId,
      token: token,
      userId: userId,
      userName: userName,
    );
  }

  /// Play the live stream video on a canvas view
  Future<void> playStream({
    required String streamId,
    required int viewID,
  }) async {
    _ensureInitialized();
    await _zegoService.playStream(streamId: streamId, viewID: viewID);
  }

  /// Stop playing the stream
  Future<void> stopPlayingStream(String streamId) async {
    _ensureInitialized();
    await _zegoService.stopPlayingStream(streamId);
  }

  /// Leave the stream and go back
  Future<void> leaveStream() async {
    _ensureInitialized();
    RtcLogger.info('[$_tag] Leaving stream');
    if (_currentStream != null && _currentStream!.streamId.isNotEmpty) {
      await _zegoService.stopPlayingStream(_currentStream!.streamId);
    }
    await _zegoService.stopViewing();
    _currentStream = null;
    _currentType = null;
  }

  /// Alias for [leaveStream]
  Future<void> stopAudienceStream(String streamId) => leaveStream();

  // ─── CONTROLS ─────────────────────────────────────────────────────────────

  /// Mute or unmute the microphone (broadcaster only)
  Future<void> muteAudio(bool mute) async {
    _ensureInitialized();
    await _zegoService.muteAudio(mute);
  }

  /// Alias for [muteAudio]
  Future<void> mutePublishStreamAudio(bool mute) => muteAudio(mute);

  /// Enable or disable the camera (broadcaster only)
  Future<void> enableCamera(bool enable) async {
    _ensureInitialized();
    await _zegoService.enableCamera(enable);
  }

  /// Alias for [enableCamera]
  Future<void> disableCamera(bool disable) => enableCamera(!disable);

  /// Switch between front and back camera (broadcaster only)
  Future<void> switchCamera() async {
    _ensureInitialized();
    await _zegoService.switchCamera();
  }

  /// Alias for [switchCamera]
  Future<void> useFrontCamera(bool useFront) async {
    _ensureInitialized();
    await _zegoService.switchCamera();
  }

  // ─── MESSAGING ────────────────────────────────────────────────────────────

  /// Send a chat message during the live stream
  Future<void> sendChatMessage(String message) async {
    _ensureInitialized();
    await _zegoService.sendChatMessage(message);
  }

  /// Alias for [sendChatMessage]
  Future<void> sendBarrageMessage(String roomId, String message) =>
      sendChatMessage(message);

  // ─── CANVAS ──────────────────────────────────────────────────────────────

  /// Create a native canvas view for video rendering
  Future<Widget?> createCanvasView(Function(int viewID) onCreated) {
    return _zegoService.createCanvasView(onCreated);
  }

  /// Start local camera preview (broadcaster only)
  Future<void> startPreview(int viewID) async {
    _ensureInitialized();
    await _zegoService.startPreview(viewID);
  }

  /// Stop local camera preview (broadcaster only)
  Future<void> stopPreview() async {
    _ensureInitialized();
    await _zegoService.stopPreview();
  }

  // ─── STATE ────────────────────────────────────────────────────────────────

  /// Get the current stream data
  LiveStreamData? get currentStream => _currentStream;

  /// Get the current participation type
  LiveStreamType? get currentType => _currentType;

  /// Check if currently in a live stream
  bool get isInLiveStream =>
      _currentStream != null && _zegoService.isInRoom;

  /// Check if currently broadcasting
  bool get isBroadcasting =>
      _currentType == LiveStreamType.broadcasting && isInLiveStream;

  /// Check if currently viewing
  bool get isViewing =>
      _currentType == LiveStreamType.viewing && isInLiveStream;

  /// Check if engine is initialized
  bool get isInitialized => _isInitialized;

  // ─── CLEANUP ──────────────────────────────────────────────────────────────

  /// Dispose and clean up resources
  Future<void> dispose() async {
    RtcLogger.info('[$_tag] Disposing');
    if (_zegoService.isEngineInitialized) {
      await _zegoService.destroy();
    }
    _isInitialized = false;
    _currentStream = null;
    _currentType = null;
    RtcLogger.info('[$_tag] Disposed');
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError('RtcLiveController not initialized. Call init() first.');
    }
  }
}

/// Simple chat message model for live stream messages
class LiveChatMessage {
  final String messageId;
  final String senderId;
  final String senderName;
  final String content;
  final DateTime timestamp;
  final bool isSentByLocalUser;

  LiveChatMessage({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.timestamp,
    required this.isSentByLocalUser,
  });
}
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:zego_express_engine/zego_express_engine.dart';
import '../utils/rtc_logger.dart';

/// Service wrapper for ZEGOCLOUD Express Engine — Live Streaming mode
/// Handles 1-to-many broadcast scenarios (broadcaster + audience)
/// FLUTTER ONLY — NO NATIVE CODE
class ZegoLiveService {
  static const String _tag = 'ZegoLiveService';

  static final ZegoLiveService _instance = ZegoLiveService._internal();
  factory ZegoLiveService() => _instance;
  ZegoLiveService._internal();

  static ZegoLiveService get instance => _instance;

  bool _isInitialized = false;
  bool _isInRoom = false;
  String? _currentRoomId;
  String? _currentStreamId;
  int? _currentAppId;
  bool _isFrontCamera = true;

  // Callbacks
  VoidCallback? onBroadcastStarted;
  VoidCallback? onBroadcastEnded;
  void Function(int viewerCount)? onViewerCountUpdate;
  void Function(String roomId, ZegoUpdateType updateType, List<ZegoStream> streamList, Map<String, dynamic> extendedData)? onRoomStreamUpdate;
  void Function(String streamId, ZegoPlayerState state, int errorCode, Map<String, dynamic> extendedData)? onPlayerStateUpdate;
  void Function(String roomId, List<ZegoBroadcastMessageInfo> messageList)? onIMRecvBroadcastMessage;
  void Function(String roomId, List<ZegoBarrageMessageInfo> messageList)? onIMRecvBarrageMessage;
  void Function(String roomId, List<ZegoBarrageMessageInfo> messageList)? onIMRecvBarrageMessageRaw;

  /// Initialize the engine with Default scenario
  Future<void> init({
    required int appId,
    required String appSign,
  }) async {
    if (_isInitialized && _currentAppId == appId) {
      RtcLogger.info('[$_tag] Already initialized with appId: $appId');
      return;
    }

    if (appId == 0 || appSign.isEmpty) {
      RtcLogger.error('[$_tag] AppID or AppSign is missing. Please check configuration.');
      return;
    }

    // Destroy existing engine if appId changed
    if (_isInitialized && _currentAppId != appId) {
      await _destroyEngineInternal();
    }

    RtcLogger.info('[$_tag] Initializing Zego Express Engine (AppID: $appId, Scenario: Default)...');

    ZegoEngineProfile profile = ZegoEngineProfile(
      appId,
      ZegoScenario.Default,
      appSign: appSign,
    );

    await ZegoExpressEngine.createEngineWithProfile(profile);
    _isInitialized = true;
    _currentAppId = appId;

    _setupHandlers();

    // FIX BUG #1: Configure audio settings immediately after engine creation
    // This is CRITICAL for audio to work in live streaming
    await _configureAudioVideoSettings();

    RtcLogger.success('[$_tag] Zego Express Engine initialized for live streaming.');
  }

  /// Configure audio and video settings
  /// CRITICAL: Without this, audio may not work in live streaming mode
  Future<void> _configureAudioVideoSettings() async {
    try {
      // Audio config — 48kbps mono is standard for voice
      await ZegoExpressEngine.instance.setAudioConfig(ZegoAudioConfig(
        48000,  // audioBitrate: 48 kbps
        ZegoAudioChannel.Mono,
        ZegoAudioCodecID.Default,
      ));
      RtcLogger.info('[$_tag] Audio config set: 48kbps Mono');

      // Enable echo cancellation
      await ZegoExpressEngine.instance.enableAEC(true);
      RtcLogger.info('[$_tag] AEC enabled');

      // Enable noise suppression
      await ZegoExpressEngine.instance.enableANS(true);
      RtcLogger.info('[$_tag] ANS enabled');

      // Enable auto gain control
      await ZegoExpressEngine.instance.enableAGC(true);
      RtcLogger.info('[$_tag] AGC enabled');

      // FIX: Configure video settings for live streaming
      // Default video config: 360p @ 15fps for audience, broadcaster can use higher
      final videoConfig = ZegoVideoConfig(
        360,   // width: 360px (good balance for live streaming)
        640,   // height: 640px
        360,   // capture width
        640,   // capture height
        600,   // bitrate: 600kbps (suitable for live streaming)
        15,    // fps: 15fps (smooth for streaming, lower bandwidth)
        ZegoVideoCodecID.Default,
      );
      await ZegoExpressEngine.instance.setVideoConfig(videoConfig);
      RtcLogger.info('[$_tag] Video config set: 360x640 @ 15fps 600kbps');

      // FIX BUG #3: Set speaker as default audio route
      // Without this, Android may route audio to earpiece instead of speaker
      await ZegoExpressEngine.instance.setAudioRouteToSpeaker(true);
      RtcLogger.audioRouteChange(from: 'default', to: 'speaker', success: true);
      RtcLogger.info('[$_tag] Audio route set to speaker');

      RtcLogger.success('[$_tag] Audio/Video settings configured for live streaming');
    } catch (e) {
      RtcLogger.error('[$_tag] Failed to configure audio/video settings', e);
    }
  }

  void _setupHandlers() {
    ZegoExpressEngine.onRoomStateUpdate =
        (String roomId, ZegoRoomState state, int errorCode, Map<String, dynamic> extendedData) {
      if (errorCode != 0) {
        RtcLogger.error('[$_tag] Room Error ($errorCode) in Room: $roomId');
      } else {
        RtcLogger.info('[$_tag] Room State: $state in Room: $roomId');
        if (state == ZegoRoomState.Connected) {
          _isInRoom = true;
        } else if (state == ZegoRoomState.Disconnected) {
          _isInRoom = false;
        }
      }
    };

    ZegoExpressEngine.onPublisherStateUpdate =
        (String streamId, ZegoPublisherState state, int errorCode, Map<String, dynamic> extendedData) {
      if (errorCode != 0) {
        RtcLogger.error('[$_tag] Publisher Error ($errorCode) for Stream: $streamId');
      } else {
        RtcLogger.info('[$_tag] Publisher State: $state for Stream: $streamId');
        if (state == ZegoPublisherState.Publishing) {
          onBroadcastStarted?.call();
        }
      }
    };

    ZegoExpressEngine.onPlayerStateUpdate =
        (String streamId, ZegoPlayerState state, int errorCode, Map<String, dynamic> extendedData) {
      RtcLogger.info('[$_tag] Player State: $state for Stream: $streamId (error: $errorCode)');
      onPlayerStateUpdate?.call(streamId, state, errorCode, extendedData);
    };

    ZegoExpressEngine.onPlayerStreamEvent =
        (ZegoStreamEvent event, String streamId, String extraInfo) {
      RtcLogger.info('[$_tag] Player Stream Event: $event for Stream: $streamId');
    };

    ZegoExpressEngine.onRoomStreamUpdate =
        (String roomId, ZegoUpdateType updateType, List<ZegoStream> streamList, Map<String, dynamic> extendedData) {
      RtcLogger.info('[$_tag] Room Stream Update: $updateType for Room: $roomId, streams: ${streamList.length}');
      onRoomStreamUpdate?.call(roomId, updateType, streamList, extendedData);
    };

    ZegoExpressEngine.onIMRecvBroadcastMessage =
        (String roomId, List<ZegoBroadcastMessageInfo> messageList) {
      RtcLogger.info('[$_tag] Received Broadcast Message in Room: $roomId');
      onIMRecvBroadcastMessage?.call(roomId, messageList);
    };

    ZegoExpressEngine.onIMRecvBarrageMessage =
        (String roomId, List<ZegoBarrageMessageInfo> messageList) {
      RtcLogger.info('[$_tag] Received Barrage Message in Room: $roomId');
      onIMRecvBarrageMessage?.call(roomId, messageList);
      onIMRecvBarrageMessageRaw?.call(roomId, messageList);
    };

    ZegoExpressEngine.onRoomUserUpdate =
        (String roomId, ZegoUpdateType updateType, List<ZegoUser> userList) {
      RtcLogger.info('[$_tag] Room User Update: $updateType in Room: $roomId, users: ${userList.length}');
      if (updateType == ZegoUpdateType.Add) {
        onViewerCountUpdate?.call(userList.length);
      }
    };
  }

  // ─── BROADCASTER ────────────────────────────────────────────────────────────

  /// Start broadcasting (go live) as a host
  Future<void> startBroadcasting({
    required String roomId,
    required String streamId,
    required String token,
    required String userId,
    required String userName,
  }) async {
    // The engine's callbacks are static and shared with the call service, so
    // whichever side is actually working has to claim them. See ZegoService.
    _setupHandlers();

    if (!_isInitialized) {
      RtcLogger.error('[$_tag] Cannot start broadcasting — engine not initialized');
      return;
    }

    RtcLogger.info('[$_tag] Starting broadcast in Room: $roomId, Stream: $streamId');
    _currentRoomId = roomId;

    ZegoUser user = ZegoUser(userId, userName);
    ZegoRoomConfig config = ZegoRoomConfig.defaultConfig()..token = token;

    await ZegoExpressEngine.instance.loginRoom(roomId, user, config: config);

    // FIX BUG #2: CRITICAL — Enable audio capture device and unmute microphone
    // BEFORE starting to publish. Without this, the microphone may not capture audio.
    try {
      await ZegoExpressEngine.instance.enableAudioCaptureDevice(true);
      RtcLogger.info('[$_tag] Audio capture device ENABLED');
    } catch (e) {
      RtcLogger.error('[$_tag] Failed to enable audio capture device', e);
    }

    // FIX BUG #4: Ensure microphone is unmuted before publishing
    await ZegoExpressEngine.instance.muteMicrophone(false);
    RtcLogger.microphoneStateChange(isMuted: false, success: true);

    // FIX: Enable camera BEFORE publishing — without this, video track won't be
    // included in the published stream even though the stream ID is valid.
    // Audio works by default, but video requires explicit enable.
    try {
      await ZegoExpressEngine.instance.enableCamera(true);
      RtcLogger.info('[$_tag] Camera ENABLED for live broadcast');
      // Also reset to front camera for consistency
      await ZegoExpressEngine.instance.useFrontCamera(true);
    } catch (e) {
      RtcLogger.warning('[$_tag] Failed to enable camera: $e');
    }

    await ZegoExpressEngine.instance.startPublishingStream(streamId);
    RtcLogger.success('[$_tag] Broadcast started: $streamId');
  }

  /// Stop broadcasting (end the live session)
  Future<void> stopBroadcasting() async {
    if (!_isInitialized) return;

    RtcLogger.info('[$_tag] Stopping broadcast...');
    await ZegoExpressEngine.instance.stopPublishingStream();
    await ZegoExpressEngine.instance.logoutRoom();
    _isInRoom = false;
    _currentRoomId = null;

    onBroadcastEnded?.call();
    RtcLogger.success('[$_tag] Broadcast stopped');
  }

  /// Alias for [stopBroadcasting] — stops publishing stream (backward compatible)
  Future<void> stopPublishing() => stopBroadcasting();

  /// Alias for [startBroadcasting] — starts publishing stream (backward compatible)
  Future<void> startPublishing({
    required String roomId,
    required String streamId,
    required String token,
    required String userId,
    required String userName,
  }) =>
      startBroadcasting(
        roomId: roomId,
        streamId: streamId,
        token: token,
        userId: userId,
        userName: userName,
      );

  // ─── VIEWER ─────────────────────────────────────────────────────────────────

  /// Join a live stream as a viewer
  Future<void> startViewing({
    required String roomId,
    required String streamId,
    required String token,
    required String userId,
    required String userName,
  }) async {
    if (!_isInitialized) {
      RtcLogger.error('[$_tag] Cannot start viewing — engine not initialized');
      return;
    }

    RtcLogger.info('[$_tag] Joining as viewer: Room $roomId, Stream $streamId');
    _currentRoomId = roomId;
    _currentStreamId = streamId;

    ZegoUser user = ZegoUser(userId, userName);
    ZegoRoomConfig config = ZegoRoomConfig.defaultConfig()..token = token;

    await ZegoExpressEngine.instance.loginRoom(roomId, user, config: config);
    RtcLogger.success('[$_tag] Joined as viewer: $userName ($userId) in Room: $roomId');
  }

  /// Play the live stream video on a canvas view
  Future<void> playStream({
    required String streamId,
    required int viewID,
  }) async {
    // The engine's callbacks are static and shared with the call service, so
    // whichever side is actually working has to claim them. See ZegoService.
    _setupHandlers();

    if (!_isInitialized) return;

    RtcLogger.info('[$_tag] Playing stream: $streamId on viewID: $viewID');
    _currentStreamId = streamId;
    ZegoCanvas canvas = ZegoCanvas(viewID);
    canvas.viewMode = ZegoViewMode.AspectFill;

    // FIX: Pass player config with roomID for proper audio routing
    ZegoPlayerConfig playerConfig = ZegoPlayerConfig.defaultConfig()
      ..roomID = _currentRoomId ?? '';

    await ZegoExpressEngine.instance.startPlayingStream(
      streamId,
      canvas: canvas,
      config: playerConfig,
    );
  }

  /// Stop viewing and leave the stream
  Future<void> stopViewing() async {
    if (!_isInitialized) return;

    RtcLogger.info('[$_tag] Stopping viewing...');
    if (_currentStreamId != null) {
      await ZegoExpressEngine.instance.stopPlayingStream(_currentStreamId!);
    }
    await ZegoExpressEngine.instance.logoutRoom();
    _isInRoom = false;
    _currentRoomId = null;
    _currentStreamId = null;
    RtcLogger.success('[$_tag] Stopped viewing');
  }

  /// Stop playing a specific stream (backward compatible)
  Future<void> stopPlayingStream(String streamId) async {
    if (!_isInitialized) return;
    await ZegoExpressEngine.instance.stopPlayingStream(streamId);
    RtcLogger.info('[$_tag] Stopped playing stream: $streamId');
  }

  /// Alias for [stopViewing] — backward compatible
  Future<void> stopAudienceStream(String streamId) => stopViewing();

  // ─── CONTROLS ──────────────────────────────────────────────────────────────

  /// Mute or unmute the microphone (broadcaster only)
  Future<void> muteAudio(bool mute) async {
    await ZegoExpressEngine.instance.muteMicrophone(mute);
    RtcLogger.microphoneStateChange(isMuted: mute, success: true);
  }

  /// Alias for [muteAudio]
  Future<void> mutePublishStreamAudio(bool mute) => muteAudio(mute);

  /// Enable or disable the camera (broadcaster only)
  Future<void> enableCamera(bool enable) async {
    await ZegoExpressEngine.instance.enableCamera(enable);
    RtcLogger.info('[$_tag] Camera ${enable ? "enabled" : "disabled"}');
  }

  /// Alias for [enableCamera]
  Future<void> disableCamera(bool disable) => enableCamera(!disable);

  /// Switch between front and back camera (broadcaster only)
  Future<void> switchCamera() async {
    _isFrontCamera = !_isFrontCamera;
    await ZegoExpressEngine.instance.useFrontCamera(_isFrontCamera);
    RtcLogger.info('[$_tag] Switched to ${_isFrontCamera ? "front" : "back"} camera');
  }

  /// Alias for [switchCamera]
  Future<void> useFrontCamera(bool useFront) async {
    await ZegoExpressEngine.instance.useFrontCamera(useFront);
  }

  // ─── MESSAGING ─────────────────────────────────────────────────────────────

  /// Send a chat message during the live stream
  Future<void> sendChatMessage(String message) async {
    if (!_isInitialized || _currentRoomId == null) return;
    try {
      await ZegoExpressEngine.instance.sendBarrageMessage(_currentRoomId!, message);
      RtcLogger.info('[$_tag] Sent barrage message: $message');
    } catch (e) {
      RtcLogger.error('[$_tag] Failed to send barrage message', e);
    }
  }

  /// Alias for [sendChatMessage]
  Future<void> sendBarrageMessage(String roomId, String message) => sendChatMessage(message);

  // ─── CANVAS ─────────────────────────────────────────────────────────────────

  /// Create a native canvas view for video rendering
  Future<Widget?> createCanvasView(Function(int viewID) onCreated) async {
    final view = await ZegoExpressEngine.instance.createCanvasView((viewID) {
      if (viewID > 0) {
        RtcLogger.info('[$_tag] Canvas view created: viewID=$viewID');
        onCreated(viewID);
      } else {
        RtcLogger.error('[$_tag] Failed to create canvas view: viewID=$viewID');
      }
    });
    return view;
  }

  /// Start local camera preview (broadcaster only)
  /// Uses canvas-based preview which requires a canvas view to be created first
  Future<void> startPreview(int viewID) async {
    if (!_isInitialized) return;
    try {
      // Create a canvas with the viewID for preview rendering
      final canvas = ZegoCanvas(viewID);
      await ZegoExpressEngine.instance.startPreview(canvas: canvas);
      RtcLogger.info('[$_tag] Preview started on viewID: $viewID');
    } catch (e) {
      RtcLogger.error('[$_tag] Failed to start preview', e);
    }
  }

  /// Stop local camera preview (broadcaster only)
  Future<void> stopPreview() async {
    if (!_isInitialized) return;
    await ZegoExpressEngine.instance.stopPreview();
    RtcLogger.info('[$_tag] Preview stopped');
  }

  // ─── LIFECYCLE ─────────────────────────────────────────────────────────────

  bool get isEngineInitialized => _isInitialized;

  /// Check if currently in a room
  bool get isInRoom => _isInRoom;

  /// Dispose the engine
  Future<void> destroy() async {
    if (!_isInitialized) return;
    RtcLogger.info('[$_tag] Destroying Zego Express Engine...');
    await _destroyEngineInternal();
    RtcLogger.success('[$_tag] Zego Express Engine destroyed');
  }

  Future<void> _destroyEngineInternal() async {
    try {
      await ZegoExpressEngine.destroyEngine();
      _isInitialized = false;
      _currentAppId = null;
      _currentRoomId = null;
    } catch (e) {
      RtcLogger.error('[$_tag] Failed to destroy engine', e);
    }
  }
}

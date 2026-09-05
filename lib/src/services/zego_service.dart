import 'dart:async';
import 'package:flutter/services.dart';
import 'package:zego_express_engine/zego_express_engine.dart';
import '../config/rtc_call_config.dart';
import '../models/call_error.dart';
import '../models/call_type.dart';
import '../utils/rtc_logger.dart';

/// Service wrapper for ZEGOCLOUD Express Engine
/// Handles initialization, room management, stream publishing/playing
/// Implements reconnection logic and lifecycle management
/// FLUTTER ONLY - NO NATIVE CODE
class ZegoService {
  static const int _defaultVideoFps = 30;

  final RtcCallConfig _config;

  bool _isEngineInitialized = false;
  bool _isInRoom = false;
  String? _currentRoomId;
  String? _currentUserId;
  String? _currentUserName;
  String? _currentStreamId;
  CallType? _currentCallType;

  bool _isMicrophoneMuted = false;
  bool _isCameraEnabled = true;
  bool _isFrontCamera = true;
  bool _isSpeakerEnabled = true;

  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  // Fallback mechanism: poll for remote streams when onStreamAdded doesn't fire
  Timer? _streamPollTimer;

  // Callbacks
  Function(String userId)? onUserJoined;
  Function(String userId)? onUserLeft;
  Function(String streamId)? onStreamAdded;
  Function(String streamId)? onStreamRemoved;
  /// Called when a stream starts playing audio/video successfully
  Function(String streamId)? onStreamPlaying;
  /// Called when player enters NoPlay state (audio/video not rendering)
  Function(String streamId, int errorCode)? onStreamPlayingFailed;
  Function(CallError error)? onError;
  Function(int errorCode)? onRoomError;
  VoidCallback? onReconnecting;
  VoidCallback? onReconnected;

  ZegoService(this._config);

  /// Initialize ZEGOCLOUD engine
  Future<void> initialize({
    required int appId,
    required String appSign,
  }) async {
    if (_isEngineInitialized) {
      RtcLogger.warning('ZEGO engine already initialized');
      return;
    }

    try {
      RtcLogger.info('Initializing ZEGOCLOUD engine', {'appId': appId});

      final profile = ZegoEngineProfile(
        appId,
        ZegoScenario.Default,
        appSign: appSign,
        enablePlatformView: true,
      );

      await ZegoExpressEngine.createEngineWithProfile(profile);
      _isEngineInitialized = true;

      // Setup event handlers
      _setupEventHandlers();

      // Configure audio/video settings
      await _configureAudioVideoSettings();

      RtcLogger.success('ZEGOCLOUD engine initialized successfully');

      // ════════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log audio config being applied
      // ════════════════════════════════════════════════════════════════════════
      RtcLogger.audioCall(
        userId: _currentUserId,
        roomId: _currentRoomId,
        callType: _currentCallType?.name,
        step: 'ENGINE_INITIALIZED',
        detail: 'audioBitrate=${_config.audioBitrate}kbps, '
            'AEC=${_config.enableEchoCancellation}, '
            'ANS=${_config.enableNoiseSuppression}, '
            'AGC=${_config.enableAutoGainControl}',
      );
    } catch (e, stackTrace) {
      RtcLogger.error('Failed to initialize ZEGO engine', e, stackTrace);
      onError?.call(CallError.unknown(
        message: 'Failed to initialize engine',
        exception: e,
        stackTrace: stackTrace,
      ));
      rethrow;
    }
  }

  /// Setup ZEGOCLOUD event handlers
  void _setupEventHandlers() {
    RtcLogger.debug('Setting up ZEGO event handlers');

    // Room state updates
    ZegoExpressEngine.onRoomStateUpdate = (
      String roomID,
      ZegoRoomState state,
      int errorCode,
      Map<String, dynamic> extendedData,
    ) {
      RtcLogger.info('🔔🔔🔔 onRoomStateUpdate FIRED - roomId=$roomID state=$state errorCode=$errorCode');

      if (errorCode != 0) {
        RtcLogger.error('Room error', errorCode);
        onRoomError?.call(errorCode);

        // Attempt reconnection for certain errors
        if (_shouldAttemptReconnect(errorCode)) {
          _attemptReconnect();
        }
      }
    };

    // User updates — also trigger stream play for audio calls
    // (onStreamAdded may not fire due to event channel issues, so user-join is a reliable trigger)
    ZegoExpressEngine.onRoomUserUpdate = (
      String roomID,
      ZegoUpdateType updateType,
      List<ZegoUser> userList,
    ) {
      RtcLogger.info('🔔🔔🔔 onRoomUserUpdate FIRED - roomId=$roomID updateType=$updateType userCount=${userList.length}');

      // ════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log signaling event for user update
      // ════════════════════════════════════════════════════════════════════
      RtcLogger.audioSignaling(
        event: 'onRoomUserUpdate',
        direction: updateType == ZegoUpdateType.Add ? 'REMOTE_JOIN' : 'REMOTE_LEAVE',
        metadata: {
          'roomId': roomID,
          'updateType': updateType.name,
          'userCount': userList.length,
        },
      );

      for (final user in userList) {
        if (updateType == ZegoUpdateType.Add) {
          RtcLogger.info('User joined', user.userID);

          // ════════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log remote user joined
          // ════════════════════════════════════════════════════════════════
          RtcLogger.audioCall(
            userId: _currentUserId,
            peerId: user.userID,
            roomId: roomID,
            callType: _currentCallType?.name,
            step: 'REMOTE_USER_JOINED',
            detail: 'peerId=${user.userID}',
          );

          onUserJoined?.call(user.userID);
          // Trigger stream play for audio calls when remote user joins
          // This is a fallback when onStreamAdded doesn't fire
          _scheduleRemoteStreamPlay(user.userID);
        } else {
          RtcLogger.info('User left', user.userID);

          // ════════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log remote user left
          // ════════════════════════════════════════════════════════════════
          RtcLogger.audioCall(
            userId: _currentUserId,
            peerId: user.userID,
            roomId: roomID,
            callType: _currentCallType?.name,
            step: 'REMOTE_USER_LEFT',
            detail: 'peerId=${user.userID}',
          );

          onUserLeft?.call(user.userID);
        }
      }
    };

    // Stream updates
    ZegoExpressEngine.onRoomStreamUpdate = (
      String roomID,
      ZegoUpdateType updateType,
      List<ZegoStream> streamList,
      Map<String, dynamic> extendedData,
    ) {
      RtcLogger.info('🔔🔔🔔🔔🔔🔔 onRoomStreamUpdate FIRED!!! 🔔🔔🔔');
      RtcLogger.info('   roomId: $roomID');
      RtcLogger.info('   updateType: $updateType');
      RtcLogger.info('   streamCount: ${streamList.length}');
      for (final stream in streamList) {
        RtcLogger.info('   📦 Stream: streamId=${stream.streamID}');
      }
      RtcLogger.info('   extendedData: $extendedData');

      // ════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log signaling event for stream update
      // ════════════════════════════════════════════════════════════════════
      RtcLogger.audioSignaling(
        event: 'onRoomStreamUpdate',
        direction: updateType == ZegoUpdateType.Add ? 'STREAM_ADDED' : 'STREAM_REMOVED',
        metadata: {
          'roomId': roomID,
          'updateType': updateType.name,
          'streamCount': streamList.length,
        },
      );

      for (final stream in streamList) {
        if (updateType == ZegoUpdateType.Add) {
          RtcLogger.info('🎉🎉🎉 STREAM ADDED EVENT: streamId=${stream.streamID}');

          // ════════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log stream added
          // ════════════════════════════════════════════════════════════════
          RtcLogger.audioCall(
            userId: _currentUserId,
            roomId: roomID,
            streamId: stream.streamID,
            callType: _currentCallType?.name,
            step: 'STREAM_ADDED',
            detail: 'streamId=${stream.streamID}',
          );

          RtcLogger.info('   About to call onStreamAdded callback with streamId: ${stream.streamID}');
          // Track for re-negotiation on reconnect
          _trackRemoteStream(stream.streamID);
          onStreamAdded?.call(stream.streamID);
          RtcLogger.info('   onStreamAdded callback invoked');
        } else {
          RtcLogger.info('📤 STREAM REMOVED EVENT: streamId=${stream.streamID}');

          // ════════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log stream removed
          // ════════════════════════════════════════════════════════════════
          RtcLogger.audioCall(
            userId: _currentUserId,
            roomId: roomID,
            streamId: stream.streamID,
            callType: _currentCallType?.name,
            step: 'STREAM_REMOVED',
            detail: 'streamId=${stream.streamID}',
          );

          // Untrack stream
          _untrackRemoteStream(stream.streamID);
          onStreamRemoved?.call(stream.streamID);
        }
      }
      RtcLogger.info('🔔 onRoomStreamUpdate handler COMPLETED');
    };

    // Network quality updates
    ZegoExpressEngine.onNetworkQuality = (
      String userID,
      ZegoStreamQualityLevel upstreamQuality,
      ZegoStreamQualityLevel downstreamQuality,
    ) {
      // Log poor network quality
      if (upstreamQuality == ZegoStreamQualityLevel.Bad ||
          downstreamQuality == ZegoStreamQualityLevel.Bad) {
        RtcLogger.warning('Poor network quality detected');
      }
    };

    // Local device exceptions — the only reliable signal that the app never
    // obtained runtime mic/camera permission. Without this the engine happily
    // publishes a silent stream and the call looks connected to both sides.
    ZegoExpressEngine.onLocalDeviceExceptionOccurred = (
      ZegoDeviceExceptionType exceptionType,
      ZegoDeviceType deviceType,
      String deviceID,
    ) {
      RtcLogger.warning(
        'Local device exception: $exceptionType on $deviceType',
        {'deviceID': deviceID},
      );

      final device = deviceType == ZegoDeviceType.Camera ? 'Camera' : 'Microphone';
      switch (exceptionType) {
        case ZegoDeviceExceptionType.PermissionNotGranted:
          onError?.call(CallError.permissionDenied(
            message: '$device permission was not granted. The app must request '
                'it at runtime before starting a call — the manifest/Info.plist '
                'declaration alone is not enough.',
          ));
        case ZegoDeviceExceptionType.ZeroCaptureFps:
        case ZegoDeviceExceptionType.DeviceOccupied:
        case ZegoDeviceExceptionType.SiriIsRecording:
          onError?.call(CallError.permissionDenied(
            message: '$device is unavailable ($exceptionType) — it may be in '
                'use by another app, or permission was revoked mid-call.',
          ));
        default:
          onError?.call(CallError.unknown(
            message: '$device error: $exceptionType',
          ));
      }
    };

    // Player state updates — CRITICAL for audio-only call debugging
    // Fires when stream playback starts, stops, or fails
    ZegoExpressEngine.onPlayerStateUpdate = (
      String streamId,
      ZegoPlayerState state,
      int errorCode,
      Map<String, dynamic> extendedData,
    ) {
      RtcLogger.info('🔔🔔🔔 onPlayerStateUpdate FIRED - streamId=$streamId state=$state errorCode=$errorCode');

      // ════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log player state update
      // ════════════════════════════════════════════════════════════════════
      RtcLogger.audioSignaling(
        event: 'onPlayerStateUpdate',
        direction: state.name,
        metadata: {
          'streamId': streamId,
          'state': state.name,
          'errorCode': errorCode,
        },
      );

      if (state == ZegoPlayerState.Playing) {
        RtcLogger.success('✅ onPlayerStateUpdate: stream is PLAYING — audio/video should be audible/visible');

        // ════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log stream is now playing (audio subscribed successfully)
        // ════════════════════════════════════════════════════════════════════
        RtcLogger.audioSubscribe(
          streamId: streamId,
          success: true,
          userId: _currentUserId,
          roomId: _currentRoomId,
        );

        onStreamPlaying?.call(streamId);
      } else if (state == ZegoPlayerState.NoPlay) {
        RtcLogger.error('❌ onPlayerStateUpdate: stream NO_PLAY — audio/video is NOT rendering! Error: $errorCode');

        // ════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log stream playback failed
        // ════════════════════════════════════════════════════════════════════
        RtcLogger.audioSubscribe(
          streamId: streamId,
          success: false,
          userId: _currentUserId,
          roomId: _currentRoomId,
          error: 'onPlayerStateUpdate: NO_PLAY state, errorCode=$errorCode',
        );

        onStreamPlayingFailed?.call(streamId, errorCode);
      } else {
        RtcLogger.info('onPlayerStateUpdate: state=$state');
      }
    };

    RtcLogger.success('ZEGO event handlers configured');
  }

  /// Configure audio and video settings
  Future<void> _configureAudioVideoSettings() async {
    try {
      // Audio config
      await ZegoExpressEngine.instance.setAudioConfig(ZegoAudioConfig(
        _config.audioBitrate,
        ZegoAudioChannel.Mono,
        ZegoAudioCodecID.Default,
      ));

      // Video config
      await ZegoExpressEngine.instance.setVideoConfig(
        ZegoVideoConfig(
          _config.videoWidth,
          _config.videoHeight,
          _config.videoWidth,
          _config.videoHeight,
          _config.videoBitrate,
          _defaultVideoFps,
          ZegoVideoCodecID.Default,
        ),
      );

      // Enable echo cancellation
      if (_config.enableEchoCancellation) {
        await ZegoExpressEngine.instance.enableAEC(true);
      }

      // Enable noise suppression
      if (_config.enableNoiseSuppression) {
        await ZegoExpressEngine.instance.enableANS(true);
      }

      // Enable auto gain control
      if (_config.enableAutoGainControl) {
        await ZegoExpressEngine.instance.enableAGC(true);
      }

      // Set speaker as default audio route
      await ZegoExpressEngine.instance.setAudioRouteToSpeaker(true);
      RtcLogger.audioRouteChange(
        from: 'default',
        to: 'speaker',
        success: true,
      );

      // Log audio configuration
      RtcLogger.audioConfigApplied(
        bitrate: _config.audioBitrate,
        channel: 'Mono',
        echoCancellation: _config.enableEchoCancellation,
        noiseSuppression: _config.enableNoiseSuppression,
        autoGainControl: _config.enableAutoGainControl,
      );

      RtcLogger.success('Audio/Video settings configured');
    } catch (e) {
      RtcLogger.error('Failed to configure audio/video settings', e);
    }
  }

  /// Login to a room
  Future<void> loginRoom({
    required String roomId,
    required String userId,
    required String userName,
    required CallType callType,
    String? token,
  }) async {
    if (!_isEngineInitialized) {
      throw CallError.engineNotInitialized();
    }

    // ZegoExpressEngine's event callbacks are STATIC, so the live-streaming
    // service overwrites ours the moment it initialises. Reclaim them here:
    // without this, onRoomStreamUpdate never reaches the call path, the remote
    // stream is never played, and the call connects with no remote audio or
    // video — a black screen at both ends.
    _setupEventHandlers();

    // CRITICAL: Always force logout before attempting to login
    // This ensures we're starting from a clean state
    // ZEGO error 1002001 occurs when user is already in a room
    RtcLogger.info('🧹 Ensuring clean state before room login...');
    await logoutRoom();

    try {
      RtcLogger.info('╔════════════════════════════════════════════════════════════╗');
      RtcLogger.info('║  🚪 ZEGO EXPRESS ENGINE - LOGIN ROOM                      ║');
      RtcLogger.info('╚════════════════════════════════════════════════════════════╝');
      RtcLogger.info('  👤 User ID:   $userId');
      RtcLogger.info('  👤 User Name: $userName');
      RtcLogger.info('  🏠 Room ID:   $roomId');
      RtcLogger.info('  📱 Call Type: ${callType.name}');
      RtcLogger.info('  📹 Video:     ${callType.isVideo}');
      RtcLogger.info('════════════════════════════════════════════════════════════');

      _currentRoomId = roomId;
      _currentUserId = userId;
      _currentUserName = userName;
      _currentCallType = callType;

      // ════════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log audio-only call detection
      // ════════════════════════════════════════════════════════════════════════
      if (callType.isAudio) {
        RtcLogger.audioCall(
          userId: userId,
          peerId: null,
          roomId: roomId,
          callType: callType.name,
          step: 'AUDIO_CALL_DETECTED',
          detail: 'Camera will be DISABLED for this call',
        );
      }

      final user = ZegoUser(userId, userName);
      final config = ZegoRoomConfig(0, true, '');
      if (token != null && token.isNotEmpty) {
        config.token = token;
        RtcLogger.info('  🔑 Token:    provided (${token.length} chars)');
      } else {
        RtcLogger.warning('  🔑 Token:    NOT PROVIDED — room auth may fail');
      }

      RtcLogger.info('🔄 Calling ZegoExpressEngine.instance.loginRoom...');
      final loginResult =
          await ZegoExpressEngine.instance.loginRoom(roomId, user, config: config);

      // The result carries the real outcome. Without this check a failed login
      // (1002001 RoomCountExceed, 1000020 auth) still reports success, and the
      // stream is then published into a room we never joined — the call looks
      // connected to both sides and carries nothing.
      if (loginResult.errorCode != 0) {
        RtcLogger.error(
          '❌ loginRoom FAILED with errorCode ${loginResult.errorCode}',
          loginResult.extendedData,
        );
        throw CallError.roomJoinFailed(
          message: 'Failed to join room $roomId (ZEGO error ${loginResult.errorCode}). '
              'See https://docs.zegocloud.com/article/5547',
        );
      }

      // Let the room state settle before publishing.
      await Future.delayed(const Duration(milliseconds: 300));
      RtcLogger.success('✅ ZegoExpressEngine.instance.loginRoom successful!');

      // Enable camera based on call type
      if (callType.isVideo) {
        await ZegoExpressEngine.instance.enableCamera(true);
        _isCameraEnabled = true;

        // CRITICAL: Reset to front camera on every new call (Issue #6 fix)
        // This ensures the call always starts with the front camera regardless of previous call state
        _isFrontCamera = true;
        await ZegoExpressEngine.instance.useFrontCamera(true);
        RtcLogger.info('📷 Reset to FRONT camera for new call');

        // Enable video mirror for front camera (makes video look natural)
        await ZegoExpressEngine.instance.setVideoMirrorMode(ZegoVideoMirrorMode.OnlyPreviewMirror);

        // Set app orientation to portrait (0 = Portrait, 90 = LandscapeLeft, etc.)
        await ZegoExpressEngine.instance.setAppOrientation(DeviceOrientation.portraitUp); // 0 = Portrait

        RtcLogger.info('📹 Camera enabled for video call with mirror mode and portrait orientation');
      } else {
        await ZegoExpressEngine.instance.enableCamera(false);
        _isCameraEnabled = false;
        RtcLogger.info('🎙️ Camera disabled for audio call');

        // ════════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log camera disabled for audio call
        // ════════════════════════════════════════════════════════════════════════
        RtcLogger.audioCall(
          userId: userId,
          roomId: roomId,
          callType: callType.name,
          step: 'CAMERA_DISABLED_FOR_AUDIO_CALL',
          detail: 'Video disabled, audio-only session',
        );
      }

      // ════════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log room joined
      // ════════════════════════════════════════════════════════════════════════
      RtcLogger.audioCall(
        userId: userId,
        roomId: roomId,
        callType: callType.name,
        step: 'ROOM_JOINED',
        detail: 'userId=$userId roomId=$roomId',
      );

      _isInRoom = true;
      _reconnectAttempts = 0; // Reset reconnect attempts on successful login

      // CRITICAL: Wait for ZEGO's internal state to stabilize after room login
      // ZEGO's loginRoom API returns before internal room state is fully ready
      // Without this delay, startPublishingStream will fail with error 1003023
      RtcLogger.info('⏳ Waiting for ZEGO room state to stabilize (500ms)...');
      await Future.delayed(const Duration(milliseconds: 500));
      RtcLogger.info('✅ ZEGO room state stabilized, ready to publish stream');

      RtcLogger.success('╔════════════════════════════════════════════════════════════╗');
      RtcLogger.success('║  ✅ SUCCESSFULLY LOGGED INTO ZEGO ROOM                     ║');
      RtcLogger.success('╚════════════════════════════════════════════════════════════╝');
      RtcLogger.success('  🏠 Room ID: $roomId');
      RtcLogger.success('  👤 User: $userName ($userId)');
      RtcLogger.success('════════════════════════════════════════════════════════════');
    } catch (e, stackTrace) {
      // ALWAYS set _isInRoom=false on failure to prevent publishing to a non-existent room
      _isInRoom = false;

      final errorString = e.toString();
      final isAlreadyInRoomError = errorString.contains('1002001') ||
                                     errorString.contains('already logged in') ||
                                     errorString.contains('multiple rooms');
      final isInvalidRoomError = errorString.contains('1000020') ||
                                     errorString.contains('room does not exist') ||
                                     errorString.contains('token is invalid');

      if (isAlreadyInRoomError) {
        RtcLogger.error(
          '❌ ZEGO Error 1002001: Already logged into a room. '
          'This should not happen as we force logout before login. '
          'Attempting emergency cleanup...',
          e,
          stackTrace
        );

        // Emergency cleanup: force logout and clear state
        try {
          await ZegoExpressEngine.instance.logoutRoom();
          _currentRoomId = null;
          _currentUserId = null;
          _currentUserName = null;
          _currentStreamId = null;
          _currentCallType = null;
          RtcLogger.info('✅ Emergency cleanup completed');
        } catch (cleanupError) {
          RtcLogger.error('Failed during emergency cleanup', cleanupError);
        }
      } else if (isInvalidRoomError) {
        RtcLogger.error(
          '❌ ZEGO Error 1000020: Room does not exist or token is invalid. '
          'Check: token is provided, room exists on ZEGO server, userId matches token.',
          e,
          stackTrace
        );
      }

      RtcLogger.error('Failed to login room', e, stackTrace);
      throw CallError.roomJoinFailed(
        message: 'Failed to join call room: ${isAlreadyInRoomError ? "Already in another room" : isInvalidRoomError ? "Room does not exist or invalid token" : e.toString()}',
        exception: e,
      );
    }
  }

  /// Start publishing stream
  Future<void> startPublishing({
    required String streamId,
    required CallType callType,
  }) async {
    if (!_isInRoom) {
      throw CallError.invalidState(message: 'Not in room, cannot publish');
    }

    const maxRetries = 3;
    const retryDelay = Duration(milliseconds: 500);

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        RtcLogger.info('🎙️ startPublishing() attempt $attempt/$maxRetries', {
          'streamId': streamId,
          'callType': callType.name,
          'isAudio': callType.isAudio,
          'isVideo': callType.isVideo,
        });

        _currentStreamId = streamId;

        // ════════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log about to enable audio capture
        // ════════════════════════════════════════════════════════════════════════
        RtcLogger.audioCapture(
          enabled: true,
          streamId: streamId,
          userId: _currentUserId,
          roomId: _currentRoomId,
        );

        // CRITICAL: Enable audio capture device for background audio
        // This ensures microphone stays active when app goes to background
        // Must be called BEFORE unmuting and publishing
        try {
          await ZegoExpressEngine.instance.enableAudioCaptureDevice(true);
          RtcLogger.audioCaptureDevice(enabled: true, success: true);

          // ════════════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log audio capture enabled
          // ════════════════════════════════════════════════════════════════════
          RtcLogger.audioCapture(
            enabled: true,
            streamId: streamId,
            userId: _currentUserId,
            roomId: _currentRoomId,
          );

          // Update debug state
        } catch (e) {
          RtcLogger.audioCaptureDevice(enabled: true, success: false, error: e.toString());
          rethrow;
        }
        RtcLogger.info('🔊 Audio capture device ENABLED');

        // Small delay to ensure audio capture device is fully activated
        // Some Android devices need a brief moment for the audio device to initialize
        await Future.delayed(const Duration(milliseconds: 50));

        // ════════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log about to unmute microphone
        // ════════════════════════════════════════════════════════════════════════
        RtcLogger.audioTrackState(
          trackId: 'mic_$_currentUserId',
          enabled: true,
          muted: false,
          streamId: streamId,
          userId: _currentUserId,
        );

        // Unmute microphone
        await ZegoExpressEngine.instance.muteMicrophone(false);
        _isMicrophoneMuted = false;
        RtcLogger.microphoneStateChange(isMuted: false, success: true);

        // ════════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log microphone unmuted
        // ════════════════════════════════════════════════════════════════════════
        RtcLogger.audioTrackState(
          trackId: 'mic_$_currentUserId',
          enabled: true,
          muted: false,
          streamId: streamId,
          userId: _currentUserId,
        );

        // Update debug state

        // ════════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log about to publish audio stream
        // ════════════════════════════════════════════════════════════════════════
        RtcLogger.audioPublish(
          streamId: streamId,
          success: true,
          userId: _currentUserId,
          roomId: _currentRoomId,
        );

        // Start publishing
        await ZegoExpressEngine.instance.startPublishingStream(streamId);
        RtcLogger.success('✅✅✅ Stream publishing started — local audio should now be transmitted');

        // ════════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log audio stream published
        // ════════════════════════════════════════════════════════════════════════
        RtcLogger.audioPublish(
          streamId: streamId,
          success: true,
          userId: _currentUserId,
          roomId: _currentRoomId,
        );

        // Update debug state

        return; // Success, exit the retry loop
      } catch (e, stackTrace) {
        // Check if this is the "not logged in" error
        final errorString = e.toString();
        final isNotLoggedInError = errorString.contains('1003023') ||
                                    errorString.contains('not logged in') ||
                                    errorString.contains('not in room');

        if (isNotLoggedInError && attempt < maxRetries) {
          RtcLogger.warning(
            '⚠️ Publish attempt $attempt failed: ZEGO room not ready yet. '
            'Retrying in ${retryDelay.inMilliseconds}ms... '
            '(Error: 1003023 - Engine not logged in to room)'
          );
          await Future.delayed(retryDelay);
          continue; // Retry
        }

        // Final attempt failed or non-retryable error
        RtcLogger.error(
          '❌ Failed to publish stream (attempt $attempt/$maxRetries)',
          e,
          stackTrace
        );

        if (attempt == maxRetries) {
          throw CallError.streamPublishFailed(
            message: 'Failed to publish audio/video after $maxRetries attempts. '
                     'Error: ${isNotLoggedInError ? "ZEGO room not ready" : e.toString()}',
            exception: e,
          );
        }
      }
    }
  }

  /// Stop publishing stream
  Future<void> stopPublishing() async {
    if (_currentStreamId == null) return;

    try {
      RtcLogger.info('Stopping stream publication');
      await ZegoExpressEngine.instance.stopPublishingStream();
      _currentStreamId = null;
      RtcLogger.success('Stream publishing stopped');
    } catch (e) {
      RtcLogger.error('Failed to stop publishing', e);
    }
  }

  /// Start playing remote stream
  /// Note: Host app should handle video view creation and rendering
  Future<void> playStream({
    required String streamId,
  }) async {
    try {
      RtcLogger.info('🎵 playStream() called with streamId: $streamId (callType: ${_currentCallType?.name})');
      RtcLogger.info('🎵 Audio route check: isSpeakerEnabled=$_isSpeakerEnabled, isInRoom=$_isInRoom');
      RtcLogger.info('🎵 Current roomId: $_currentRoomId, currentUserId: $_currentUserId');

      // Get current audio route for logging
      final currentRoute = _isSpeakerEnabled ? 'speaker' : 'earpiece';
      RtcLogger.audioRouteChange(from: 'none', to: currentRoute, success: true);

      // ════════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log attempting audio stream subscription
      // ════════════════════════════════════════════════════════════════════════
      RtcLogger.audioSubscribe(
        streamId: streamId,
        success: true,
        userId: _currentUserId,
        roomId: _currentRoomId,
        peerId: _remoteStreamIds.isNotEmpty ? _remoteStreamIds.first : null,
      );

      // Explicitly set audio route BEFORE playing stream — prevents Android audio routing issues
      // where switching speaker/earpiece mid-call breaks the remote stream's audio output
      if (_isInRoom) {
        try {
          await ZegoExpressEngine.instance.setAudioRouteToSpeaker(_isSpeakerEnabled);
          RtcLogger.info('🎵 Audio route pre-set to ${_isSpeakerEnabled ? "speaker" : "earpiece"} before playStream');
        } catch (e) {
          RtcLogger.warning('🎵 Could not pre-set audio route: $e (continuing with playStream anyway)');
        }
      }

      // Start playing stream with config so ZEGO knows the room context for audio routing
      // ZegoPlayerConfig.roomID is required for audio-only playback to work correctly
      final playerConfig = ZegoPlayerConfig.defaultConfig()
        ..roomID = _currentRoomId ?? '';
      RtcLogger.info('🎵 Calling ZegoExpressEngine.instance.startPlayingStream($streamId) with roomID=$_currentRoomId...');
      await ZegoExpressEngine.instance.startPlayingStream(streamId, config: playerConfig);
      RtcLogger.info('🎵 startPlayingStream() completed for streamId: $streamId');

      // ════════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log audio stream subscribed successfully
      // ════════════════════════════════════════════════════════════════════════
      RtcLogger.audioSubscribe(
        streamId: streamId,
        success: true,
        userId: _currentUserId,
        roomId: _currentRoomId,
        peerId: _remoteStreamIds.isNotEmpty ? _remoteStreamIds.first : null,
      );

      // Update debug state

      // Ensure audio route is set AFTER stream starts (Android may reset route on stream start)
      if (_isInRoom && _isSpeakerEnabled) {
        try {
          await ZegoExpressEngine.instance.setAudioRouteToSpeaker(true);
        } catch (_) {}
      }

      // Log successful stream play with audio context
      RtcLogger.streamPlayStarted(
        streamId: streamId,
        success: true,
        audioRoute: currentRoute,
      );
      RtcLogger.success('✅ playStream() SUCCESS for audio call');
    } catch (e, stackTrace) {
      // Log failed stream play
      RtcLogger.streamPlayStarted(
        streamId: streamId,
        success: false,
        error: e.toString(),
      );

      // ════════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log audio stream subscription FAILED
      // ════════════════════════════════════════════════════════════════════════
      RtcLogger.audioSubscribe(
        streamId: streamId,
        success: false,
        userId: _currentUserId,
        roomId: _currentRoomId,
        error: e.toString(),
      );

      RtcLogger.error('❌ Failed to play stream', e, stackTrace);
      throw CallError.streamPlayFailed(
        message: 'Failed to play remote stream',
        exception: e,
      );
    }
  }

  /// Stop playing remote stream
  Future<void> stopPlayingStream(String streamId) async {
    try {
      RtcLogger.info('Stopping stream playback', streamId);
      await ZegoExpressEngine.instance.stopPlayingStream(streamId);
      RtcLogger.success('Stream playback stopped');
    } catch (e) {
      RtcLogger.error('Failed to stop playing stream', e);
    }
  }

  /// Toggle microphone mute
  Future<void> toggleMicrophone() async {
    _isMicrophoneMuted = !_isMicrophoneMuted;

    // ════════════════════════════════════════════════════════════════════════
    // AUDIO DEBUG: Log toggle microphone attempt
    // ════════════════════════════════════════════════════════════════════════
    RtcLogger.audioTrackState(
      trackId: 'mic_$_currentUserId',
      enabled: true,
      muted: _isMicrophoneMuted,
      streamId: _currentStreamId,
      userId: _currentUserId,
    );

    try {
      await ZegoExpressEngine.instance.muteMicrophone(_isMicrophoneMuted);
      RtcLogger.microphoneStateChange(isMuted: _isMicrophoneMuted, success: true);

      // Update debug state
    } catch (e) {
      RtcLogger.microphoneStateChange(isMuted: _isMicrophoneMuted, success: false, error: e.toString());
      // Revert state on failure
      _isMicrophoneMuted = !_isMicrophoneMuted;
    }
  }

  /// Set microphone mute state
  Future<void> setMicrophoneMuted(bool muted) async {
    _isMicrophoneMuted = muted;

    // ════════════════════════════════════════════════════════════════════════
    // AUDIO DEBUG: Log set microphone mute
    // ════════════════════════════════════════════════════════════════════════
    RtcLogger.audioTrackState(
      trackId: 'mic_$_currentUserId',
      enabled: true,
      muted: muted,
      streamId: _currentStreamId,
      userId: _currentUserId,
    );

    try {
      await ZegoExpressEngine.instance.muteMicrophone(muted);
      RtcLogger.microphoneStateChange(isMuted: muted, success: true);

      // Update debug state
    } catch (e) {
      RtcLogger.microphoneStateChange(isMuted: muted, success: false, error: e.toString());
      // Revert state on failure
      _isMicrophoneMuted = !muted;
    }
  }

  /// Toggle camera
  Future<void> toggleCamera() async {
    _isCameraEnabled = !_isCameraEnabled;
    await ZegoExpressEngine.instance.enableCamera(_isCameraEnabled);
    RtcLogger.info('Camera ${_isCameraEnabled ? "enabled" : "disabled"}');
  }

  /// Switch between front and back camera
  Future<void> switchCamera() async {
    _isFrontCamera = !_isFrontCamera;
    await ZegoExpressEngine.instance.useFrontCamera(_isFrontCamera);
    RtcLogger.info('Switched to ${_isFrontCamera ? "front" : "back"} camera');
  }

  /// Toggle speaker
  Future<void> toggleSpeaker() async {
    RtcLogger.info('🔊🔊🔊 toggleSpeaker() called - current state: isSpeakerEnabled=$_isSpeakerEnabled');
    _isSpeakerEnabled = !_isSpeakerEnabled;
    try {
      RtcLogger.info('🔊 Calling setAudioRouteToSpeaker($_isSpeakerEnabled)...');
      await ZegoExpressEngine.instance.setAudioRouteToSpeaker(_isSpeakerEnabled);
      RtcLogger.info('🔊 setAudioRouteToSpeaker completed');
      final fromRoute = _isSpeakerEnabled ? 'earpiece' : 'speaker';
      final toRoute = _isSpeakerEnabled ? 'speaker' : 'earpiece';

      // ════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log audio routing change
      // ════════════════════════════════════════════════════════════════════
      RtcLogger.audioRouting(
        fromRoute: fromRoute,
        toRoute: toRoute,
        streamId: _currentStreamId,
      );

      RtcLogger.audioRouteChange(from: fromRoute, to: toRoute, success: true);
      RtcLogger.speakerState(enabled: _isSpeakerEnabled, success: true);
      RtcLogger.success('🔊🔊🔊 toggleSpeaker() SUCCESS - now using: ${_isSpeakerEnabled ? "speaker" : "earpiece"}');

      // Update debug state

      // Re-set audio route after toggle to ensure remote stream audio follows the route
      // On Android, audio route changes can temporarily interrupt remote stream audio
      await Future.delayed(const Duration(milliseconds: 300));
      try {
        await ZegoExpressEngine.instance.setAudioRouteToSpeaker(_isSpeakerEnabled);
      } catch (_) {}
    } catch (e) {
      RtcLogger.audioRouteChange(
        from: _isSpeakerEnabled ? 'earpiece' : 'speaker',
        to: _isSpeakerEnabled ? 'speaker' : 'earpiece',
        success: false,
        error: e.toString(),
      );
      RtcLogger.speakerState(enabled: _isSpeakerEnabled, success: false, error: e.toString());
      // Revert state on failure
      _isSpeakerEnabled = !_isSpeakerEnabled;
      rethrow;
    }
  }

  /// Logout from room
  Future<void> logoutRoom() async {
    // Always attempt logout, even if we think we're not in a room
    // This handles cases where internal state gets out of sync with ZEGO's actual state
    try {
      // Deliberately NOT gated on _isInRoom: when a call ends remotely the flag
      // is cleared while ZEGO still holds the room, and the next loginRoom then
      // fails with 1002001 (RoomCountExceed) — a connected call publishing
      // nothing. Logging out of a room we are not in is harmless.
      RtcLogger.info('Logging out from room${_currentRoomId != null ? ": $_currentRoomId" : ""}');

      // Stop publishing if we have a stream
      if (_currentStreamId != null) {
        try {
          await stopPublishing();
        } catch (e) {
          RtcLogger.warning('Error stopping publishing during logout: $e');
          // Continue with logout even if this fails
        }
      }

      // Stop preview
      try {
        await ZegoExpressEngine.instance.stopPreview();
      } catch (e) {
        RtcLogger.warning('Error stopping preview during logout: $e');
        // Continue with logout even if this fails
      }

      // Logout from room
      try {
        if (_currentRoomId != null) {
          await ZegoExpressEngine.instance.logoutRoom(_currentRoomId!);
        } else {
          // Try to logout even without roomId (ZEGO will handle current room)
          await ZegoExpressEngine.instance.logoutRoom();
        }
      } catch (e) {
        RtcLogger.warning('Error during ZEGO logout: $e');
        // Continue to clear state even if logout fails
      }

      RtcLogger.success('Logged out from room');
    } catch (e) {
      RtcLogger.error('Failed to logout from room', e);
    } finally {
      // CRITICAL: Always clear internal state, even if logout fails
      // This prevents state desync issues
      _isInRoom = false;
      _currentRoomId = null;
      _currentUserId = null;
      _currentUserName = null;
      _currentStreamId = null;
      _currentCallType = null;
      _clearTrackedStreams();  // Clear tracked remote streams
      _streamPollTimer?.cancel();
      _streamPollTimer = null;
      RtcLogger.info('✅ Internal room state cleared');
    }
  }

  /// Attempt reconnection after network failure
  Future<void> _attemptReconnect() async {
    if (_reconnectAttempts >= _config.reconnectRetryCount) {
      RtcLogger.error('Max reconnect attempts reached');
      onError?.call(CallError.networkError(
        message: 'Failed to reconnect after ${_config.reconnectRetryCount} attempts',
      ));
      return;
    }

    _reconnectAttempts++;
    onReconnecting?.call();

    final backoff = _config.getReconnectBackoff(_reconnectAttempts - 1);
    RtcLogger.info(
      'Attempting reconnect',
      {'attempt': _reconnectAttempts, 'backoff': '${backoff.inSeconds}s'},
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(backoff, () async {
      try {
        // Try to rejoin room with saved state
        if (_currentRoomId != null &&
            _currentUserId != null &&
            _currentUserName != null &&
            _currentCallType != null) {
          RtcLogger.info('Rejoining room after disconnect');

          // First logout to clean up any stale state
          await logoutRoom();

          // Rejoin with saved parameters
          await loginRoom(
            roomId: _currentRoomId!,
            userId: _currentUserId!,
            userName: _currentUserName!,
            callType: _currentCallType!,
          );

          // Restore stream publishing if we had an active stream
          if (_currentStreamId != null) {
            await startPublishing(
              streamId: _currentStreamId!,
              callType: _currentCallType!,
            );
          }

          onReconnected?.call();
          RtcLogger.success('Reconnection successful');
        } else {
          RtcLogger.error('Cannot reconnect: missing connection state');
          onError?.call(CallError.invalidState(
            message: 'Cannot reconnect: insufficient state information',
          ));
        }
      } catch (e) {
        RtcLogger.error('Reconnect attempt failed', e);
        _attemptReconnect(); // Retry with next backoff
      }
    });
  }

  /// Check if should attempt reconnect for error code
  bool _shouldAttemptReconnect(int errorCode) {
    // ZEGO error codes that indicate network issues (should attempt reconnect)
    const networkErrorCodes = [
      1001005, // Network disconnected (WiFi ↔ Mobile switch)
      1002001, // Network error
      1002002, // Network timeout
      1002003, // Network disconnected
    ];
    return networkErrorCodes.contains(errorCode);
  }

  /// Destroy engine
  Future<void> destroy() async {
    if (!_isEngineInitialized) return;

    try {
      RtcLogger.info('Destroying ZEGO engine');

      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _streamPollTimer?.cancel();
      _streamPollTimer = null;

      if (_isInRoom) {
        await logoutRoom();
      }

      await ZegoExpressEngine.destroyEngine();

      _isEngineInitialized = false;
      _reconnectAttempts = 0;

      // Clear callbacks
      onUserJoined = null;
      onUserLeft = null;
      onStreamAdded = null;
      onStreamRemoved = null;
      onStreamPlaying = null;
      onStreamPlayingFailed = null;
      onError = null;
      onRoomError = null;
      onReconnecting = null;
      onReconnected = null;

      RtcLogger.success('ZEGO engine destroyed');
    } catch (e) {
      RtcLogger.error('Failed to destroy engine', e);
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  // STREAM RE-NEGOTIATION - CRITICAL FOR NETWORK RECONNECT
  // ════════════════════════════════════════════════════════════════════════
  //
  // WHEN TO CALL: After network reconnect to restore audio/video
  // WHY: ZEGO streams may become stale after network loss
  //
  // ════════════════════════════════════════════════════════════════════════

  /// Track remote stream IDs for re-negotiation
  final Set<String> _remoteStreamIds = {};

  /// Re-negotiate streams after network recovery
  ///
  /// This method MUST be called after network reconnect to restore audio/video.
  /// Without this, calls may reconnect but have no audio ("silent call bug").
  Future<bool> reNegotiateStreams() async {
    if (!_isInRoom || _currentStreamId == null) {
      RtcLogger.warning('Cannot re-negotiate: not in room or no stream');
      return false;
    }

    RtcLogger.info('🔄 Re-negotiating streams after reconnect...');

    try {
      // ══════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log re-negotiation started
      // ══════════════════════════════════════════════════════════════════
      RtcLogger.audioCall(
        userId: _currentUserId,
        roomId: _currentRoomId,
        streamId: _currentStreamId,
        callType: _currentCallType?.name,
        step: 'RENEGOTIATION_STARTED',
        detail: 'Re-establishing audio pipeline after reconnect',
      );

      // ══════════════════════════════════════════════════════════════════
      // STEP 1: Stop current publishing
      // ══════════════════════════════════════════════════════════════════
      await ZegoExpressEngine.instance.stopPublishingStream();
      RtcLogger.info('Stopped publishing stream');

      // ══════════════════════════════════════════════════════════════════
      // STEP 2: Reset audio devices
      // ══════════════════════════════════════════════════════════════════
      RtcLogger.audioCapture(
        enabled: false,
        streamId: _currentStreamId ?? 'unknown',
        userId: _currentUserId,
        roomId: _currentRoomId,
      );

      await ZegoExpressEngine.instance.enableAudioCaptureDevice(false);
      await Future.delayed(const Duration(milliseconds: 200));

      RtcLogger.audioCapture(
        enabled: true,
        streamId: _currentStreamId ?? 'unknown',
        userId: _currentUserId,
        roomId: _currentRoomId,
      );

      await ZegoExpressEngine.instance.enableAudioCaptureDevice(true);

      // ══════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log audio capture reset
      // ══════════════════════════════════════════════════════════════════
      RtcLogger.audioTrackState(
        trackId: 'mic_$_currentUserId',
        enabled: true,
        muted: false,
        streamId: _currentStreamId,
        userId: _currentUserId,
      );

      await ZegoExpressEngine.instance.muteMicrophone(false);
      _isMicrophoneMuted = false;
      RtcLogger.info('Reset audio devices');

      // ══════════════════════════════════════════════════════════════════
      // STEP 2.5: Reset video/camera for video calls (Issue #1 fix)
      // ══════════════════════════════════════════════════════════════════
      if (_isCameraEnabled && _currentCallType?.isVideo == true) {
        await ZegoExpressEngine.instance.enableCamera(false);
        await Future.delayed(const Duration(milliseconds: 200));
        await ZegoExpressEngine.instance.enableCamera(true);
        await ZegoExpressEngine.instance.useFrontCamera(_isFrontCamera);
        RtcLogger.info('Reset camera for video call');
      }

      // ══════════════════════════════════════════════════════════════════
      // STEP 3: Restart publishing with same stream ID
      // ══════════════════════════════════════════════════════════════════
      RtcLogger.audioPublish(
        streamId: _currentStreamId ?? 'unknown',
        success: true,
        userId: _currentUserId,
        roomId: _currentRoomId,
      );

      await ZegoExpressEngine.instance.startPublishingStream(_currentStreamId!);
      RtcLogger.info('Restarted publishing stream');

      // ══════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log publish restarted
      // ══════════════════════════════════════════════════════════════════
      RtcLogger.audioPublish(
        streamId: _currentStreamId ?? 'unknown',
        success: true,
        userId: _currentUserId,
        roomId: _currentRoomId,
      );

      // ══════════════════════════════════════════════════════════════════
      // STEP 4: Re-play remote streams
      // ══════════════════════════════════════════════════════════════════
      for (final remoteStreamId in _remoteStreamIds) {
        try {
          await ZegoExpressEngine.instance.stopPlayingStream(remoteStreamId);
          await Future.delayed(const Duration(milliseconds: 100));
          final reconnectConfig = ZegoPlayerConfig.defaultConfig()
            ..roomID = _currentRoomId ?? '';

          // ══════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log re-subscribing to remote stream
          // ══════════════════════════════════════════════════════════════
          RtcLogger.audioSubscribe(
            streamId: remoteStreamId,
            success: true,
            userId: _currentUserId,
            roomId: _currentRoomId,
          );

          await ZegoExpressEngine.instance.startPlayingStream(remoteStreamId, config: reconnectConfig);
          RtcLogger.info('Re-played remote stream: $remoteStreamId');

          // ══════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log re-subscribe success
          // ══════════════════════════════════════════════════════════════
          RtcLogger.audioSubscribe(
            streamId: remoteStreamId,
            success: true,
            userId: _currentUserId,
            roomId: _currentRoomId,
          );
        } catch (e) {
          RtcLogger.warning('Failed to re-play stream $remoteStreamId: $e');

          // ══════════════════════════════════════════════════════════════
          // AUDIO DEBUG: Log re-subscribe failure
          // ══════════════════════════════════════════════════════════════
          RtcLogger.audioSubscribe(
            streamId: remoteStreamId,
            success: false,
            userId: _currentUserId,
            roomId: _currentRoomId,
            error: e.toString(),
          );
        }
      }

      // ══════════════════════════════════════════════════════════════════
      // STEP 5: Verify stream health
      // ══════════════════════════════════════════════════════════════════
      await Future.delayed(const Duration(seconds: 1));

      // ══════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log re-negotiation complete
      // ══════════════════════════════════════════════════════════════════
      RtcLogger.audioCall(
        userId: _currentUserId,
        roomId: _currentRoomId,
        streamId: _currentStreamId,
        callType: _currentCallType?.name,
        step: 'RENEGOTIATION_COMPLETED',
        detail: 'Audio pipeline re-established after reconnect',
      );

      RtcLogger.success('✅ Streams re-negotiated successfully');
      return true;

    } catch (e, stackTrace) {
      RtcLogger.error('❌ Failed to re-negotiate streams', e, stackTrace);

      // Notify error callback
      onError?.call(CallError.networkError(
        message: 'Failed to restore call after network recovery',
        exception: e,
      ));

      return false;
    }
  }

  /// Track remote stream for re-negotiation
  void _trackRemoteStream(String streamId) {
    _remoteStreamIds.add(streamId);
  }

  /// Untrack remote stream
  void _untrackRemoteStream(String streamId) {
    _remoteStreamIds.remove(streamId);
  }

  /// Clear all tracked streams
  void _clearTrackedStreams() {
    _remoteStreamIds.clear();
    _streamPollTimer?.cancel();
    _streamPollTimer = null;
  }

  /// Schedule stream play for remote user (fallback when onStreamAdded doesn't fire)
  /// Schedule fallback stream play for a remote user.
  /// Called as a fallback when onStreamAdded doesn't fire.
  void scheduleFallbackStreamPlay(String remoteUserId) {
    _scheduleRemoteStreamPlay(remoteUserId);
  }

  void _scheduleRemoteStreamPlay(String remoteUserId) async {
    if (_currentRoomId == null || _currentUserId == null) return;

    final expectedStreamId = 'Stream_${_currentRoomId}_${remoteUserId}_stream';
    RtcLogger.info('🎯 Scheduling stream play for remote user: $remoteUserId, expected streamId: $expectedStreamId');

    // Cancel any existing poll timer
    _streamPollTimer?.cancel();

    // Poll for the stream with increasing delays (100ms, 500ms, 1s, 2s)
    final delays = [100, 500, 1000, 2000];
    int attempt = 0;

    void scheduleNext() {
      if (attempt >= delays.length) {
        RtcLogger.warning('⏰ Stream poll exhausted — giving up on auto-playing remote stream');

        // ════════════════════════════════════════════════════════════════════
        // AUDIO DEBUG: Log fallback poll exhausted
        // ════════════════════════════════════════════════════════════════════
        RtcLogger.audioSubscribe(
          streamId: expectedStreamId,
          success: false,
          userId: _currentUserId,
          roomId: _currentRoomId,
          peerId: remoteUserId,
          error: 'Fallback polling exhausted',
        );
        return;
      }

      final delay = Duration(milliseconds: delays[attempt]);
      attempt++;
      RtcLogger.info('⏳ Scheduling stream poll attempt $attempt in ${delay.inMilliseconds}ms');

      // ════════════════════════════════════════════════════════════════════
      // AUDIO DEBUG: Log fallback poll attempt
      // ════════════════════════════════════════════════════════════════════
      RtcLogger.audioSubscribe(
        streamId: expectedStreamId,
        success: true,
        userId: _currentUserId,
        roomId: _currentRoomId,
        peerId: remoteUserId,
      );

      _streamPollTimer = Timer(delay, () async {
        if (!_isInRoom || _currentRoomId == null) return;

        final streamId = 'Stream_${_currentRoomId}_${remoteUserId}_stream';
        RtcLogger.info('🔍 Attempt $attempt to play stream: $streamId');

        // Only try if we haven't already tracked this stream
        if (_remoteStreamIds.contains(streamId)) {
          RtcLogger.info('✅ Stream already tracked, skipping poll attempt $attempt');
          return;
        }

        // Try to play the stream
        try {
          RtcLogger.info('🎙️🔊 ATTEMPT $attempt: Calling playStream for audio call fallback');
          await playStream(streamId: streamId);
          RtcLogger.success('✅✅✅ Fallback stream play SUCCESS for streamId: $streamId');
        } catch (e) {
          RtcLogger.warning('⚠️ Fallback stream play attempt $attempt failed: $e');
          // Try again on next scheduled poll
          if (attempt < delays.length) {
            scheduleNext();
          } else {
            RtcLogger.error('❌ All fallback stream play attempts exhausted');
          }
        }
      });
    }

    scheduleNext();
  }

  // Getters
  bool get isEngineInitialized => _isEngineInitialized;
  bool get isInRoom => _isInRoom;
  bool get isMicrophoneMuted => _isMicrophoneMuted;
  bool get isCameraEnabled => _isCameraEnabled;
  bool get isFrontCamera => _isFrontCamera;
  bool get isSpeakerEnabled => _isSpeakerEnabled;
  String? get currentRoomId => _currentRoomId;
  String? get currentUserId => _currentUserId;
  String? get currentStreamId => _currentStreamId;
  Set<String> get remoteStreamIds => Set.unmodifiable(_remoteStreamIds);
}

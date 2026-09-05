// Import statements must come first
import '../../adapters/signaling_mapper.dart';
import '../../config/rtc_call_config.dart';
import '../../native_callkit/native_callkit_config.dart' as native;

/// Configuration for the communication service
class CommunicationConfig {
  /// ZEGO configuration
  final ZegoConfig zegoConfig;

  /// Socket configuration
  final SocketConfig socketConfig;

  /// CallKit configuration (iOS/Android)
  final CallKitConfig? callKitConfig;

  /// Enable native CallKit UI
  /// When true: Native CallKit handles incoming call UI
  /// When false: App handles UI using callbacks (onIncomingCall, etc.)
  /// Default: true (use CallKit if config is provided)
  final bool useCallKit;

  /// Custom signaling mapper for your backend
  /// If not provided, uses DefaultSignalingMapper
  final SignalingMapper? signalingMapper;

  /// Enable debug logging
  final bool enableLogging;

  /// Log level
  final LogLevel logLevel;

  const CommunicationConfig({
    required this.zegoConfig,
    required this.socketConfig,
    this.callKitConfig,
    this.useCallKit = true,
    this.signalingMapper,
    this.enableLogging = true,
    this.logLevel = LogLevel.info,
  });

  /// Convert to internal RtcCallConfig
  RtcCallConfig get rtcCallConfig {
    return RtcCallConfig(
      enableLogs: enableLogging,
      ringingTimeout: callKitConfig?.timeout ?? const Duration(seconds: 30),
      videoBitrate: zegoConfig.videoBitrate,
      videoWidth: zegoConfig.videoWidth,
      videoHeight: zegoConfig.videoHeight,
    );
  }
}

/// ZEGO Express SDK configuration
class ZegoConfig {
  /// ZEGO App ID
  final int appId;

  /// ZEGO App Sign
  final String appSign;

  /// ZEGO Server URL (optional)
  final String? serverUrl;

  /// Enable hardware encoder
  final bool enableHardwareEncoder;

  /// Enable hardware decoder
  final bool enableHardwareDecoder;

  /// Video bitrate in kbps (default: 2000 for HD quality)
  final int videoBitrate;

  /// Video resolution width (default: 720 for portrait HD)
  /// For portrait video calls (most mobile apps), use 720x1280
  /// For landscape video calls, use 1280x720
  final int videoWidth;

  /// Video resolution height (default: 1280 for portrait HD)
  /// For portrait video calls (most mobile apps), use 720x1280
  /// For landscape video calls, use 1280x720
  final int videoHeight;

  const ZegoConfig({
    required this.appId,
    required this.appSign,
    this.serverUrl,
    this.enableHardwareEncoder = true,
    this.enableHardwareDecoder = true,
    this.videoBitrate = 2000,
    this.videoWidth = 720,  // Portrait width (matches phone screens in portrait mode)
    this.videoHeight = 1280, // Portrait height (matches phone screens in portrait mode)
  });
}

/// Socket.io configuration
class SocketConfig {
  /// Socket server URL
  final String url;

  /// Reconnection delay
  final Duration reconnectDelay;

  /// Maximum reconnection attempts (0 = infinite)
  final int maxReconnectAttempts;

  /// Additional headers for socket connection
  final Map<String, String>? headers;

  /// Connection timeout
  final Duration connectionTimeout;

  const SocketConfig({
    required this.url,
    this.reconnectDelay = const Duration(seconds: 5),
    this.maxReconnectAttempts = 5,
    this.headers,
    this.connectionTimeout = const Duration(seconds: 10),
  });
}

/// CallKit configuration for native call UI
class CallKitConfig {
  /// App name to show in CallKit
  final String appName;

  /// Icon name (from assets)
  final String iconName;

  /// Ringtone sound file name
  final String ringtoneSound;

  /// Call timeout duration
  final Duration timeout;

  /// Support video calls
  final bool supportsVideo;

  /// Maximum call groups (iOS)
  final int maximumCallGroups;

  /// Maximum calls per group (iOS)
  final int maximumCallsPerCallGroup;

  const CallKitConfig({
    required this.appName,
    this.iconName = 'CallKitLogo',
    this.ringtoneSound = 'system_ring',
    this.timeout = const Duration(seconds: 30),
    this.supportsVideo = true,
    this.maximumCallGroups = 1,
    this.maximumCallsPerCallGroup = 1,
  });

  /// Convert to internal NativeCallKitConfig
  native.NativeCallKitConfig toNativeCallKitConfig() {
    return native.NativeCallKitConfig(
      appName: appName,
      ringDuration: timeout,
      callTimeout: timeout,
      iosIconName: iconName,
      iosRingtone: ringtoneSound,
      androidRingtone: ringtoneSound,
    );
  }
}

/// Log levels
enum LogLevel {
  verbose,
  debug,
  info,
  warning,
  error,
  none,
}

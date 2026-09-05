/// Log level for RTC diagnostics
enum RtcLogLevel {
  /// All logs including ZEGO internal events
  verbose,

  /// Standard flow logs (default for production)
  info,

  /// Only warnings and errors
  warning,

  /// Only errors
  error,
}

/// Configuration for RTC call behavior
/// Allows customization of timeouts, retries, and other call parameters
class RtcCallConfig {
  /// Timeout duration for ringing calls (default: 30 seconds)
  /// If call is not accepted within this duration, it will be auto-cancelled
  final Duration ringingTimeout;

  /// Number of retry attempts for reconnection (default: 5)
  final int reconnectRetryCount;

  /// Initial backoff duration for reconnection (default: 2 seconds)
  /// Uses exponential backoff: 2s, 4s, 8s, 16s, 32s
  final Duration reconnectBackoff;

  /// Maximum backoff duration for reconnection (default: 30 seconds)
  final Duration maxReconnectBackoff;

  /// Enable debug logging (default: true)
  /// IMPORTANT: Should be ENABLED in production for audio debugging visibility
  final bool enableLogs;

  /// Log level for fine-grained control (default: info)
  /// - verbose: all logs including ZEGO internal events
  /// - info: standard flow logs
  /// - warning: only warnings and errors
  /// - error: only errors
  final RtcLogLevel logLevel;




  /// Audio bitrate in kbps (default: 48)
  final int audioBitrate;

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

  /// Enable echo cancellation (default: true)
  final bool enableEchoCancellation;

  /// Enable noise suppression (default: true)
  final bool enableNoiseSuppression;

  /// Enable auto gain control (default: true)
  final bool enableAutoGainControl;

  /// Enable comprehensive audio call debugging
  /// When true, logs detailed audio pipeline state including track creation,
  /// permission status, device routing, signaling, and stream state
  final bool enableAudioDebug;

  /// Enable audio debug logs even in production (default: debug-only)
  /// When false (default), audio debug logs are suppressed in release builds
  /// Use this to troubleshoot production audio issues
  final bool audioDebugInProduction;

  const RtcCallConfig({
    this.ringingTimeout = const Duration(seconds: 30),
    this.reconnectRetryCount = 5,
    this.reconnectBackoff = const Duration(seconds: 2),
    this.maxReconnectBackoff = const Duration(seconds: 30),
    this.enableLogs = true,  // Changed: Logging ENABLED by default for production diagnostics
    this.logLevel = RtcLogLevel.info,  // Default to info level
    this.audioBitrate = 48,
    this.videoBitrate = 2000, // HD quality bitrate
    this.videoWidth = 720,   // Portrait HD width (matches phone screens)
    this.videoHeight = 1280, // Portrait HD height (matches phone screens)
    this.enableEchoCancellation = true,
    this.enableNoiseSuppression = true,
    this.enableAutoGainControl = true,
    this.enableAudioDebug = false,
    this.audioDebugInProduction = false,
  });

  /// Create a development configuration with verbose logging
  factory RtcCallConfig.development() {
    return const RtcCallConfig(
      enableLogs: true,
      logLevel: RtcLogLevel.verbose,  // All ZEGO internal events
      ringingTimeout: Duration(seconds: 60), // Longer timeout for testing
    );
  }

  /// Create a production configuration with optimal settings
  /// NOTE: Logging is ENABLED by default for audio debugging
  factory RtcCallConfig.production() {
    return const RtcCallConfig(
      enableLogs: true,  // Keep enabled for production diagnostics
      logLevel: RtcLogLevel.info,  // Standard flow logs
      ringingTimeout: Duration(seconds: 30),
      reconnectRetryCount: 5,
    );
  }

  /// Create a copy with updated fields
  RtcCallConfig copyWith({
    Duration? ringingTimeout,
    int? reconnectRetryCount,
    Duration? reconnectBackoff,
    Duration? maxReconnectBackoff,
    bool? enableLogs,
    RtcLogLevel? logLevel,
    int? audioBitrate,
    int? videoBitrate,
    int? videoWidth,
    int? videoHeight,
    bool? enableEchoCancellation,
    bool? enableNoiseSuppression,
    bool? enableAutoGainControl,
    bool? enableAudioDebug,
    bool? audioDebugInProduction,
  }) {
    return RtcCallConfig(
      ringingTimeout: ringingTimeout ?? this.ringingTimeout,
      reconnectRetryCount: reconnectRetryCount ?? this.reconnectRetryCount,
      reconnectBackoff: reconnectBackoff ?? this.reconnectBackoff,
      maxReconnectBackoff: maxReconnectBackoff ?? this.maxReconnectBackoff,
      enableLogs: enableLogs ?? this.enableLogs,
      logLevel: logLevel ?? this.logLevel,
      audioBitrate: audioBitrate ?? this.audioBitrate,
      videoBitrate: videoBitrate ?? this.videoBitrate,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      enableEchoCancellation: enableEchoCancellation ?? this.enableEchoCancellation,
      enableNoiseSuppression: enableNoiseSuppression ?? this.enableNoiseSuppression,
      enableAutoGainControl: enableAutoGainControl ?? this.enableAutoGainControl,
      enableAudioDebug: enableAudioDebug ?? this.enableAudioDebug,
      audioDebugInProduction: audioDebugInProduction ?? this.audioDebugInProduction,
    );
  }

  /// Calculate exponential backoff duration for given attempt
  Duration getReconnectBackoff(int attempt) {
    final backoffSeconds = reconnectBackoff.inSeconds * (1 << attempt);
    final cappedSeconds = backoffSeconds.clamp(
      reconnectBackoff.inSeconds,
      maxReconnectBackoff.inSeconds,
    );
    return Duration(seconds: cappedSeconds);
  }

  @override
  String toString() {
    return 'RtcCallConfig('
        'ringingTimeout: ${ringingTimeout.inSeconds}s, '
        'reconnectRetryCount: $reconnectRetryCount, '
        'enableLogs: $enableLogs, '
        'logLevel: ${logLevel.name}'
        ')';
  }
}

/// Configuration for native CallKit integration
///
/// Controls how the native CallKit UI appears on iOS and Android.
class NativeCallKitConfig {
  /// App name shown in CallKit UI
  final String appName;

  /// Text for accept button (default: "Accept")
  final String acceptText;

  /// Text for decline button (default: "Decline")
  final String declineText;

  /// How long to ring before timing out (default: 30 seconds)
  final Duration ringDuration;

  /// Call timeout duration (default: 60 seconds)
  final Duration callTimeout;

  /// Show app logo in Android notification (default: true)
  final bool showLogo;

  // Android-specific settings
  final String androidRingtone;
  final String androidBackgroundColor;
  final String androidActionColor;
  final String androidTextColor;
  final String androidChannelName;

  // iOS-specific settings (DEPRECATED - not used anymore)
  @Deprecated('iconName is no longer used - iOS will use default app icon')
  final String iosIconName;
  final String? iosRingtone;

  const NativeCallKitConfig({
    required this.appName,
    this.acceptText = 'Accept',
    this.declineText = 'Decline',
    this.ringDuration = const Duration(seconds: 30),
    this.callTimeout = const Duration(seconds: 60),
    this.showLogo = true,
    this.androidRingtone = 'system_ringtone_default',
    this.androidBackgroundColor = '#0955fa',
    this.androidActionColor = '#4CAF50',
    this.androidTextColor = '#ffffff',
    this.androidChannelName = 'Incoming Call',
    this.iosIconName = '', // Deprecated - not used
    this.iosRingtone = 'system_ringtone_default',
  });

  /// Development preset with sensible defaults
  factory NativeCallKitConfig.development({required String appName}) {
    return NativeCallKitConfig(
      appName: appName,
      ringDuration: const Duration(seconds: 30),
      callTimeout: const Duration(seconds: 60),
    );
  }

  /// Production preset with longer timeouts
  factory NativeCallKitConfig.production({required String appName}) {
    return NativeCallKitConfig(
      appName: appName,
      ringDuration: const Duration(seconds: 45),
      callTimeout: const Duration(minutes: 2),
    );
  }

  /// Create a copy with modified fields
  NativeCallKitConfig copyWith({
    String? appName,
    String? acceptText,
    String? declineText,
    Duration? ringDuration,
    Duration? callTimeout,
    bool? showLogo,
    String? androidRingtone,
    String? androidBackgroundColor,
    String? androidActionColor,
    String? androidTextColor,
    String? androidChannelName,
    String? iosIconName,
    String? iosRingtone,
  }) {
    return NativeCallKitConfig(
      appName: appName ?? this.appName,
      acceptText: acceptText ?? this.acceptText,
      declineText: declineText ?? this.declineText,
      ringDuration: ringDuration ?? this.ringDuration,
      callTimeout: callTimeout ?? this.callTimeout,
      showLogo: showLogo ?? this.showLogo,
      androidRingtone: androidRingtone ?? this.androidRingtone,
      androidBackgroundColor: androidBackgroundColor ?? this.androidBackgroundColor,
      androidActionColor: androidActionColor ?? this.androidActionColor,
      androidTextColor: androidTextColor ?? this.androidTextColor,
      androidChannelName: androidChannelName ?? this.androidChannelName,
      iosIconName: iosIconName ?? this.iosIconName,
      iosRingtone: iosRingtone ?? this.iosRingtone,
    );
  }
}

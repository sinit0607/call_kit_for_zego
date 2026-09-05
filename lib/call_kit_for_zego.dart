/// RTC Call Kit - A comprehensive Flutter package for real-time audio/video calling
///
/// This package provides:
/// - Audio and video calling using ZEGOCLOUD
/// - Native CallKit integration for iOS and Android
/// - Socket-based signaling abstraction
/// - Network reconnection with exponential backoff
/// - State machine for call lifecycle management
///
/// ## Quick Start
///
/// ```dart
/// // 1. Initialize the service
/// final rtcService = RtcCommunicationService();
/// await rtcService.initialize(
///   config: CommunicationConfig(
///     zego: ZegoConfig(appId: YOUR_APP_ID, appSign: 'YOUR_APP_SIGN'),
///     callKit: CallKitConfig(appName: 'Your App'),
///   ),
///   socketAdapter: YourSocketAdapter(),
/// );
///
/// // 2. Set current user
/// rtcService.setCurrentUser(UserInfo(userId: 'user123', userName: 'John'));
///
/// // 3. Listen to events
/// rtcService.callEvents.listen((event) {
///   // Handle call events
/// });
///
/// // 4. Make a call
/// await rtcService.startCall(
///   calleeId: 'user456',
///   calleeName: 'Jane',
///   callType: CallType.video,
/// );
/// ```
library call_kit_for_zego;

// ════════════════════════════════════════════════════════════════════════════
// PUBLIC API - Main Service
// ════════════════════════════════════════════════════════════════════════════
export 'src/api/rtc_communication_service.dart';
export 'src/controllers/rtc_live_controller.dart';

// ════════════════════════════════════════════════════════════════════════════
// PUBLIC API - Configuration
// ════════════════════════════════════════════════════════════════════════════
export 'src/api/models/communication_config.dart';
export 'src/config/rtc_call_config.dart';
export 'src/native_callkit/native_callkit_config.dart';

// ════════════════════════════════════════════════════════════════════════════
// PUBLIC API - Models
// ════════════════════════════════════════════════════════════════════════════
export 'src/api/models/call_event.dart';
export 'src/api/models/chat_event.dart';
export 'src/api/models/chat_message.dart';
export 'src/api/models/user_info.dart';
export 'src/api/models/communication_error.dart';

export 'src/models/call_data.dart';
export 'src/models/call_state.dart';
export 'src/models/call_type.dart';
export 'src/models/call_user.dart';
export 'src/models/call_end_reason.dart';
export 'src/models/call_error.dart';
export 'src/models/live_stream_data.dart';
export 'src/models/live_stream_type.dart';

// ════════════════════════════════════════════════════════════════════════════
// PUBLIC API - Adapters (for integration)
// ════════════════════════════════════════════════════════════════════════════
export 'src/adapters/socket_adapter.dart';
export 'src/adapters/signaling_mapper.dart';

// ════════════════════════════════════════════════════════════════════════════
// PUBLIC API - Signaling
// ════════════════════════════════════════════════════════════════════════════
export 'src/signaling/rtc_signaling_event.dart';

// ════════════════════════════════════════════════════════════════════════════
// PUBLIC API - Widgets
// ════════════════════════════════════════════════════════════════════════════
export 'src/widgets/rtc_video_view.dart';
export 'src/widgets/chat_screen.dart';

// Re-export ZEGOCLOUD types needed for live streaming callbacks
export 'package:zego_express_engine/zego_express_engine.dart'
  show ZegoViewMode, ZegoUpdateType, ZegoPlayerState, ZegoStream, ZegoUser;

// ════════════════════════════════════════════════════════════════════════════
// PUBLIC API - Plugins (Optional integrations)
// ════════════════════════════════════════════════════════════════════════════
export 'src/plugins/analytics_plugin.dart';
export 'src/plugins/crash_reporting_plugin.dart';
export 'src/plugins/call_storage_plugin.dart';

// ════════════════════════════════════════════════════════════════════════════
// PUBLIC API - Utilities
// ════════════════════════════════════════════════════════════════════════════
export 'src/utils/rtc_logger.dart';

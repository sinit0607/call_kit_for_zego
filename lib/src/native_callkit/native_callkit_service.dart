import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:uuid/uuid.dart';
import '../models/call_data.dart';
import '../utils/rtc_logger.dart';
import 'native_callkit_config.dart';

/// Service that wraps flutter_callkit_incoming plugin
///
/// Provides a clean interface to show native CallKit UI on iOS
/// and InCallUI on Android. This is optional and can be enabled/disabled.
class NativeCallKitService {
  final NativeCallKitConfig config;
  static const String _tag = 'NativeCallKitService';

  bool _isInitialized = false;
  final Map<String, CallKitParams> _activeCallKitCalls = {};
  final _uuid = const Uuid();

  // Map CallKit UUID to original callId (and reverse)
  final Map<String, String> _callKitIdToCallId = {};
  final Map<String, String> _callIdToCallKitId = {}; // Reverse mapping

  NativeCallKitService({required this.config});

  /// Initialize the native CallKit service
  Future<void> initialize() async {
    if (_isInitialized) {
      RtcLogger.warning('[$_tag] Already initialized');
      return;
    }

    try {
      RtcLogger.info('[$_tag] Initializing native CallKit service');
      _isInitialized = true;
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to initialize', e, stack);
      rethrow;
    }
  }

  /// Show incoming call UI using native CallKit
  Future<void> showIncomingCall(CallData callData) async {
    if (!_isInitialized) {
      RtcLogger.error('[$_tag] Not initialized, cannot show incoming call');
      return;
    }

    try {
      RtcLogger.info('[$_tag] Showing incoming call: ${callData.callId}');
      RtcLogger.info('[$_tag] Call details - User: ${callData.remoteUser.userName}, Type: ${callData.callType.name}, IsIncoming: ${callData.isIncoming}');

      // SAFETY: Clear any existing CallKit calls to prevent conflicts
      try {
        final activeCalls = await FlutterCallkitIncoming.activeCalls();
        if (activeCalls.isNotEmpty) {
          RtcLogger.warning('[$_tag] Found ${activeCalls.length} active CallKit calls, clearing them first');
          await FlutterCallkitIncoming.endAllCalls();
          await Future.delayed(Duration(milliseconds: 100)); // Small delay to let CallKit clean up
        }
      } catch (e) {
        RtcLogger.warning('[$_tag] Could not check/clear active calls: $e');
        // Continue anyway - this is just a safety check
      }

      // CRITICAL FIX: Ensure handle is never null or empty (required by iOS CallKit)
      final safeHandle = callData.remoteUser.userId.isNotEmpty
          ? callData.remoteUser.userId
          : callData.remoteUser.userName;

      // CRITICAL FIX: Don't pass null avatar - can cause crashes
      final safeAvatar = callData.remoteUser.avatarUrl?.isNotEmpty == true
          ? callData.remoteUser.avatarUrl
          : null;

      // CRITICAL FIX: Generate proper UUID for iOS CallKit (iOS requires valid UUID format)
      // iOS UUID format: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
      final callKitUuid = _uuid.v4();
      _callKitIdToCallId[callKitUuid] = callData.callId;
      _callIdToCallKitId[callData.callId] = callKitUuid; // Reverse mapping

      RtcLogger.info('[$_tag] Generated CallKit UUID: $callKitUuid for callId: ${callData.callId}');

      // RESTORED: Use old working configuration from commit 0b455bb
      final params = CallKitParams(
        id: callKitUuid, // Use proper UUID format instead of our custom callId
        nameCaller: callData.remoteUser.userName,
        appName: config.appName,
        avatar: safeAvatar,
        handle: safeHandle,
        type: callData.callType.isVideo ? 1 : 0,
        duration: config.ringDuration.inMilliseconds,
        extra: <String, dynamic>{
          'originalCallId': callData.callId, // Store original callId for later retrieval
          'callType': callData.callType.name,
          'isIncoming': callData.isIncoming,
        },
        headers: <String, dynamic>{'platform': 'ios'},
        android: AndroidParams(
          isCustomNotification: true,
          isShowLogo: false,
          isShowFullLockedScreen: true, // ✅ CRITICAL: Shows full-screen UI on locked screen
          isShowCallID: false,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: '#0955fa',
          backgroundUrl: safeAvatar ?? '',
          actionColor: '#4CAF50',
          textColor: '#ffffff',
          incomingCallNotificationChannelName: 'Incoming Call',
          missedCallNotificationChannelName: 'Missed Call',
          textAccept: 'Accept',
          textDecline: 'Decline',
        ),
        ios: const IOSParams(
          // CRITICAL: NO iconName - asset doesn't exist and causes crash
          handleType: 'number',
          supportsVideo: true, // Set to true to support both audio/video
          maximumCallGroups: 2,
          maximumCallsPerCallGroup: 1,
          audioSessionMode: 'voip',
          audioSessionActive: true,
          audioSessionPreferredSampleRate: 44100.0,
          audioSessionPreferredIOBufferDuration: 0.005,
          supportsDTMF: true,
          supportsHolding: true,
          supportsGrouping: false,
          supportsUngrouping: false,
          ringtonePath: 'system_ringtone_default',
        ),
      );

      _activeCallKitCalls[callKitUuid] = params;

      RtcLogger.info('[$_tag] Calling FlutterCallkitIncoming.showCallkitIncoming...');

      // Debug: Log all params before calling
      RtcLogger.info('[$_tag] CallKit Params:');
      RtcLogger.info('  - id (CallKit UUID): ${params.id}');
      RtcLogger.info('  - originalCallId: ${callData.callId}');
      RtcLogger.info('  - nameCaller: ${params.nameCaller}');
      RtcLogger.info('  - appName: ${params.appName}');
      RtcLogger.info('  - handle: ${params.handle}');
      RtcLogger.info('  - type: ${params.type}');
      RtcLogger.info('  - avatar: ${params.avatar ?? "null"}');
      RtcLogger.info('  - duration: ${params.duration}');

      // Call with multiple layers of protection
      try {
        RtcLogger.info('[$_tag] About to call native FlutterCallkitIncoming.showCallkitIncoming...');

        await FlutterCallkitIncoming.showCallkitIncoming(params).timeout(
          Duration(seconds: 5),
          onTimeout: () {
            RtcLogger.warning('[$_tag] ⚠️ CallKit call timed out after 5 seconds');
          },
        );

        RtcLogger.info('[$_tag] ✅ FlutterCallkitIncoming.showCallkitIncoming completed');
        RtcLogger.success('[$_tag] ✅ CallKit UI should now be visible');
      } on PlatformException catch (e) {
        RtcLogger.error('[$_tag] ❌ PlatformException from CallKit: ${e.code} - ${e.message}');
        RtcLogger.error('[$_tag] Details: ${e.details}');
      } on TimeoutException catch (e) {
        RtcLogger.warning('[$_tag] ⏱️ Timeout calling CallKit: $e');
      } catch (e, stack) {
        RtcLogger.error('[$_tag] ❌ Unexpected error calling CallKit: ${e.runtimeType}');
        RtcLogger.error('[$_tag] Error: $e');
        RtcLogger.error('[$_tag] Stack: $stack');
      }
    } catch (e, stack) {
      RtcLogger.error('[$_tag] ❌❌❌ OUTER CATCH: Failed to show incoming call ❌❌❌', e, stack);
      RtcLogger.error('[$_tag] Error details: ${e.toString()}');
      RtcLogger.error('[$_tag] Stack trace: ${stack.toString()}');
    }
  }

  /// Show outgoing call UI
  Future<void> showOutgoingCall(CallData callData) async {
    if (!_isInitialized) {
      RtcLogger.error('[$_tag] Not initialized, cannot show outgoing call');
      return;
    }

    try {
      RtcLogger.info('[$_tag] Showing outgoing call: ${callData.callId}');

      // Generate proper UUID for iOS CallKit
      final callKitUuid = _uuid.v4();
      _callKitIdToCallId[callKitUuid] = callData.callId;
      _callIdToCallKitId[callData.callId] = callKitUuid; // Reverse mapping

      final params = CallKitParams(
        id: callKitUuid,
        nameCaller: callData.remoteUser.userName,
        appName: config.appName,
        avatar: callData.remoteUser.avatarUrl,
        handle: callData.remoteUser.userId,
        type: callData.callType.isVideo ? 1 : 0,
        duration: config.callTimeout.inMilliseconds,
        extra: <String, dynamic>{
          'callType': callData.callType.name,
          'isIncoming': false,
        },
        headers: <String, dynamic>{},
        android: AndroidParams(
          isCustomNotification: true,
          isShowLogo: config.showLogo,
          backgroundColor: config.androidBackgroundColor,
          backgroundUrl: callData.remoteUser.avatarUrl ?? '',
          actionColor: config.androidActionColor,
          textColor: config.androidTextColor,
          incomingCallNotificationChannelName: config.androidChannelName,
          textAccept: config.acceptText,
          textDecline: config.declineText,
        ),
        ios: const IOSParams(
          // CRITICAL: NO iconName - asset doesn't exist and causes crash
          handleType: 'number',
          normalHandle: 1, // Outgoing call: handle is not encrypted
          supportsVideo: true,
          maximumCallGroups: 2,
          maximumCallsPerCallGroup: 1,
          audioSessionMode: 'voip',
          audioSessionActive: true,
          audioSessionPreferredSampleRate: 44100.0,
          audioSessionPreferredIOBufferDuration: 0.005,
          supportsDTMF: true,
          supportsHolding: true,
          supportsGrouping: false,
          supportsUngrouping: false,
          ringtonePath: 'system_ringtone_default',
        ),
      );

      _activeCallKitCalls[callKitUuid] = params;
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      RtcLogger.info('[$_tag] Successfully showed outgoing call: ${callData.callId}');
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to show outgoing call', e, stack);
    }
  }

  /// Mark call as connected (updates CallKit UI state)
  Future<void> markCallConnected(String callId) async {
    if (!_isInitialized) return;

    try {
      RtcLogger.info('[$_tag] Marking call as connected: $callId');

      // CRITICAL FIX: Look up the CallKit UUID from the original callId
      final callKitUuid = _callIdToCallKitId[callId];

      if (callKitUuid == null) {
        RtcLogger.error('[$_tag] Cannot mark call as connected: No CallKit UUID found for callId: $callId');
        RtcLogger.error('[$_tag] Available mappings: $_callIdToCallKitId');
        return;
      }

      RtcLogger.info('[$_tag] Found CallKit UUID: $callKitUuid for callId: $callId');

      await FlutterCallkitIncoming.startCall(CallKitParams(
        id: callKitUuid, // ✅ Use CallKit UUID, not original callId
        nameCaller: '',
        handle: '',
        type: 0,
      ));

      RtcLogger.success('[$_tag] ✅ Successfully marked call as connected');
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to mark call as connected', e, stack);
    }
  }

  /// End call and dismiss CallKit UI
  /// Pass the callId (will look up corresponding CallKit UUID if it exists)
  Future<void> endCall(String callId) async {
    if (!_isInitialized) return;

    try {
      // Look up the CallKit UUID for this callId
      final callKitUuid = _callIdToCallKitId[callId];

      if (callKitUuid == null) {
        // No CallKit UI was shown for this call (e.g., outgoing call from user side)
        // This is normal - just log and return
        RtcLogger.info('[$_tag] No CallKit UUID found for callId: $callId (no CallKit UI shown)');
        return;
      }

      RtcLogger.info('[$_tag] Ending call: callId=$callId, callKitUuid=$callKitUuid');
      await FlutterCallkitIncoming.endCall(callKitUuid);
      _activeCallKitCalls.remove(callKitUuid);

      // Clean up both mappings
      _callIdToCallKitId.remove(callId);
      _callKitIdToCallId.remove(callKitUuid);

      RtcLogger.success('[$_tag] Successfully ended CallKit call: $callKitUuid');
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to end call', e, stack);
    }
  }

  /// End all active calls
  Future<void> endAllCalls() async {
    if (!_isInitialized) return;

    try {
      RtcLogger.info('[$_tag] Ending all calls');
      await FlutterCallkitIncoming.endAllCalls();
      _activeCallKitCalls.clear();
      _callKitIdToCallId.clear();
      _callIdToCallKitId.clear(); // Clear reverse mapping too
    } catch (e, stack) {
      RtcLogger.error('[$_tag] Failed to end all calls', e, stack);
    }
  }

  /// Get stream of CallKit events
  ///
  /// Events include:
  /// - ACTION_CALL_INCOMING
  /// - ACTION_CALL_START
  /// - ACTION_CALL_ACCEPT
  /// - ACTION_CALL_DECLINE
  /// - ACTION_CALL_ENDED
  /// - ACTION_CALL_TIMEOUT
  /// - ACTION_CALL_CALLBACK (missed call callback)
  /// - ACTION_CALL_TOGGLE_HOLD
  /// - ACTION_CALL_TOGGLE_MUTE
  /// - ACTION_CALL_TOGGLE_DMTF
  /// - ACTION_CALL_TOGGLE_GROUP
  /// - ACTION_CALL_TOGGLE_AUDIO_SESSION
  Stream<CallEvent?> get eventStream {
    return FlutterCallkitIncoming.onEvent;
  }

  /// Check if a call is currently active in CallKit
  Future<bool> hasActiveCall() async {
    if (!_isInitialized) return false;

    try {
      final activeCalls = await FlutterCallkitIncoming.activeCalls();
      return activeCalls.isNotEmpty;
    } catch (e) {
      RtcLogger.error('[$_tag] Failed to check active calls', e);
      return false;
    }
  }

  /// Get all active CallKit calls
  Future<List<dynamic>> getActiveCalls() async {
    if (!_isInitialized) return [];

    try {
      return await FlutterCallkitIncoming.activeCalls();
    } catch (e) {
      RtcLogger.error('[$_tag] Failed to get active calls', e);
      return [];
    }
  }

  /// Get original callId from CallKit UUID
  /// Returns null if mapping doesn't exist
  String? getOriginalCallId(String callKitUuid) {
    return _callKitIdToCallId[callKitUuid];
  }

  /// Dispose and cleanup
  Future<void> dispose() async {
    RtcLogger.info('[$_tag] Disposing native CallKit service');
    await endAllCalls();
    _isInitialized = false;
    _activeCallKitCalls.clear();
    _callKitIdToCallId.clear();
  }
}

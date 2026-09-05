import 'dart:async';
import '../models/call_data.dart';
import '../models/call_state.dart';
import '../models/call_end_reason.dart';
import '../utils/rtc_logger.dart';

// ══════════════════════════════════════════════════════════════════════════
// CALL STATE MANAGER - SINGLE SOURCE OF TRUTH FOR CALL STATE
// ══════════════════════════════════════════════════════════════════════════
//
// CRITICAL RULES:
// 1. All state transitions go through CallStateGuard
// 2. Thread-safe with synchronized Lock
// 3. Only ONE active call allowed at a time
// 4. State MUST be cleared after ANY call termination
//
// ══════════════════════════════════════════════════════════════════════════

/// Simple async lock for thread-safe state management
class _AsyncLock {
  Completer<void>? _completer;

  /// Execute a function with exclusive access
  Future<T> synchronized<T>(Future<T> Function() fn) async {
    // Wait for any existing operation to complete
    while (_completer != null) {
      await _completer!.future;
    }

    // Create new lock
    _completer = Completer<void>();

    try {
      return await fn();
    } finally {
      // Release lock
      final completer = _completer;
      _completer = null;
      completer?.complete();
    }
  }
}

/// Manages call state transitions with validation
/// Prevents invalid state transitions and tracks current call
/// Thread-safe with synchronization
class CallStateManager {
  // ════════════════════════════════════════════════════════════════════════
  // STATE VARIABLES - PRIVATE, ACCESS ONLY THROUGH METHODS
  // ════════════════════════════════════════════════════════════════════════

  CallData? _currentCall;
  final _AsyncLock _stateLock = _AsyncLock();

  final _stateController = StreamController<CallStateChange>.broadcast();
  final _callDataController = StreamController<CallData>.broadcast();

  /// Stream of state changes (for tracking transitions)
  Stream<CallStateChange> get stateChanges => _stateController.stream;

  /// Stream of call data changes
  Stream<CallData> get stateStream => _callDataController.stream;

  /// Current active call (if any)
  CallData? get currentCall => _currentCall;

  /// Current call state
  CallState get currentState => _currentCall?.state ?? CallState.idle;

  /// Check if there's an active call
  bool get hasActiveCall => _currentCall != null && _currentCall!.isActive;

  /// Check if can accept new incoming call
  bool get canAcceptIncomingCall => !hasActiveCall;

  // ════════════════════════════════════════════════════════════════════════
  // CALL INITIALIZATION
  // ════════════════════════════════════════════════════════════════════════

  /// Initialize a new outgoing call
  ///
  /// RULES:
  /// 1. Can only start from IDLE state
  /// 2. Must provide call data with isIncoming = false
  Future<CallData?> initializeOutgoingCall(CallData callData) async {
    return await _stateLock.synchronized(() async {
      // RULE: Can only start from IDLE
      if (currentState != CallState.idle) {
        RtcLogger.error(
          '❌ Cannot start outgoing call from state: $currentState',
          {'currentCall': _currentCall?.callId ?? 'null'},
        );
        return null;
      }

      if (callData.isIncoming) {
        RtcLogger.error('❌ Cannot initialize outgoing call with incoming=true');
        return null;
      }

      // Validate transition
      final newState = CallStateGuard.transition(CallState.idle, CallState.calling);
      if (newState != CallState.calling) {
        RtcLogger.error('❌ Transition to calling blocked by guard');
        return null;
      }

      final newCall = callData.copyWith(state: CallState.calling);
      _currentCall = newCall;
      _emitStateChange(CallState.idle, CallState.calling);
      _emitCallData(newCall);

      RtcLogger.success(
        '✅ Outgoing call initialized',
        {'callId': newCall.callId, 'to': newCall.remoteUser.userName},
      );

      return newCall;
    });
  }

  /// Initialize a new incoming call
  ///
  /// RULES:
  /// 1. Can only receive in IDLE state
  /// 2. Must provide call data with isIncoming = true
  Future<CallData?> initializeIncomingCall(CallData callData) async {
    return await _stateLock.synchronized(() async {
      // RULE: Can only receive call in IDLE
      if (currentState != CallState.idle) {
        RtcLogger.error(
          '❌ Cannot receive incoming call in state: $currentState',
          {'currentCall': _currentCall?.callId ?? 'null'},
        );
        return null;
      }

      if (!callData.isIncoming) {
        RtcLogger.error('❌ Cannot initialize incoming call with incoming=false');
        return null;
      }

      // Validate transition
      final newState = CallStateGuard.transition(CallState.idle, CallState.ringing);
      if (newState != CallState.ringing) {
        RtcLogger.error('❌ Transition to ringing blocked by guard');
        return null;
      }

      final newCall = callData.copyWith(state: CallState.ringing);
      _currentCall = newCall;
      _emitStateChange(CallState.idle, CallState.ringing);
      _emitCallData(newCall);

      RtcLogger.success(
        '✅ Incoming call initialized',
        {'callId': newCall.callId, 'from': newCall.remoteUser.userName},
      );

      return newCall;
    });
  }

  // ════════════════════════════════════════════════════════════════════════
  // STATE TRANSITIONS - ALL GO THROUGH GUARD
  // ════════════════════════════════════════════════════════════════════════

  /// Transition to a new state
  ///
  /// CRITICAL: All transitions go through CallStateGuard.
  /// Invalid transitions are logged and BLOCKED.
  Future<bool> transitionTo(CallState newState) async {
    return await _stateLock.synchronized(() async {
      if (_currentCall == null) {
        RtcLogger.error('❌ No active call for transition to $newState');
        return false;
      }

      final oldState = _currentCall!.state;

      // USE GUARD
      final resultState = CallStateGuard.transition(oldState, newState);

      if (resultState == newState) {
        // AUDIO CALL LOGGING: Log state transitions for audio calls
        final isAudioCall = _currentCall!.callType.isAudio;
        if (isAudioCall) {
          RtcLogger.audioCall(
            userId: _currentCall!.localUser.userId,
            peerId: _currentCall!.remoteUser.userId,
            roomId: _currentCall!.roomId,
            streamId: null,
            callType: 'audio',
            step: 'STATE_TRANSITION',
            detail: '${oldState.name} -> ${newState.name}',
          );
        }

        // Transition allowed
        _currentCall = _currentCall!.copyWith(state: newState);
        _emitStateChange(oldState, newState);
        _emitCallData(_currentCall!);
        return true;
      }

      // Transition blocked by guard
      RtcLogger.error(
        '❌ Transition BLOCKED by guard',
        {'from': oldState.name, 'to': newState.name},
      );
      return false;
    });
  }

  /// Transition to accepted state
  Future<bool> transitionToAccepted() => transitionTo(CallState.accepted);

  /// Transition to connecting state
  Future<bool> transitionToConnecting() => transitionTo(CallState.connecting);

  /// Transition to connected state
  Future<bool> transitionToConnected() => transitionTo(CallState.connected);

  /// Transition to reconnecting state
  Future<bool> transitionToReconnecting() => transitionTo(CallState.reconnecting);

  // ════════════════════════════════════════════════════════════════════════
  // END CALL - CRITICAL: ALWAYS CLEAR STATE
  // ════════════════════════════════════════════════════════════════════════

  /// End the current call
  ///
  /// CRITICAL: This MUST be called for ANY call termination.
  /// Always clears state, even if already ended.
  Future<bool> endCall(CallEndReason reason) async {
    return await _stateLock.synchronized(() async {
      if (_currentCall == null) {
        RtcLogger.warning('⚠️ No call to end (already cleared)');
        return false;
      }

      if (_currentCall!.hasEnded) {
        RtcLogger.warning('⚠️ Call already ended, clearing state');
        _clearState();
        return false;
      }

      final oldState = _currentCall!.state;
      final endState = _determineEndState(reason);

      RtcLogger.info('🧹 ENDING CALL', {
        'callId': _currentCall!.callId,
        'oldState': oldState.name,
        'endState': endState.name,
        'reason': reason.name,
      });

      final updated = _currentCall!.copyWith(
        state: endState,
        endReason: reason,
        endTime: DateTime.now(),
      );

      // CRITICAL: Clear state AFTER emitting final state
      _emitStateChange(oldState, endState);
      _emitCallData(updated);

      // NOW clear internal state
      _clearState();

      RtcLogger.success('✅ Call ended and state cleared');

      return true;
    });
  }

  /// Determine end state based on reason
  CallState _determineEndState(CallEndReason reason) {
    switch (reason) {
      case CallEndReason.missed:
        return CallState.missed;
      case CallEndReason.timeout:
        return CallState.timeout;
      case CallEndReason.failed:
      case CallEndReason.networkLost:
        return CallState.failed;
      default:
        return CallState.ended;
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  // STATE UPDATES (Non-transition)
  // ════════════════════════════════════════════════════════════════════════

  /// Update session information (sessionId and roomId from backend)
  /// Called when sessionStarted event is received
  void updateSessionInfo({
    required String sessionId,
    required String roomId,
  }) {
    if (_currentCall == null) {
      RtcLogger.warning('⚠️ Cannot update session info: No active call');
      return;
    }

    RtcLogger.info('📝 Updating session info', {
      'sessionId': sessionId,
      'roomId': roomId,
    });

    // AUDIO CALL LOGGING: Log critical session ID assignment for audio calls
    final isAudioCall = _currentCall!.callType.isAudio;
    if (isAudioCall) {
      RtcLogger.audioCall(
        userId: _currentCall!.localUser.userId,
        peerId: _currentCall!.remoteUser.userId,
        roomId: roomId,
        streamId: null,
        callType: 'audio',
        step: 'SESSION_ID_SET',
        detail: 'sessionId assigned for audio call correlation',
      );
    }

    _currentCall = _currentCall!.copyWith(
      sessionId: sessionId,
      roomId: roomId,
    );
    _emitCallData(_currentCall!);
  }

  /// Update call duration
  void updateDuration(int seconds) {
    if (_currentCall == null) return;
    if (_currentCall!.state != CallState.connected) return;

    final updated = _currentCall!.copyWith(durationSeconds: seconds);
    _currentCall = updated;
    _emitCallData(updated);
  }

  // ════════════════════════════════════════════════════════════════════════
  // CLEANUP - CRITICAL: MUST CLEAR ALL STATE
  // ════════════════════════════════════════════════════════════════════════

  /// Clear current call (for cleanup)
  ///
  /// CRITICAL: Call this after ANY call termination.
  void clearCall() {
    _stateLock.synchronized(() async {
      _clearState();
    });
  }

  void _clearState() {
    final hadCall = _currentCall != null;
    _currentCall = null;

    if (hadCall) {
      RtcLogger.success('✅ Call state CLEARED - ready for new calls');
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  // EVENT EMISSION
  // ════════════════════════════════════════════════════════════════════════

  void _emitStateChange(CallState from, CallState to) {
    if (!_stateController.isClosed) {
      _stateController.add(CallStateChange(from: from, to: to));
    }
  }

  void _emitCallData(CallData callData) {
    if (!_callDataController.isClosed) {
      _callDataController.add(callData);
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  // DEBUGGING
  // ════════════════════════════════════════════════════════════════════════

  /// Get current state for debugging
  Map<String, dynamic> captureState() {
    return {
      'hasActiveCall': hasActiveCall,
      'currentState': currentState.name,
      'callId': _currentCall?.callId,
      'sessionId': _currentCall?.sessionId,
      'roomId': _currentCall?.roomId,
      'remoteUser': _currentCall?.remoteUser.userName,
      'isIncoming': _currentCall?.isIncoming,
      'durationSeconds': _currentCall?.durationSeconds,
    };
  }

  /// Dispose resources
  void dispose() {
    _currentCall = null;
    _stateController.close();
    _callDataController.close();
    RtcLogger.debug('CallStateManager disposed');
  }
}

/// State change event
class CallStateChange {
  final CallState from;
  final CallState to;
  final DateTime timestamp;

  CallStateChange({required this.from, required this.to})
      : timestamp = DateTime.now();

  @override
  String toString() => 'CallStateChange($from → $to)';
}

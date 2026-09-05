/// Represents the current state of a call
/// State machine transitions ensure predictable call flow
enum CallState {
  /// No active call
  idle,

  /// Outgoing call is ringing (waiting for remote to accept)
  calling,

  /// Incoming call is ringing (waiting for local user to accept/reject)
  ringing,

  /// Call accepted, waiting for sessionStarted from backend
  accepted,

  /// Call is being connected (establishing media streams)
  connecting,

  /// Call is active and connected
  connected,

  /// Call is attempting to reconnect after network loss
  reconnecting,

  /// Incoming call was missed (not answered within timeout)
  missed,

  /// Call ended normally
  ended,

  /// Call failed due to an error
  failed,

  /// Call timed out (ringing timeout expired)
  timeout;

  /// Check if call is in active states
  bool get isActive =>
      this == CallState.calling ||
      this == CallState.ringing ||
      this == CallState.accepted ||
      this == CallState.connecting ||
      this == CallState.connected ||
      this == CallState.reconnecting;

  /// Check if call is in terminal states
  bool get isTerminal =>
      this == CallState.ended ||
      this == CallState.failed ||
      this == CallState.timeout ||
      this == CallState.missed;

  /// Check if call is ringing
  bool get isRinging => this == CallState.ringing || this == CallState.calling;

  /// Check if call is connected
  bool get isConnected => this == CallState.connected;

  /// Check if call is idle
  bool get isIdle => this == CallState.idle;

  /// Check if ZEGO room should be active
  bool get shouldHaveZegoRoom =>
      this == CallState.connecting ||
      this == CallState.connected ||
      this == CallState.reconnecting;

  /// Check if can transition to given state
  bool canTransitionTo(CallState target) {
    return CallStateGuard.canTransition(this, target);
  }

  /// Convert to display string
  String toDisplayString() {
    switch (this) {
      case CallState.idle:
        return 'Idle';
      case CallState.calling:
        return 'Calling...';
      case CallState.ringing:
        return 'Incoming Call';
      case CallState.accepted:
        return 'Connecting...';
      case CallState.connecting:
        return 'Connecting...';
      case CallState.connected:
        return 'Connected';
      case CallState.reconnecting:
        return 'Reconnecting...';
      case CallState.missed:
        return 'Missed Call';
      case CallState.ended:
        return 'Call Ended';
      case CallState.failed:
        return 'Call Failed';
      case CallState.timeout:
        return 'Call Timeout';
    }
  }

  /// Convert to JSON string
  String toJson() => name;

  /// Create from JSON string
  static CallState fromJson(String value) {
    return CallState.values.firstWhere(
      (e) => e.name == value,
      orElse: () => CallState.idle,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// CALL STATE GUARD - ENFORCES VALID TRANSITIONS ONLY
// ══════════════════════════════════════════════════════════════════════════
//
// RULE: Any transition not in this map MUST be logged and IGNORED.
// This prevents invalid state machine transitions that cause bugs.
//
// ══════════════════════════════════════════════════════════════════════════

/// Allowed state transitions - violation is a bug
const Map<CallState, Set<CallState>> _allowedTransitions = {
  CallState.idle: {
    CallState.calling, // Start outgoing call
    CallState.ringing, // Receive incoming call
  },
  CallState.calling: {
    CallState.accepted, // Remote accepted (for caller's view)
    CallState.connecting, // Going directly to session (fast path)
    CallState.ended, // Remote rejected or cancelled
    CallState.failed, // Network or timeout error
    CallState.timeout, // Call timeout
  },
  CallState.ringing: {
    CallState.accepted, // User accepted
    CallState.connecting, // Direct connect (fast path)
    CallState.ended, // User rejected
    CallState.missed, // Timeout without action
    CallState.failed, // Call cancelled by caller
  },
  CallState.accepted: {
    CallState.connecting, // sessionStarted received
    CallState.ended, // Session failed to start
    CallState.failed, // Timeout or error
    CallState.timeout, // Backend timeout
  },
  CallState.connecting: {
    CallState.connected, // ZEGO room joined successfully
    CallState.failed, // ZEGO join failed
    CallState.ended, // Call ended during connect
  },
  CallState.connected: {
    CallState.reconnecting, // Network loss
    CallState.ended, // Normal call end
    CallState.failed, // Fatal error during call
  },
  CallState.reconnecting: {
    CallState.connected, // Reconnect success
    CallState.ended, // Reconnect timeout
    CallState.failed, // Reconnect failed
  },
  // Terminal states - no transitions allowed
  CallState.ended: {},
  CallState.failed: {},
  CallState.missed: {},
  CallState.timeout: {},
};

/// Transition guard - validates state changes
///
/// CRITICAL: All state transitions MUST go through this guard.
/// Invalid transitions are logged and BLOCKED.
class CallStateGuard {
  static const String _tag = 'CallStateGuard';

  /// Check if transition is allowed
  /// Returns true if allowed, false if not
  static bool canTransition(CallState from, CallState to) {
    // Always allow transition to same state (no-op)
    if (from == to) return true;

    // Always allow transition from terminal states to idle (reset)
    if (from.isTerminal && to == CallState.idle) return true;

    final allowed = _allowedTransitions[from] ?? {};
    return allowed.contains(to);
  }

  /// Validate and execute transition
  /// Returns the new state if allowed, current state if not
  ///
  /// USAGE:
  /// ```dart
  /// final newState = CallStateGuard.transition(currentState, targetState);
  /// if (newState == targetState) {
  ///   // Transition successful
  /// } else {
  ///   // Transition blocked
  /// }
  /// ```
  static CallState transition(CallState current, CallState target) {
    if (canTransition(current, target)) {
      _logTransition(current, target, allowed: true);
      return target;
    }

    // ════════════════════════════════════════════════════════════════════════
    // FORBIDDEN TRANSITION - LOG ERROR AND IGNORE
    // ════════════════════════════════════════════════════════════════════════

    _logTransition(current, target, allowed: false);
    _reportForbiddenTransition(current, target);

    // Return current state - DO NOT CHANGE
    return current;
  }

  static void _logTransition(
    CallState from,
    CallState to, {
    required bool allowed,
  }) {
    if (allowed) {
      print('[$_tag] ✅ $from → $to');
    } else {
      print('[$_tag] ❌❌❌ FORBIDDEN TRANSITION: $from → $to');
      print('[$_tag] Allowed from $from: ${_allowedTransitions[from]}');
      print('[$_tag] This is a BUG - investigate immediately');
    }
  }

  static void _reportForbiddenTransition(CallState from, CallState to) {
    // TODO: Send to crash reporting service
    // Example:
    // FirebaseCrashlytics.instance.recordError(
    //   Exception('Forbidden state transition: $from → $to'),
    //   StackTrace.current,
    //   reason: 'CallStateGuard violation',
    // );
  }

  /// Get allowed transitions from a state (for debugging)
  static Set<CallState> getAllowedTransitions(CallState from) {
    return _allowedTransitions[from] ?? {};
  }
}

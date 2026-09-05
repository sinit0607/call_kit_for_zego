/// Call storage plugin interface for persisting call data
///
/// Implement this interface to store call history locally or remotely
///
/// Example implementation:
/// ```dart
/// class SharedPrefsCallStoragePlugin implements CallStoragePlugin {
///   final SharedPreferences _prefs;
///
///   @override
///   Future<void> saveActiveCall(CallRecord record) async {
///     await _prefs.setString('active_call', jsonEncode(record.toJson()));
///   }
/// }
/// ```
abstract class CallStoragePlugin {
  /// Save an active call (for recovery after app restart)
  Future<void> saveActiveCall(CallRecord record);

  /// Get the active call (if any)
  Future<CallRecord?> getActiveCall();

  /// Clear the active call
  Future<void> clearActiveCall();

  /// Save a completed call to history
  Future<void> saveCallToHistory(CallRecord record);

  /// Get call history
  Future<List<CallRecord>> getCallHistory({int? limit, int? offset});

  /// Clear all call history
  Future<void> clearCallHistory();
}

/// Call record model for storage
class CallRecord {
  final String callId;
  final String callType;
  final String callerId;
  final String callerName;
  final String? callerImage;
  final String calleeId;
  final String calleeName;
  final String? calleeImage;
  final String? roomId;
  final String? sessionId;
  final DateTime startTime;
  final DateTime? endTime;
  final String? endReason;
  final int? durationSeconds;
  final bool isOutgoing;
  final Map<String, dynamic>? metadata;

  CallRecord({
    required this.callId,
    required this.callType,
    required this.callerId,
    required this.callerName,
    this.callerImage,
    required this.calleeId,
    required this.calleeName,
    this.calleeImage,
    this.roomId,
    this.sessionId,
    required this.startTime,
    this.endTime,
    this.endReason,
    this.durationSeconds,
    required this.isOutgoing,
    this.metadata,
  });

  Map<String, dynamic> toJson() => {
    'callId': callId,
    'callType': callType,
    'callerId': callerId,
    'callerName': callerName,
    'callerImage': callerImage,
    'calleeId': calleeId,
    'calleeName': calleeName,
    'calleeImage': calleeImage,
    'roomId': roomId,
    'sessionId': sessionId,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime?.toIso8601String(),
    'endReason': endReason,
    'durationSeconds': durationSeconds,
    'isOutgoing': isOutgoing,
    'metadata': metadata,
  };

  factory CallRecord.fromJson(Map<String, dynamic> json) => CallRecord(
    callId: json['callId'] as String,
    callType: json['callType'] as String,
    callerId: json['callerId'] as String,
    callerName: json['callerName'] as String,
    callerImage: json['callerImage'] as String?,
    calleeId: json['calleeId'] as String,
    calleeName: json['calleeName'] as String,
    calleeImage: json['calleeImage'] as String?,
    roomId: json['roomId'] as String?,
    sessionId: json['sessionId'] as String?,
    startTime: DateTime.parse(json['startTime'] as String),
    endTime: json['endTime'] != null ? DateTime.parse(json['endTime'] as String) : null,
    endReason: json['endReason'] as String?,
    durationSeconds: json['durationSeconds'] as int?,
    isOutgoing: json['isOutgoing'] as bool,
    metadata: json['metadata'] as Map<String, dynamic>?,
  );

  /// Convenience getter: remote user ID (callee if outgoing, caller if incoming)
  String get remoteUserId => isOutgoing ? calleeId : callerId;

  /// Convenience getter: remote user name (callee if outgoing, caller if incoming)
  String get remoteUserName => isOutgoing ? calleeName : callerName;

  /// Convenience getter: remote user avatar (callee if outgoing, caller if incoming)
  String? get remoteUserAvatar => isOutgoing ? calleeImage : callerImage;

  CallRecord copyWith({
    String? callId,
    String? callType,
    String? callerId,
    String? callerName,
    String? callerImage,
    String? calleeId,
    String? calleeName,
    String? calleeImage,
    String? roomId,
    String? sessionId,
    DateTime? startTime,
    DateTime? endTime,
    String? endReason,
    int? durationSeconds,
    bool? isOutgoing,
    Map<String, dynamic>? metadata,
  }) => CallRecord(
    callId: callId ?? this.callId,
    callType: callType ?? this.callType,
    callerId: callerId ?? this.callerId,
    callerName: callerName ?? this.callerName,
    callerImage: callerImage ?? this.callerImage,
    calleeId: calleeId ?? this.calleeId,
    calleeName: calleeName ?? this.calleeName,
    calleeImage: calleeImage ?? this.calleeImage,
    roomId: roomId ?? this.roomId,
    sessionId: sessionId ?? this.sessionId,
    startTime: startTime ?? this.startTime,
    endTime: endTime ?? this.endTime,
    endReason: endReason ?? this.endReason,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    isOutgoing: isOutgoing ?? this.isOutgoing,
    metadata: metadata ?? this.metadata,
  );
}

/// Default no-op implementation (does nothing)
class NoOpCallStoragePlugin implements CallStoragePlugin {
  @override
  Future<void> saveActiveCall(CallRecord record) async {}

  @override
  Future<CallRecord?> getActiveCall() async => null;

  @override
  Future<void> clearActiveCall() async {}

  @override
  Future<void> saveCallToHistory(CallRecord record) async {}

  @override
  Future<List<CallRecord>> getCallHistory({int? limit, int? offset}) async => [];

  @override
  Future<void> clearCallHistory() async {}
}

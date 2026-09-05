/// Socket adapter interface for integrating with different socket implementations
///
/// This allows call_kit_for_zego to work with any socket library (Socket.IO, WebSocket, etc.)
/// by providing a common interface for emitting and listening to events.
///
/// Example implementation for Socket.IO:
/// ```dart
/// class SocketIOAdapter implements SocketAdapter {
///   final IO.Socket socket;
///
///   SocketIOAdapter(this.socket);
///
///   @override
///   Future<void> emit(String event, Map<String, dynamic> data) async {
///     socket.emit(event, data);
///   }
///
///   @override
///   void on(String event, void Function(dynamic data) callback) {
///     socket.on(event, callback);
///   }
///
///   @override
///   void off(String event) {
///     socket.off(event);
///   }
/// }
/// ```
abstract class SocketAdapter {
  /// Emit an event with data
  Future<void> emit(String event, Map<String, dynamic> data);

  /// Listen to an event
  void on(String event, void Function(dynamic data) callback);

  /// Remove listener for an event
  void off(String event);

  /// Check if socket is connected
  bool get isConnected;
}

/// Simple function-based socket adapter
///
/// Use this when you want to provide simple callbacks without implementing
/// the full SocketAdapter interface.
///
/// Example:
/// ```dart
/// final adapter = FunctionSocketAdapter(
///   emitFn: (event, data) async => socket.emit(event, data),
///   onFn: (event, callback) => socket.on(event, callback),
///   offFn: (event) => socket.off(event),
///   isConnectedFn: () => socket.connected,
/// );
/// ```
class FunctionSocketAdapter implements SocketAdapter {
  final Future<void> Function(String event, Map<String, dynamic> data) emitFn;
  final void Function(String event, void Function(dynamic data) callback) onFn;
  final void Function(String event) offFn;
  final bool Function() isConnectedFn;

  FunctionSocketAdapter({
    required this.emitFn,
    required this.onFn,
    required this.offFn,
    required this.isConnectedFn,
  });

  @override
  Future<void> emit(String event, Map<String, dynamic> data) {
    return emitFn(event, data);
  }

  @override
  void on(String event, void Function(dynamic data) callback) {
    onFn(event, callback);
  }

  @override
  void off(String event) {
    offFn(event);
  }

  @override
  bool get isConnected => isConnectedFn();
}

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:call_kit_for_zego/call_kit_for_zego.dart';

/// Example implementation of SocketAdapter using socket_io_client
///
/// Your app should implement this interface to connect your socket
/// implementation to the RTC Call Kit package.
class SocketIOAdapterImpl implements SocketAdapter {
  late io.Socket _socket;
  bool _isConnected = false;
  final String serverUrl;
  final String? token;

  /// Who this socket belongs to, so the server can route calls here.
  ///
  /// Kept on the adapter rather than emitted once, because the binding has to
  /// survive a reconnect — and because the user is usually chosen before the
  /// socket finishes connecting, in which case an immediate emit is dropped.
  String? _userId;
  String? _userName;

  SocketIOAdapterImpl({
    required this.serverUrl,
    this.token,
  });

  /// Identify the current user to the server, now and on every reconnect.
  void setUser(String userId, {String? userName}) {
    _userId = userId;
    _userName = userName;
    _register();
  }

  void _register() {
    if (_userId == null || !_isConnected) return;
    _socket.emit('register', {
      'userId': _userId,
      if (_userName != null) 'userName': _userName,
    });
    debugPrint('[SocketAdapter] Registered as $_userId');
  }

  void _initSocket() {
    final options = io.OptionBuilder()
        .setTransports(['websocket'])
        .enableAutoConnect()
        .enableReconnection()
        .setReconnectionAttempts(5)
        .setReconnectionDelay(1000);

    // Add auth token if provided
    if (token != null) {
      options.setAuth({'token': token});
    }

    _socket = io.io(serverUrl, options.build());

    _socket.onConnect((_) {
      _isConnected = true;
      debugPrint('[SocketAdapter] Connected to $serverUrl');
      // Re-assert identity: a reconnect gets a new socket id, and the server
      // has no idea it belongs to the same user.
      _register();
    });

    _socket.onDisconnect((_) {
      _isConnected = false;
      debugPrint('[SocketAdapter] Disconnected from server');
    });

    _socket.onError((error) {
      debugPrint('[SocketAdapter] Socket error: $error');
    });

    _socket.onConnectError((error) {
      debugPrint('[SocketAdapter] Connection error talking to $serverUrl: '
          '$error\n'
          '  Is the demo server running (cd demo_server && npm start)?\n'
          '  A physical device cannot reach 10.0.2.2 or localhost — pass your '
          "machine's LAN IP:\n"
          '  flutter run --dart-define=SIGNALING_URL=http://<LAN-IP>:3000');
    });
  }

  @override
  bool get isConnected => _isConnected;

  @override
  void on(String event, Function(dynamic) callback) {
    _socket.on(event, callback);
  }

  @override
  void off(String event) {
    _socket.off(event);
  }

  @override
  Future<void> emit(String event, Map<String, dynamic> data) async {
    if (_isConnected) {
      _socket.emit(event, data);
    } else {
      debugPrint('[SocketAdapter] Cannot emit - not connected');
    }
  }

  /// Connect to the socket server
  Future<void> connect() async {
    _initSocket();
    if (!_isConnected) {
      _socket.connect();
    }
  }

  /// Disconnect from the socket server
  void disconnect() {
    _socket.disconnect();
    _isConnected = false;
  }

  /// Dispose the socket connection
  void dispose() {
    _socket.dispose();
  }
}

/// Alternative: WebSocket implementation example
///
/// Use this if you're using raw WebSockets instead of Socket.IO
class WebSocketAdapter implements SocketAdapter {
  // WebSocket? _webSocket;
  final bool _isConnected = false;
  final Map<String, List<Function(dynamic)>> _listeners = {};

  @override
  bool get isConnected => _isConnected;

  @override
  void on(String event, Function(dynamic) callback) {
    _listeners.putIfAbsent(event, () => []).add(callback);
  }

  @override
  void off(String event) {
    _listeners.remove(event);
  }

  @override
  Future<void> emit(String event, Map<String, dynamic> data) async {
    // In WebSocket, you typically send JSON with event name
    // final message = jsonEncode({'event': event, 'data': data});
    // _webSocket?.add(message);
    debugPrint('[WebSocketAdapter] Emit not implemented in this example');
  }
}

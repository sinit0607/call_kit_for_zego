import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:call_kit_for_zego/call_kit_for_zego.dart';
import 'socket_adapter_impl.dart';
import 'my_signaling_mapper.dart';

/// Example app demonstrating RTC Call Kit usage
///
/// This example shows:
/// - How to initialize the RTC Communication Service
/// - How to set up socket adapter
/// - How to listen for call events
/// - How to start outgoing calls
/// - How to handle incoming calls
/// - How to use in-session chat messaging
/// Where the demo signaling server is running (see `demo_server/`).
///
/// Override without editing this file:
///   flutter run --dart-define=SIGNALING_URL=http://192.168.1.42:3000
///
/// The Android emulator reaches your machine's localhost on 10.0.2.2; a real
/// device needs your machine's LAN IP. iOS simulators can use localhost.
const String kSignalingUrl = String.fromEnvironment(
  'SIGNALING_URL',
  defaultValue: 'http://192.168.1.7:3000',
);

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RTC Call Kit Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _isInitialized = false;
  String? _currentUserId;
  SocketIOAdapterImpl? _socketAdapter;
  String? _activeSessionId;
  StreamSubscription<CallEvent>? _callEventSubscription;
  StreamSubscription<ChatEvent>? _chatEventSubscription;

  @override
  void initState() {
    super.initState();
    _initializeService();
  }

  @override
  void dispose() {
    _callEventSubscription?.cancel();
    _chatEventSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeService() async {
    try {
      // 1. Create your socket adapter
      // Replace with your actual socket implementation
      final socketAdapter = SocketIOAdapterImpl(
        serverUrl: kSignalingUrl,
      );
      _socketAdapter = socketAdapter;

      // 2. Connect the socket
      await socketAdapter.connect();

      // 3. Initialize RTC Communication Service
      await RtcCommunicationService.initialize(
        config: CommunicationConfig(
          zegoConfig: const ZegoConfig(
            appId: 10420576, // Replace with your ZEGO App ID
            appSign:
                'c852dcc2fbf67706a1b8cf6b18c7c93bad6947611946cc51c4306a4848a6aa41', // Replace with your ZEGO App Sign
          ),
          socketConfig: const SocketConfig(
            url: kSignalingUrl,
          ),
          callKitConfig: const CallKitConfig(
            appName: 'RTC Call Kit Demo',
            timeout: Duration(seconds: 30),
          ),
          signalingMapper: MySignalingMapper(),
        ),
        socketAdapter: socketAdapter,
      );

      // 4. Set up call event listener
      _callEventSubscription =
          RtcCommunicationService.instance.callEvents.listen(_handleCallEvent);

      // 5. Set up chat event listener
      _chatEventSubscription =
          RtcCommunicationService.instance.chatEvents.listen(_handleChatEvent);

      setState(() {
        _isInitialized = true;
      });

      // Ask up front. An incoming call is accepted from the native CallKit UI,
      // which never returns to Flutter before media starts — so there is no
      // point later at which we could prompt.
      await _ensureCallPermissions(isVideo: true);
    } catch (e) {
      debugPrint('Failed to initialize: $e');
    }
  }

  void _handleCallEvent(CallEvent event) {
    debugPrint('Call event: ${event.type}');

    switch (event.type) {
      case CallEventType.incomingCall:
        _showIncomingCallDialog(event);
        break;
      case CallEventType.callAccepted:
        debugPrint('Call accepted');
        break;
      case CallEventType.sessionStarted:
        setState(() => _activeSessionId = event.sessionId);
        _navigateToCallScreen(event);
        break;
      case CallEventType.callEnded:
        setState(() => _activeSessionId = null);
        Navigator.of(context).popUntil((route) => route.isFirst);
        break;
      case CallEventType.callFailed:
        _showErrorDialog(
            'Call failed: ${event.metadata?['error'] ?? 'Unknown error'}');
        break;
      default:
        break;
    }
  }

  void _showIncomingCallDialog(CallEvent event) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Incoming Call'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 40,
              backgroundImage: event.remoteUser?.userImage != null
                  ? NetworkImage(event.remoteUser!.userImage!)
                  : null,
              child: event.remoteUser?.userImage == null
                  ? Text(event.remoteUser?.userName.substring(0, 1) ?? '?')
                  : null,
            ),
            const SizedBox(height: 16),
            Text(
              event.remoteUser?.userName ?? 'Unknown',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            Text(
              '${event.callType?.name ?? 'Audio'} Call',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              RtcCommunicationService.instance.rejectCall(event.callId);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Decline'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              // Accept call - this will trigger sessionStarted event
              // which navigates to call screen
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  void _navigateToCallScreen(CallEvent event) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CallScreen(
          callId: event.callId,
          remoteUser: event.remoteUser,
          callType: event.callType ?? CallType.audio,
          sessionId: event.sessionId,
          roomId: event.roomId,
        ),
      ),
    );
  }

  void _handleChatEvent(ChatEvent event) {
    debugPrint('Chat event: ${event.type}');

    switch (event.type) {
      case ChatEventType.sessionStarted:
        setState(() => _activeSessionId = event.sessionId);
        break;
      case ChatEventType.sessionEnded:
        setState(() => _activeSessionId = null);
        break;
      case ChatEventType.messageReceived:
        debugPrint(
            'Message from ${event.message?.senderName}: ${event.message?.content}');
        break;
      default:
        break;
    }
  }

  void _openChatScreen() {
    if (_activeSessionId == null) {
      _showErrorDialog('No active session. Start or receive a call first.');
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ChatScreen(sessionId: _activeSessionId!),
      ),
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _setUser(String userId, String userName) async {
    await RtcCommunicationService.instance.setCurrentUser(
      UserInfo(
        userId: userId,
        userName: userName,
      ),
    );

    // The signaling server routes by userId, so it needs to know which socket
    // belongs to whom. The adapter re-sends this whenever it (re)connects, so
    // picking a user before the socket is up still works. Real backends
    // usually derive identity from the auth token during the handshake.
    _socketAdapter?.setUser(userId, userName: userName);

    setState(() {
      _currentUserId = userId;
    });
  }

  /// Request mic (and camera for video) before any media starts.
  ///
  /// Declaring the permissions in the manifest is not enough on Android 6+:
  /// without a runtime grant the ZEGO engine still joins the room and
  /// publishes an empty stream, so the call connects and carries nothing.
  Future<bool> _ensureCallPermissions({required bool isVideo}) async {
    final statuses = await [
      Permission.microphone,
      if (isVideo) Permission.camera,
      if (Platform.isAndroid) Permission.notification, // Android 13+
    ].request();

    // Notifications only affect the incoming-call UI, so do not block on them.
    final blocking = {
      Permission.microphone: statuses[Permission.microphone],
      if (isVideo) Permission.camera: statuses[Permission.camera],
    };
    final denied = blocking.entries
        .where((e) => e.value?.isGranted != true)
        .map((e) => e.key == Permission.camera ? 'Camera' : 'Microphone')
        .toList();

    if (denied.isEmpty) return true;

    final permanently = blocking.values.any((s) => s?.isPermanentlyDenied == true);
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${denied.join(' and ')} access needed'),
        content: Text(
          permanently
              ? 'Enable ${denied.join(' and ').toLowerCase()} access in Settings, '
                  'otherwise the call will connect but carry no media.'
              : 'Without it the call will connect but carry no media.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          if (permanently)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
        ],
      ),
    );
    return false;
  }

  Future<void> _startCall(String targetUserId, String targetUserName) async {
    if (!await _ensureCallPermissions(isVideo: true)) return;

    final result = await RtcCommunicationService.instance.startCall(
      targetUserId: targetUserId,
      targetUserName: targetUserName,
      callType: CallType.video,
    );

    if (result.success) {
      debugPrint('Call started: ${result.callId}');
    } else {
      _showErrorDialog('Failed to start call: ${result.error}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('RTC Call Kit Demo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // User section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Current User',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(_currentUserId ?? 'Not logged in'),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => _setUser('user_1', 'User 1'),
                            child: const Text('Login as User 1'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => _setUser('user_2', 'User 2'),
                            child: const Text('Login as User 2'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Call section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Start Call',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _currentUserId != null
                          ? () => _startCall(
                                _currentUserId == 'user_1'
                                    ? 'user_2'
                                    : 'user_1',
                                _currentUserId == 'user_1'
                                    ? 'User 2'
                                    : 'User 1',
                              )
                          : null,
                      icon: const Icon(Icons.video_call),
                      label: const Text('Start Video Call'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Chat section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'In-Session Chat',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _activeSessionId != null
                          ? 'Session: ${_activeSessionId!.substring(0, _activeSessionId!.length > 12 ? 12 : _activeSessionId!.length)}...'
                          : 'No active session',
                      style: TextStyle(
                        color: _activeSessionId != null
                            ? Colors.green
                            : Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed:
                          _activeSessionId != null ? _openChatScreen : null,
                      icon: const Icon(Icons.chat),
                      label: const Text('Open Chat'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Call screen widget
class CallScreen extends StatefulWidget {
  final String callId;
  final UserInfo? remoteUser;
  final CallType callType;
  final String? sessionId;
  final String? roomId;

  const CallScreen({
    super.key,
    required this.callId,
    this.remoteUser,
    required this.callType,
    this.sessionId,
    this.roomId,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _isMuted = false;
  bool _isCameraOn = true;
  bool _isSpeakerOn = true;

  /// The peer publishes as `Stream_<roomId>_<userId>_stream`, so the remote
  /// view can be addressed as soon as we know the room and who we are talking
  /// to — no need to wait for a stream-added callback.
  String? get _remoteStreamId {
    final roomId = widget.roomId;
    final peerId = widget.remoteUser?.userId;
    if (roomId == null || peerId == null) return null;
    return 'Stream_${roomId}_${peerId}_stream';
  }

  @override
  void initState() {
    super.initState();
    // Mark call as connected in CallKit
    RtcCommunicationService.instance.markCallConnected(widget.callId);
  }

  Future<void> _endCall() async {
    await RtcCommunicationService.instance.endCall();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Remote video (full screen)
          if (widget.callType == CallType.video)
            Positioned.fill(
              child: _remoteStreamId != null
                  ? RtcRemoteVideoView(streamId: _remoteStreamId!)
                  // Never render nothing: a bare black screen is impossible to
                  // tell apart from a video that failed to start.
                  : const ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: Text(
                          'Waiting for video…',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
            ),

          // Local video (small preview)
          if (widget.callType == CallType.video)
            Positioned(
              top: 80,
              right: 16,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: const SizedBox(
                  width: 100,
                  height: 150,
                  child: RtcLocalVideoView(),
                ),
              ),
            ),

          // User info
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Column(
              children: [
                if (widget.callType == CallType.audio)
                  CircleAvatar(
                    radius: 50,
                    backgroundImage: widget.remoteUser?.userImage != null
                        ? NetworkImage(widget.remoteUser!.userImage!)
                        : null,
                    child: widget.remoteUser?.userImage == null
                        ? Text(
                            widget.remoteUser?.userName.substring(0, 1) ?? '?',
                            style: const TextStyle(fontSize: 40),
                          )
                        : null,
                  ),
                const SizedBox(height: 16),
                Text(
                  widget.remoteUser?.userName ?? 'Unknown',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.callType == CallType.video
                      ? 'Video Call'
                      : 'Audio Call',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),

          // Call controls
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Mute button
                _CallButton(
                  icon: _isMuted ? Icons.mic_off : Icons.mic,
                  label: _isMuted ? 'Unmute' : 'Mute',
                  onPressed: () async {
                    await RtcCommunicationService.instance.toggleMute();
                    setState(() => _isMuted = !_isMuted);
                  },
                ),

                // Camera button (video calls only)
                if (widget.callType == CallType.video)
                  _CallButton(
                    icon: _isCameraOn ? Icons.videocam : Icons.videocam_off,
                    label: _isCameraOn ? 'Camera Off' : 'Camera On',
                    onPressed: () async {
                      await RtcCommunicationService.instance.toggleCamera();
                      setState(() => _isCameraOn = !_isCameraOn);
                    },
                  ),

                // Speaker button
                _CallButton(
                  icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                  label: _isSpeakerOn ? 'Speaker Off' : 'Speaker On',
                  onPressed: () async {
                    await RtcCommunicationService.instance.toggleSpeaker();
                    setState(() => _isSpeakerOn = !_isSpeakerOn);
                  },
                ),

                // Switch camera button (video calls only)
                if (widget.callType == CallType.video)
                  _CallButton(
                    icon: Icons.cameraswitch,
                    label: 'Switch',
                    onPressed: () async {
                      await RtcCommunicationService.instance.switchCamera();
                    },
                  ),

                // End call button
                _CallButton(
                  icon: Icons.call_end,
                  label: 'End',
                  color: Colors.red,
                  onPressed: _endCall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Call control button widget
class _CallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;

  const _CallButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color ?? Colors.white24,
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.white),
            onPressed: onPressed,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ],
    );
  }
}

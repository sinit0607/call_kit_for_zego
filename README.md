# Call Kit for ZEGO

Real-time audio/video calling for Flutter, built on ZEGOCLOUD, with native
CallKit on iOS and ConnectionService on Android for the incoming-call UI.

> Unofficial. Not affiliated with or endorsed by ZEGOCLOUD — it builds on their
> [`zego_express_engine`](https://pub.dev/packages/zego_express_engine) SDK.

[![Pub Version](https://img.shields.io/pub/v/call_kit_for_zego)](https://pub.dev/packages/call_kit_for_zego)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Features

- **Audio & Video Calling** - High-quality real-time communication using ZEGOCLOUD
- **In-Session Chat** - Text messaging with typing indicators and delivery/read receipts
- **Flexible CallKit Integration** - Choose between native CallKit UI or custom app UI
  - Native mode: Full-screen incoming call UI on locked screens (iOS/Android)
  - Custom mode: Complete control over call UI with your own design
- **Socket Agnostic** - Works with any WebSocket/Socket.IO implementation
- **State Machine** - Robust call state management with transition guards
- **Network Resilience** - Automatic reconnection with exponential backoff
- **Plugin Architecture** - Optional analytics, crash reporting, and call storage
- **WhatsApp-like UX** - 30-second ringing timeout, proper call lifecycle
- **Demo signaling server included** - a working Node server in [`demo_server/`](demo_server)
  so you can place a real call before writing any backend

## Table of Contents

- [Demo Server](#demo-server--place-a-real-call-in-5-minutes)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [CallKit Options](#callkit-options)
  - [Native CallKit Mode](#native-callkit-mode-default)
  - [Custom UI Mode](#custom-ui-mode)
- [Architecture](#architecture)
- [Configuration](#configuration)
- [Socket Integration](#socket-integration)
- [Handling Call Events](#handling-call-events)
- [Making and Receiving Calls](#making-and-receiving-calls)
- [In-Session Chat](#in-session-chat)
- [Platform Setup](#platform-setup)
  - [Android](#android)
  - [iOS](#ios)
  - [Runtime permissions are your app's job](#-runtime-permissions-are-your-apps-job)
- [Plugins](#plugins)
- [Advanced Usage](#advanced-usage)
- [Troubleshooting](#troubleshooting)

## Demo Server — place a real call in 5 minutes

This repo ships a **complete signaling server** in [`demo_server/`](demo_server),
so you can make a working call before writing any backend code.

Calling needs two halves: **media** (ZEGOCLOUD handles that) and **signaling** —
telling the other person "you have a call". This package is signaling-agnostic
on purpose, so *you* provide the second half. The demo server is a working
implementation you can call against today and copy from later.

> It is a **test harness, not a backend**: no auth, no database, everything
> lives in memory and dies with the process.

### 1. Start the server

```bash
cd demo_server
npm install
npm start
```

It listens on port 3000. Check it and see who is connected:

```bash
curl localhost:3000/health
```

### 2. Point the app at it

The example reads the URL from a `--dart-define`:

```bash
cd example
flutter run --dart-define=SIGNALING_URL=http://192.168.1.20:3000
```

| Where the app runs | URL to use |
| --- | --- |
| Android emulator | `http://10.0.2.2:3000` (the default) |
| iOS simulator | `http://localhost:3000` |
| **Real device** | `http://<your-machine-LAN-IP>:3000` |

Find your IP with `ipconfig getifaddr en0` (macOS) or `hostname -I` (Linux).
A real device must be on the same Wi-Fi as your machine.

> `10.0.2.2` is an **emulator-only** alias for your machine's localhost. On a
> physical device it resolves to nothing and you get
> `[SocketAdapter] Connection error: timeout`.

### 3. Make the call

Add your ZEGOCLOUD `appId` / `appSign` in `example/lib/main.dart` — signaling
works without them, but there will be no audio or video. Then launch the app on
**two devices**, pick a different user on each, and call.

Accept the microphone and camera prompts on both. A denied mic does not fail the
call — it publishes an empty stream, so you get a connected call with silence.

### Verify signaling without any devices

`npm test` in `demo_server/` drives two fake clients through a full call —
ring, accept, chat, hang up, plus the reject and offline paths — asserting the
exact field names the mapper reads:

```bash
cd demo_server && npm test
```

### Writing your own server

[`demo_server/README.md`](demo_server/README.md) documents the full protocol —
every event in both directions and its payload — plus the three things a real
backend must get right. Each of them fails *silently*, as a call that connects
and looks fine:

1. **`sessionStarted` must reach both parties, and it is what starts media.**
   The controller deliberately does not join the ZEGO room on the offer or the
   accept; it waits for your authoritative `roomId` here.
2. **Both parties need the identical `roomId`.** Two different ones means two
   people alone in two rooms, with the UI showing "connected" throughout.
3. **Never infer direction from `userId` / `listenerId`.** The mapper puts
   *whoever is emitting* in `userId`, so the callee occupies that field on
   `accept-request`. Look the call up by `requestId` instead.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  call_kit_for_zego: ^1.0.0
```

Then run:
```bash
flutter pub get
```

## Quick Start

### 1. Initialize the Service

```dart
import 'package:call_kit_for_zego/call_kit_for_zego.dart';

// Initialize the service
await RtcCommunicationService.initialize(
  config: CommunicationConfig(
    zegoConfig: ZegoConfig(
      appId: YOUR_ZEGO_APP_ID,      // From ZEGOCLOUD console
      appSign: 'YOUR_ZEGO_APP_SIGN', // From ZEGOCLOUD console
    ),
    socketConfig: SocketConfig(
      url: 'https://your-server.com',
    ),
    callKitConfig: CallKitConfig(
      appName: 'Your App Name',
      iconName: 'app_icon',  // Optional: custom icon for incoming call
    ),
    useCallKit: true,  // Optional: Use native CallKit (default: true)
  ),
  socketAdapter: YourSocketAdapter(),  // Your socket implementation
);

// Get the service instance
final rtcService = RtcCommunicationService.instance;
```

> 💡 **Note:** Set `useCallKit: false` to use your own custom incoming call UI instead of native CallKit. See [CallKit Options](#callkit-options).

### 2. Set Current User

```dart
rtcService.setCurrentUser(UserInfo(
  userId: 'user_123',
  userName: 'John Doe',
  userImage: 'https://example.com/avatar.jpg',
));
```

### 3. Listen to Events

```dart
// Listen to call events
rtcService.callEvents.listen((event) {
  switch (event.type) {
    case CallEventType.incomingCall:
      // Show incoming call UI (or let native CallKit handle it)
      break;
    case CallEventType.callAccepted:
      // Navigate to call screen
      break;
    case CallEventType.callEnded:
      // Clean up and navigate back
      break;
    case CallEventType.callDeclined:
      // Show "call declined" message
      break;
  }
});
```

### 4. Make a Call

```dart
await rtcService.startCall(
  calleeId: 'user_456',
  calleeName: 'Jane Smith',
  calleeImage: 'https://example.com/jane.jpg',
  callType: CallType.video,
);
```

### 5. Handle Incoming Calls

```dart
// Accept call
await rtcService.acceptCall();

// Reject call
await rtcService.rejectCall();
```

### 6. End Call

```dart
await rtcService.endCall();
```

## CallKit Options

The package offers two modes for handling incoming calls:

### Native CallKit Mode (Default)

When `useCallKit = true` (default), the package uses native iOS CallKit and Android ConnectionService to display full-screen incoming call UI, even on locked screens.

**Perfect for:**
- WhatsApp/Telegram-like call experience
- System-level call integration
- Calls that work on locked screens
- Less implementation work

**Configuration:**

```dart
await RtcCommunicationService.initialize(
  config: CommunicationConfig(
    zegoConfig: ZegoConfig(
      appId: YOUR_ZEGO_APP_ID,
      appSign: 'YOUR_ZEGO_APP_SIGN',
    ),
    socketConfig: SocketConfig(url: 'https://your-server.com'),
    callKitConfig: CallKitConfig(
      appName: 'My App',
      iconName: 'app_icon',
    ),
    useCallKit: true, // ✅ Native CallKit UI (default)
  ),
  socketAdapter: socketAdapter,
);
```

**What you get:**
- ✅ Full-screen incoming call on locked screen
- ✅ System ringtone
- ✅ Native accept/decline buttons
- ✅ iOS CallKit & Android ConnectionService integration
- ✅ Your callbacks still fire for navigation

### Custom UI Mode

When `useCallKit = false`, you have complete control over the incoming call UI using your own custom screens.

**Perfect for:**
- Fully custom call UI design
- Unique UX requirements
- Showing additional context on call screen
- Testing without native UI complexity

**Configuration:**

```dart
await RtcCommunicationService.initialize(
  config: CommunicationConfig(
    zegoConfig: ZegoConfig(
      appId: YOUR_ZEGO_APP_ID,
      appSign: 'YOUR_ZEGO_APP_SIGN',
    ),
    socketConfig: SocketConfig(url: 'https://your-server.com'),
    useCallKit: false, // ❌ No native CallKit - you handle UI
  ),
  socketAdapter: socketAdapter,
);

// Listen to events and show your custom UI
rtcService.callEvents.listen((event) {
  if (event.type == CallEventType.incomingCall) {
    // Show YOUR custom incoming call screen
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MyCustomIncomingCallScreen(
          callerName: event.callData?.caller.userName,
          callerImage: event.callData?.caller.avatarUrl,
          onAccept: () async {
            await rtcService.acceptCall();
            // Navigate to call screen
          },
          onReject: () async {
            await rtcService.rejectCall();
            Navigator.pop(context);
          },
        ),
      ),
    );
  }
});
```

**What you get:**
- ✅ Complete control over UI design
- ✅ Show custom info (caller bio, mutual friends, etc.)
- ✅ Custom animations and styling
- ✅ Easier testing and debugging
- ⚠️ Requires more implementation work
- ⚠️ Won't work on locked screen without push notifications

**Comparison:**

| Feature | Native CallKit (`true`) | Custom UI (`false`) |
|---------|------------------------|-------------------|
| Full-screen on locked screen | ✅ | ❌ |
| System integration | ✅ | ❌ |
| Custom UI design | Limited | ✅ Full control |
| Implementation complexity | ⭐ Easy | ⭐⭐⭐ More work |
| Works with system UI | ✅ | ❌ |

> 💡 **Tip:** Start with `useCallKit = false` during development for easier testing, then switch to `true` for production.

> 📖 **Full guide:** See [CallKit usage](#callkit-usage) below for detailed examples and a migration guide.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Your Flutter App                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐       ┌─────────────────────────────┐ │
│  │  Your Socket    │       │   RtcCommunicationService   │ │
│  │  (Socket.IO,    │──────▶│   (Main Entry Point)        │ │
│  │   WebSocket)    │       └─────────────────────────────┘ │
│  └─────────────────┘                    │                   │
│                                         │                   │
│          ┌──────────────────────────────┼──────────────┐   │
│          │                              │              │   │
│          ▼                              ▼              ▼   │
│  ┌───────────────┐          ┌───────────────┐  ┌──────────┐│
│  │ CallManager   │          │ SessionManager│  │ ChatMgr  ││
│  │ (Call Events) │          │ (User State)  │  │ (Text)   ││
│  └───────────────┘          └───────────────┘  └──────────┘│
│          │                                                  │
│          ▼                                                  │
│  ┌───────────────────────────────────────────────────────┐ │
│  │              RtcCallController                         │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────────┐ │ │
│  │  │ ZegoService │  │ StateManager│  │ NativeCallKit  │ │ │
│  │  │ (A/V Engine)│  │ (State M/C) │  │ (iOS/Android)  │ │ │
│  │  └─────────────┘  └─────────────┘  └────────────────┘ │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

### ZegoConfig

```dart
ZegoConfig(
  appId: 123456789,           // Required: Your ZEGOCLOUD App ID
  appSign: 'your_app_sign',   // Required: Your ZEGOCLOUD App Sign
)
```

### CallKitConfig

```dart
CallKitConfig(
  appName: 'My App',              // Shown on incoming call screen
  iconName: 'app_icon',           // Icon resource name (optional)
  ringtoneSound: 'ringtone.mp3',  // Custom ringtone (optional)
  duration: 30000,                // Ring duration in ms (default: 30s)
  textAccept: 'Accept',           // Accept button text
  textDecline: 'Decline',         // Decline button text
  missedCallNotification: true,   // Show missed call notification
  android: AndroidCallKitConfig(
    isShowLogo: true,
    isShowFullLockedScreen: true,
  ),
  ios: IOSCallKitConfig(
    supportsVideo: true,
    maximumCallGroups: 1,
  ),
)
```

### CommunicationConfig

```dart
CommunicationConfig(
  zegoConfig: ZegoConfig(...),       // Required: ZEGO configuration
  socketConfig: SocketConfig(...),   // Required: Socket configuration
  callKitConfig: CallKitConfig(...), // Optional: CallKit configuration
  useCallKit: true,                  // Optional: Enable/disable native CallKit (default: true)
  signalingMapper: MyCustomMapper(), // Optional: Custom signaling mapper
  enableLogging: true,               // Optional: Enable debug logs (default: true)
  logLevel: LogLevel.info,           // Optional: Log level (default: info)
)
```

**useCallKit parameter:**
- `true` (default): Native CallKit handles incoming call UI
- `false`: Your app handles UI using callbacks
- See [CallKit Options](#callkit-options) section for detailed comparison

### RtcCallConfig (Advanced)

```dart
RtcCallConfig(
  // Call lifecycle
  ringingTimeout: Duration(seconds: 30),        // Auto-cancel if unanswered

  // Reconnection (exponential backoff: 2s, 4s, 8s, 16s, 30s)
  reconnectRetryCount: 5,
  reconnectBackoff: Duration(seconds: 2),
  maxReconnectBackoff: Duration(seconds: 30),

  // Audio
  audioBitrate: 48,                             // kbps
  enableEchoCancellation: true,                 // AEC
  enableNoiseSuppression: true,                 // ANS
  enableAutoGainControl: true,                  // AGC

  // Video (defaults are portrait HD, matching phone screens)
  videoBitrate: 2000,                           // kbps
  videoWidth: 720,
  videoHeight: 1280,

  // Diagnostics
  enableLogs: true,
  logLevel: RtcLogLevel.info,                   // verbose | info | warning | error
  enableAudioDebug: false,                      // Detailed audio pipeline logs
  audioDebugInProduction: false,                // Keep those logs in release builds
)
```

Two presets are provided:

```dart
RtcCallConfig.development()  // verbose logging, 60s ringing timeout
RtcCallConfig.production()   // info logging, 30s ringing timeout
```

## Socket Integration

The package is socket-agnostic. You need to provide a `SocketAdapter` that wraps your socket implementation.

### SocketAdapter Interface

```dart
abstract class SocketAdapter {
  /// Whether socket is currently connected
  bool get isConnected;

  /// Register event listener
  void on(String event, Function(dynamic) callback);

  /// Remove event listener
  void off(String event);

  /// Emit event with data
  void emit(String event, dynamic data);
}
```

### Socket.IO Implementation Example

```dart
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:call_kit_for_zego/call_kit_for_zego.dart';

class SocketIOAdapter implements SocketAdapter {
  final IO.Socket _socket;

  SocketIOAdapter(this._socket);

  @override
  bool get isConnected => _socket.connected;

  @override
  void on(String event, Function(dynamic) callback) {
    _socket.on(event, callback);
  }

  @override
  void off(String event) {
    _socket.off(event);
  }

  @override
  void emit(String event, dynamic data) {
    _socket.emit(event, data);
  }
}

// Usage
final socket = IO.io('https://your-server.com', IO.OptionBuilder()
  .setTransports(['websocket'])
  .enableAutoConnect()
  .build());

final adapter = SocketIOAdapter(socket);
await rtcService.initialize(
  config: config,
  socketAdapter: adapter,
);
```

### Custom Signaling Mapper

If your backend uses different event names/formats, implement `SignalingMapper`:

```dart
class MyBackendMapper implements SignalingMapper {
  @override
  List<String> get incomingEventNames => [
    'receiveChatRequest',    // Your incoming call event
    'requestAccepted',       // Your call accepted event
    'requestRejected',       // Your call rejected event
    'sessionStarted',        // Your session started event
    'sessionEnded',          // Your session ended event
  ];

  @override
  RtcSignalingEvent? mapIncomingEvent(String eventName, Map<String, dynamic> data) {
    switch (eventName) {
      case 'receiveChatRequest':
        return RtcSignalingEvent.callOffer(
          callId: data['requestId'] ?? _generateId(data),
          fromUserId: data['userId'],
          toUserId: data['listenerId'],
          callType: data['type'] == 'video' ? 'video' : 'audio',
          roomId: data['roomId'],
          metadata: {
            'senderName': data['userName'],
            'senderImage': data['userImage'],
          },
        );
      // ... handle other events
    }
    return null;
  }

  @override
  SignalingEmitData mapOutgoingEvent(RtcSignalingEvent event, {...}) {
    // Map outgoing events to your backend format
  }

  @override
  String getEventName(RtcSignalingEventType type) {
    switch (type) {
      case RtcSignalingEventType.callOffer:
        return 'chat-request';
      case RtcSignalingEventType.callAnswer:
        return 'accept-request';
      case RtcSignalingEventType.callReject:
        return 'reject-request';
      case RtcSignalingEventType.callEnd:
        return 'session-end';
      // ...
    }
  }
}

// Use custom mapper
await rtcService.initialize(
  config: config,
  socketAdapter: adapter,
  signalingMapper: MyBackendMapper(),
);
```

## Handling Call Events

All call events are emitted through the `callEvents` stream, regardless of whether you're using native CallKit (`useCallKit: true`) or custom UI (`useCallKit: false`). This allows you to navigate to appropriate screens and handle UI updates.

> 💡 **Important:** With `useCallKit: false`, you must handle the incoming call UI yourself by listening to `CallEventType.incomingCall` and showing your custom screen.

### CallEvent Types

```dart
rtcService.callEvents.listen((event) {
  switch (event.type) {
    case CallEventType.incomingCall:
      final callId = event.callId;
      final caller = event.remoteUser;
      print('Incoming call from ${caller?.userName}');

      // If useCallKit = false, show your custom incoming call screen here
      if (!usingCallKit) {
        showCustomIncomingCallScreen(event.callData);
      }
      break;

    case CallEventType.outgoingCall:
      print('Call initiated, waiting for answer...');
      break;

    case CallEventType.callAccepted:
      print('Call accepted, connecting...');
      // Navigate to call screen
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => CallScreen(callId: event.callId),
      ));
      break;

    case CallEventType.callConnected:
      print('Call connected!');
      break;

    case CallEventType.callDeclined:
      print('Call was declined');
      break;

    case CallEventType.callEnded:
      print('Call ended: ${event.reason}');
      Navigator.pop(context);
      break;

    case CallEventType.callFailed:
      print('Call failed: ${event.error}');
      break;

    case CallEventType.callMissed:
      print('Missed call from ${event.remoteUser?.userName}');
      break;

    case CallEventType.remoteUserJoined:
      print('Remote user joined');
      break;

    case CallEventType.remoteUserLeft:
      print('Remote user left');
      break;
  }
});
```

## Making and Receiving Calls

### Start an Outgoing Call

```dart
try {
  await rtcService.startCall(
    calleeId: 'user_456',
    calleeName: 'Jane Smith',
    calleeImage: 'https://example.com/jane.jpg',
    callType: CallType.video,  // or CallType.audio
  );
  // Show outgoing call UI
} catch (e) {
  print('Failed to start call: $e');
}
```

### Accept Incoming Call

```dart
// When user taps "Accept" (or handled automatically by CallKit)
await rtcService.acceptCall();
```

### Reject Incoming Call

```dart
// When user taps "Decline"
await rtcService.rejectCall();
```

### End Active Call

```dart
await rtcService.endCall();
```

### In-Call Controls

```dart
// Toggle mute
await rtcService.toggleMute();
bool isMuted = rtcService.isMuted;

// Toggle camera
await rtcService.toggleCamera();
bool isCameraOn = rtcService.isCameraOn;

// Switch camera (front/back)
await rtcService.switchCamera();

// Toggle speaker
await rtcService.toggleSpeaker();
```

## Video Widget

Display local and remote video:

```dart
// In your call screen widget
@override
Widget build(BuildContext context) {
  return Stack(
    children: [
      // Remote video (full screen)
      Positioned.fill(
        child: RtcVideoView(
          userId: remoteUserId,
          isLocal: false,
        ),
      ),

      // Local video (picture-in-picture)
      Positioned(
        top: 50,
        right: 20,
        width: 120,
        height: 160,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: RtcVideoView(
            userId: localUserId,
            isLocal: true,
          ),
        ),
      ),
    ],
  );
}
```

## In-Session Chat

The package includes a built-in chat system for sending text messages during active sessions. Chat works over the same socket connection used for call signaling.

### Chat Features

- Send and receive text messages
- Typing indicators (is typing / stopped typing)
- Message status tracking: `sending` → `sent` → `delivered` → `read`
- Message deduplication (prevents duplicate processing)
- Session-aware messaging (tied to call sessions)

### Listening to Chat Events

```dart
rtcService.chatEvents.listen((event) {
  switch (event.type) {
    case ChatEventType.messageReceived:
      // New message from remote user
      final message = event.message!;
      print('${message.senderName}: ${message.content}');
      break;

    case ChatEventType.messageSent:
      // Message successfully sent
      print('Sent: ${event.message?.content}');
      break;

    case ChatEventType.messageDelivered:
      // Message delivered to recipient
      final messageId = event.metadata?['messageId'];
      print('Delivered: $messageId');
      break;

    case ChatEventType.messageRead:
      // Message read by recipient
      final messageIds = event.metadata?['messageIds'];
      print('Read: $messageIds');
      break;

    case ChatEventType.typingIndicator:
      // Remote user is typing
      final isTyping = event.metadata?['isTyping'] as bool;
      final userName = event.user?.userName;
      print('$userName is ${isTyping ? "typing..." : "idle"}');
      break;

    case ChatEventType.sessionStarted:
      print('Chat session started: ${event.sessionId}');
      break;

    case ChatEventType.sessionEnded:
      print('Chat session ended: ${event.sessionId}');
      break;
  }
});
```

### Sending Messages

```dart
// Send a text message
final result = await rtcService.sendMessage(
  sessionId: 'session_123',
  content: 'Hello! How are you?',
);

if (result.success) {
  print('Message sent: ${result.message?.messageId}');
} else {
  print('Failed: ${result.error}');
}
```

### Typing Indicators

```dart
// Notify that the user started typing
await rtcService.sendTypingIndicator(
  sessionId: 'session_123',
  isTyping: true,
);

// Notify that the user stopped typing
await rtcService.sendTypingIndicator(
  sessionId: 'session_123',
  isTyping: false,
);
```

### Session Management

```dart
// Set the active chat session (auto-set when a call session starts)
rtcService.setCurrentChatSession('session_123');

// Get the current chat session ID
final sessionId = rtcService.currentChatSessionId;
```

### Chat Socket Events

The chat system uses these socket events by default:

| Direction | Socket Event | Description |
|---|---|---|
| Incoming | `receiveMessage` | New message from remote user |
| Incoming | `messageDelivered` | Delivery confirmation |
| Incoming | `messageRead` | Read receipt |
| Incoming | `typing` | Typing indicator |
| Outgoing | `sendMessage` | Send a message |
| Outgoing | `typing` | Send typing indicator |

### ChatEvent Types

| Type | Description |
|------|-------------|
| `sessionStarted` | Chat session started |
| `sessionEnded` | Chat session ended |
| `messageReceived` | New message received |
| `messageSent` | Message successfully sent |
| `messageDelivered` | Message delivered to server |
| `messageRead` | Message read by recipient |
| `messageFailed` | Message failed to send |
| `typingIndicator` | Remote user typing status |

### MessageStatus

| Status | Description |
|--------|-------------|
| `sending` | Message is being sent |
| `sent` | Message sent to server |
| `delivered` | Message delivered to recipient |
| `read` | Message read by recipient |
| `failed` | Message failed to send |

> 📖 **Widget:** The package ships a ready-made chat UI in [lib/src/widgets/chat_screen.dart](lib/src/widgets/chat_screen.dart) — message bubbles, typing indicators and status icons included.

## Platform Setup

`call_kit_for_zego` is a pure-Dart package — it has no `android/` or `ios/` folder of
its own. Everything below is configuration your **app** owns. The example app
under `example/` is a working reference for all of it.

### Android

**Permissions are mostly automatic.** `flutter_callkit_incoming` ships its own
`AndroidManifest.xml`, and the Gradle manifest merger folds it into your app.
You get these without doing anything:

`INTERNET` · `RECORD_AUDIO` · `CAMERA` · `POST_NOTIFICATIONS` ·
`MANAGE_OWN_CALLS` · `USE_FULL_SCREEN_INTENT` · `FOREGROUND_SERVICE` ·
`FOREGROUND_SERVICE_PHONE_CALL` · `FOREGROUND_SERVICE_CAMERA` ·
`FOREGROUND_SERVICE_MICROPHONE` · `WAKE_LOCK` · `VIBRATE` ·
`DISABLE_KEYGUARD` · `TURN_SCREEN_ON` · `ACCESS_NOTIFICATION_POLICY`

Add to `android/app/src/main/AndroidManifest.xml` only what the merger does not
give you:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Not in the plugin manifest; needed for the speaker/earpiece toggle -->
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />

    <!-- Keeps audio-only devices eligible on the Play Store -->
    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.microphone" android:required="false" />

    <application>
        <activity
            android:name=".MainActivity"
            android:launchMode="singleTop"
            android:showWhenLocked="true"
            android:turnScreenOn="true">
        </activity>
    </application>
</manifest>
```

> ### ⚠️ Delete `android:taskAffinity=""` from MainActivity
>
> `flutter create` puts it there by default, and it **breaks accepting a call**.
> `flutter_callkit_incoming` launches your MainActivity with
> `FLAG_ACTIVITY_NEW_TASK` when the user accepts. With an empty task affinity
> Android cannot reuse the running task, so it starts a **second MainActivity
> in a second task**: a brand-new route stack that shows a black screen while
> the real call screen sits in the original task, plus a duplicate entry in
> the recents switcher.
>
> Removing the attribute lets the activity share the app's default affinity, so
> the running task is brought forward instead.

In `android/app/build.gradle.kts`:

```kotlin
android {
    defaultConfig {
        // The full-screen incoming-call UI needs API 23+
        minSdk = maxOf(flutter.minSdkVersion, 23)
    }
}
```

**Required Gradle workaround.** `zego_express_engine` 3.25.0 still declares
`compileSdkVersion 31`, while its own AndroidX dependencies require 33+. Without
this, *any* app depending on it fails to build with
`Dependency 'androidx.window.extensions.core:core:1.0.0' requires ... version 33 or later`.
Add to `android/build.gradle.kts`, **above** the existing
`subprojects { project.evaluationDependsOn(":app") }` block:

```kotlin
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            val android = ext as com.android.build.gradle.BaseExtension
            if (android.compileSdkVersion?.substringAfter("android-")?.toIntOrNull()
                    ?.let { it < 35 } == true) {
                android.compileSdkVersion(35)
            }
        }
    }
}
```

Order matters — placed after `evaluationDependsOn`, Gradle fails with
`Cannot run Project.afterEvaluate(Action) when the project is already evaluated`.

### iOS

Add to `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is required to make and receive calls.</string>

<key>NSCameraUsageDescription</key>
<string>Camera access is required for video calls.</string>

<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>voip</string>
    <string>remote-notification</string>
    <string>fetch</string>
</array>
```

Then in Xcode (`ios/Runner.xcworkspace` → Signing & Capabilities), add:
- **Push Notifications**
- **Background Modes** → Audio/AirPlay/PiP, Voice over IP, Background fetch,
  Remote notifications

### ⚠️ Runtime permissions are your app's job

**This is the single most common cause of "the call connects but there is no
audio."** Declaring `RECORD_AUDIO` in the manifest is not the same as being
granted it. Android 6+ requires a runtime grant, and neither ZEGOCLOUD nor
`flutter_callkit_incoming` requests microphone or camera access for you.

If the permission is missing, the ZEGO engine still joins the room and still
publishes a stream — a **silent** one. Both sides show a connected call and
nothing in the logs looks wrong.

Request the permissions before calling `startCall()` or `acceptCall()`. Any
permission plugin works; `permission_handler` is the usual choice — it is
deliberately *not* a dependency of this package, so you are free to use
whatever your app already has:

```dart
import 'package:permission_handler/permission_handler.dart';

Future<bool> ensureCallPermissions({required bool isVideo}) async {
  final needed = <Permission>[
    Permission.microphone,
    if (isVideo) Permission.camera,
    if (Platform.isAndroid) Permission.notification, // Android 13+
  ];

  final results = await needed.request();
  return results.values.every((s) => s.isGranted);
}

// Before starting or accepting a call:
if (!await ensureCallPermissions(isVideo: callType == CallType.video)) {
  // Show your own "permissions required" UI — do not start the call.
  return;
}
await rtcService.startCall(/* ... */);
```

On Android, also request the full-screen-intent permission once at startup so
incoming calls can appear over the lock screen:

```dart
if (Platform.isAndroid) {
  await FlutterCallkitIncoming.requestFullIntentPermission();
}
```

**The package verifies, even though it cannot request.** If the engine reports
that a device was never authorized, `call_kit_for_zego` surfaces a
`CallError.permissionDenied` on its error stream rather than letting the call
fail silently. Listen for it:

```dart
rtcService.errors.listen((error) {
  if (error.code == CallError.codePermissionDenied) {
    // Mic or camera was never granted, or was revoked mid-call.
  }
});
```

This also fires for a mic that is unavailable for other reasons — occupied by
another app, or taken over by Siri mid-call.

## Plugins

### Analytics Plugin

Track call metrics with your analytics service:

```dart
class FirebaseAnalyticsPlugin implements AnalyticsPlugin {
  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  @override
  Future<void> logCallStarted({
    required String callId,
    required String callType,
    required String callerId,
    required String calleeId,
    bool isOutgoing = true,
  }) async {
    await _analytics.logEvent(
      name: 'call_started',
      parameters: {
        'call_id': callId,
        'call_type': callType,
        'is_outgoing': isOutgoing,
      },
    );
  }

  // Implement other methods...
}

// Register plugin
rtcService.registerPlugin(FirebaseAnalyticsPlugin());
```

### Crash Reporting Plugin

Report call errors to your crash reporting service:

```dart
class FirebaseCrashlyticsPlugin implements CrashReportingPlugin {
  final FirebaseCrashlytics _crashlytics = FirebaseCrashlytics.instance;

  @override
  Future<void> recordError(
    dynamic error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) async {
    await _crashlytics.recordError(
      error,
      stackTrace,
      reason: reason,
      fatal: fatal,
    );
  }

  // Implement other methods...
}

rtcService.registerPlugin(FirebaseCrashlyticsPlugin());
```

### Call Storage Plugin

Persist call history:

```dart
class HiveCallStoragePlugin implements CallStoragePlugin {
  final Box<CallRecord> _callBox;

  @override
  Future<void> saveCallToHistory(CallRecord record) async {
    await _callBox.put(record.callId, record);
  }

  // Implement other methods...
}

rtcService.registerPlugin(HiveCallStoragePlugin(callBox));
```

## Advanced Usage

### Custom Call State Handling

```dart
rtcService.onStateChanged = (CallState oldState, CallState newState) {
  print('State changed: $oldState → $newState');

  // Custom handling based on state
  if (newState == CallState.connecting) {
    showConnectingOverlay();
  } else if (newState == CallState.connected) {
    hideConnectingOverlay();
    startCallTimer();
  }
};
```

### Network Reconnection

The package automatically handles network reconnection. You can customize behavior:

```dart
rtcService.onReconnecting = () {
  showReconnectingBanner();
};

rtcService.onReconnected = () {
  hideReconnectingBanner();
};

rtcService.onReconnectFailed = () {
  showReconnectFailedDialog();
};
```

### Call Duration Timer

```dart
// Access current call duration
final duration = rtcService.currentCallDuration;
print('Call duration: ${duration.inMinutes}:${duration.inSeconds % 60}');

// Or listen to duration updates
rtcService.durationStream.listen((duration) {
  updateDurationUI(duration);
});
```

## Troubleshooting

### Common Issues

**1. Incoming call not showing on locked screen (Android)**
- Ensure `USE_FULL_SCREEN_INTENT` permission is declared
- Call `FlutterCallkitIncoming.requestFullIntentPermission()` at app start
- Check that `showOnLockScreen` and `turnScreenOn` are set in Activity

**2. No audio after call connects**
- Check microphone permission is granted
- Ensure ZEGO credentials are correct
- Verify both users joined the same roomId

**3. Call state stuck**
- Enable debug logging: `RtcLogger.setLogLevel(LogLevel.debug)`
- Check socket connection status
- Verify signaling events are being received

**4. CallKit not dismissing when call is cancelled**
- Ensure `endCall()` is called with correct callId
- Check that socket events are properly mapped

**5. Want to test without native CallKit complexity**
- Set `useCallKit: false` in CommunicationConfig
- Implement custom incoming call UI using `onIncomingCall` callback
- Call `rtcService.acceptCall()` or `rtcService.rejectCall()` from your UI
- See [CallKit Options](#callkit-options) for complete example

**6. Incoming call not showing (useCallKit: false)**
- Verify you're listening to `rtcService.callEvents` stream
- Check that you show your custom UI in `CallEventType.incomingCall` handler
- Ensure your incoming call screen calls `acceptCall()` or `rejectCall()`

### Debug Logging

```dart
// Enable verbose logging
RtcLogger.setLogLevel(LogLevel.debug);

// Logs will show:
// [RtcCallKit] INFO: Initializing...
// [RtcCallKit] DEBUG: Socket event received: incoming_call
// [RtcCallKit] INFO: State transition: idle → ringing
```

## API Reference

### RtcCommunicationService

| Method | Description |
|--------|-------------|
| `initialize()` | Initialize the service with config |
| `setCurrentUser()` | Set the current user |
| `startCall()` | Initiate an outgoing call |
| `acceptCall()` | Accept incoming call |
| `rejectCall()` | Reject incoming call |
| `endCall()` | End active call |
| `toggleMute()` | Toggle microphone |
| `toggleCamera()` | Toggle camera |
| `switchCamera()` | Switch front/back camera |
| `sendMessage()` | Send a chat message |
| `sendTypingIndicator()` | Send typing indicator |
| `setCurrentChatSession()` | Set active chat session |
| `dispose()` | Clean up resources |

### CallEvent Types

| Type | Description |
|------|-------------|
| `incomingCall` | Received incoming call |
| `outgoingCall` | Outgoing call initiated |
| `callAccepted` | Call was accepted |
| `callConnected` | Both parties connected |
| `callDeclined` | Call was declined |
| `callEnded` | Call ended normally |
| `callFailed` | Call failed with error |
| `callMissed` | Call was missed (timeout) |
| `remoteUserJoined` | Remote user joined room |
| `remoteUserLeft` | Remote user left room |

### CallState

| State | Description |
|-------|-------------|
| `idle` | No active call |
| `initiating` | Starting outgoing call |
| `ringing` | Waiting for answer |
| `connecting` | Call accepted, connecting |
| `connected` | Call active |
| `reconnecting` | Reconnecting after network loss |
| `ended` | Call ended |
| `failed` | Call failed |

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome — please open an issue before starting significant work.

## Support

- [Issue Tracker](https://github.com/sinit0607/call_kit_for_zego/issues)
- [CallKit usage](#callkit-usage) - Native vs custom UI, below
- [ZEGOCLOUD Documentation](https://docs.zegocloud.com/)

---

# CallKit usage


## Overview

The `useCallKit` flag allows you to control whether native CallKit UI is used or if your app handles the call UI manually.

## Configuration

### Option 1: Use Native CallKit (Default)

When `useCallKit = true` (default), the native CallKit UI handles incoming calls with full-screen notification even on locked screens.

```dart
await RtcCommunicationService.initialize(
  config: CommunicationConfig(
    zegoConfig: ZegoConfig(
      appId: YOUR_ZEGO_APP_ID,
      appSign: 'YOUR_ZEGO_APP_SIGN',
    ),
    socketConfig: SocketConfig(url: 'https://your-server.com'),
    callKitConfig: CallKitConfig(
      appName: 'My App',
      iconName: 'app_icon',
    ),
    useCallKit: true, // ✅ Native CallKit handles UI
  ),
  socketAdapter: socketAdapter,
);
```

**What happens:**
- ✅ Native full-screen incoming call UI on iOS/Android
- ✅ Works on locked screen
- ✅ System ringtone plays
- ✅ User accepts/declines via native UI
- ✅ Your callbacks (`onIncomingCall`, `onCallAccepted`, etc.) still fire for navigation

### Option 2: Custom App UI

When `useCallKit = false`, your app handles all call UI using callbacks.

```dart
await RtcCommunicationService.initialize(
  config: CommunicationConfig(
    zegoConfig: ZegoConfig(
      appId: YOUR_ZEGO_APP_ID,
      appSign: 'YOUR_ZEGO_APP_SIGN',
    ),
    socketConfig: SocketConfig(url: 'https://your-server.com'),
    callKitConfig: CallKitConfig(  // Optional: still provide config for reference
      appName: 'My App',
    ),
    useCallKit: false, // ❌ CallKit disabled - app handles UI
  ),
  socketAdapter: socketAdapter,
);
```

**What happens:**
- ❌ No native CallKit UI
- ✅ `onIncomingCall` callback fires
- ✅ You show your custom incoming call screen
- ✅ User accepts/declines via your UI
- ✅ You call `rtcService.acceptCall()` or `rtcService.rejectCall()`

## Implementation Example

### With Custom UI (useCallKit = false)

```dart
class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late RtcCommunicationService rtcService;

  @override
  void initState() {
    super.initState();
    _initializeRTC();
  }

  Future<void> _initializeRTC() async {
    await RtcCommunicationService.initialize(
      config: CommunicationConfig(
        zegoConfig: ZegoConfig(
          appId: YOUR_APP_ID,
          appSign: 'YOUR_APP_SIGN',
        ),
        socketConfig: SocketConfig(url: 'https://your-server.com'),
        useCallKit: false, // Custom UI mode
      ),
      socketAdapter: socketAdapter,
    );

    rtcService = RtcCommunicationService.instance;

    // Listen to call events
    rtcService.callEvents.listen((event) {
      switch (event.type) {
        case CallEventType.incomingCall:
          // Show YOUR custom incoming call screen
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CustomIncomingCallScreen(
                callData: event.callData,
                onAccept: () async {
                  await rtcService.acceptCall();
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => CallScreen()),
                  );
                },
                onReject: () async {
                  await rtcService.rejectCall();
                  Navigator.pop(context);
                },
              ),
            ),
          );
          break;

        case CallEventType.callEnded:
          Navigator.popUntil(context, (route) => route.isFirst);
          break;

        // Handle other events...
      }
    });
  }
}

// Your custom incoming call screen
class CustomIncomingCallScreen extends StatelessWidget {
  final CallData callData;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const CustomIncomingCallScreen({
    required this.callData,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black87,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 60,
              backgroundImage: NetworkImage(callData.caller.avatarUrl ?? ''),
            ),
            SizedBox(height: 24),
            Text(
              '${callData.caller.userName} is calling...',
              style: TextStyle(color: Colors.white, fontSize: 24),
            ),
            SizedBox(height: 48),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Reject button
                IconButton(
                  icon: Icon(Icons.call_end, size: 40),
                  color: Colors.red,
                  onPressed: onReject,
                ),
                // Accept button
                IconButton(
                  icon: Icon(Icons.call, size: 40),
                  color: Colors.green,
                  onPressed: onAccept,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

## Comparison

| Feature | `useCallKit = true` | `useCallKit = false` |
|---------|-------------------|---------------------|
| Native full-screen UI | ✅ Yes | ❌ No |
| Works on locked screen | ✅ Yes | ❌ No (requires push notification) |
| System ringtone | ✅ Yes | ❌ No (you handle audio) |
| Custom UI design | ❌ Limited | ✅ Full control |
| iOS CallKit integration | ✅ Yes | ❌ No |
| Android ConnectionService | ✅ Yes | ❌ No |
| Implementation complexity | ⭐ Easy | ⭐⭐⭐ More work |

## Use Cases

### When to use `useCallKit = true` (Native UI)
- ✅ You want WhatsApp/Telegram-like native call experience
- ✅ Calls must work on locked screens
- ✅ You want system-level call integration
- ✅ Less implementation work

### When to use `useCallKit = false` (Custom UI)
- ✅ You need fully custom call UI design
- ✅ You want to show additional info on incoming call screen
- ✅ Your app has unique UX requirements
- ✅ You're okay with more implementation work
- ✅ Testing/debugging without native UI complexity

## Migration

If you have existing code using CallKit, nothing changes by default:

```dart
// Old code - still works the same
await RtcCommunicationService.initialize(
  config: CommunicationConfig(
    callKitConfig: CallKitConfig(appName: 'My App'),
    // useCallKit defaults to true
  ),
);
```

To switch to custom UI:

```dart
// New code - custom UI mode
await RtcCommunicationService.initialize(
  config: CommunicationConfig(
    callKitConfig: CallKitConfig(appName: 'My App'),
    useCallKit: false, // 🔄 Add this line
  ),
);

// Then implement your custom incoming call UI
rtcService.callEvents.listen((event) {
  if (event.type == CallEventType.incomingCall) {
    showYourCustomIncomingCallScreen();
  }
});
```

## Important Notes

1. **Callbacks always fire**: Regardless of `useCallKit` setting, all callbacks (`onIncomingCall`, `onCallAccepted`, `onCallEnded`, etc.) always fire. This allows you to navigate to the appropriate screens.

2. **Background calls**: When `useCallKit = false`, incoming calls won't work on locked screens without additional push notification setup.

3. **Testing**: Set `useCallKit = false` during development to test without native UI complexity.

4. **Platform support**:
   - iOS: Native CallKit fully supported
   - Android: Native ConnectionService fully supported
   - Both work with `useCallKit = false`

## Questions?

If you have questions, check the main [README.md](README.md) or open an issue.

---

# CallKit flag history


## Overview
Added `useCallKit` boolean flag to make native CallKit UI optional. When disabled, the app handles call UI using callbacks.

## Changes Made

### 1. **RtcCallController** (`lib/src/controllers/rtc_call_controller.dart`)

#### Added Fields
```dart
final bool useCallKit; // Flag to enable/disable CallKit (line 47)
```

#### Constructor Changes
```dart
RtcCallController({
  // ... existing parameters
  this.useCallKit = true, // NEW: Default to true (backward compatible)
  // ...
})
```

#### Initialization Logic
- Only initializes CallKit when BOTH conditions are true:
  - `nativeCallKitConfig != null`
  - `useCallKit == true`

#### Updated Methods
All methods that interact with CallKit now check the flag:

- `init()` - Only initializes CallKit if `useCallKit == true`
- `receiveIncomingCall()` - Only shows CallKit UI if `useCallKit == true`
  - **Important**: `onIncomingCall` callback ALWAYS fires regardless of flag
- `rejectCall()` - Only ends CallKit if `useCallKit == true`
- `endCall()` - Only ends CallKit if `useCallKit == true`
- `markCallConnected()` - Only marks CallKit connected if `useCallKit == true`
- `_handleCallAnswerEvent()` - Only marks CallKit connected if `useCallKit == true`
- `_handleCallRejectEvent()` - Only ends CallKit if `useCallKit == true`
- `_handleCallCancelEvent()` - Only ends CallKit if `useCallKit == true`
- `dispose()` - Only disposes CallKit if `useCallKit == true`

### 2. **CommunicationConfig** (`lib/src/api/models/communication_config.dart`)

#### Added Field
```dart
/// Enable native CallKit UI
/// When true: Native CallKit handles incoming call UI
/// When false: App handles UI using callbacks (onIncomingCall, etc.)
/// Default: true (use CallKit if config is provided)
final bool useCallKit;
```

#### Constructor Changes
```dart
const CommunicationConfig({
  // ... existing parameters
  this.useCallKit = true, // NEW: Default to true
  // ...
});
```

### 3. **RtcCommunicationService** (`lib/src/api/rtc_communication_service.dart`)

#### Updated Initialization
```dart
_rtcController = RtcCallController(
  // ... existing parameters
  useCallKit: _config.useCallKit, // NEW: Pass through from config
  // ...
);
```

### 4. **Bug Fixes**

#### Fixed Syntax Error (line 365)
```dart
// Before
} else{

// After
} else {
```

### 5. **Documentation**

Documented in the [CallKit usage](#callkit-usage) section of this README.
- Comprehensive guide on using the new flag
- Code examples for both modes
- Comparison table
- Migration guide
- Use case recommendations

## Backward Compatibility

✅ **100% Backward Compatible**

Default value is `true`, so existing code continues to work exactly as before:

```dart
// Existing code - no changes needed
await RtcCommunicationService.initialize(
  config: CommunicationConfig(
    callKitConfig: CallKitConfig(appName: 'My App'),
    // useCallKit defaults to true
  ),
);
```

## Usage Examples

### Native CallKit (Default)
```dart
CommunicationConfig(
  callKitConfig: CallKitConfig(appName: 'My App'),
  useCallKit: true, // or omit - defaults to true
)
```

### Custom App UI
```dart
CommunicationConfig(
  callKitConfig: CallKitConfig(appName: 'My App'),
  useCallKit: false, // CallKit disabled
)

// Handle incoming calls in your app
rtcService.callEvents.listen((event) {
  if (event.type == CallEventType.incomingCall) {
    showMyCustomIncomingCallScreen();
  }
});
```

## Benefits

1. **Flexibility**: Developers can choose native or custom UI
2. **Testing**: Easier to test without native UI complexity
3. **Custom UX**: Full control over call UI design
4. **Backward Compatible**: No breaking changes
5. **Clean Architecture**: Flag is passed through all layers

## Testing Checklist

- [x] CallKit works when `useCallKit = true`
- [x] CallKit is bypassed when `useCallKit = false`
- [x] Callbacks fire in both modes
- [x] No null pointer errors
- [x] Backward compatibility maintained
- [ ] Integration tests with real ZEGO calls
- [ ] Test on iOS and Android

## Next Steps

1. Test with real calls on iOS/Android
2. Update main README.md with `useCallKit` documentation
3. Add unit tests for flag behavior
4. Consider adding to example app

## Files Modified

1. `lib/src/controllers/rtc_call_controller.dart`
2. `lib/src/api/models/communication_config.dart`
3. `lib/src/api/rtc_communication_service.dart`
4. The [CallKit usage](#callkit-usage) section of this README
5. `CHANGELOG_CALLKIT_FLAG.md` (this file)

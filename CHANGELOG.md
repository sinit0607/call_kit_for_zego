# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- WebRTC support (in addition to ZEGOCLOUD)
- Group calling support
- Screen sharing
- Call recording
- End-to-end encryption
- Call quality metrics

## [1.0.0] - 2026-09-05

First public release, published as `call_kit_for_zego`.

### Added
- Audio and video calling using ZEGOCLOUD
- Native CallKit integration for iOS and Android, including the full-screen
  incoming-call UI on locked screens
- `SocketAdapter` — bring your own WebSocket/Socket.IO implementation
- `SignalingMapper` — map any backend's event format onto the package's
- State machine for call lifecycle, with guarded transitions
- Network reconnection with exponential backoff
- 30-second ringing timeout
- In-session chat, in-call controls (mute, camera, speaker), duration tracking
- `RtcRemoteVideoView` / `RtcLocalVideoView` rendering widgets
- Optional analytics, crash-reporting and call-storage plugin interfaces
- Mic/camera permission failures surface as `CallError.permissionDenied`
  rather than the engine silently publishing an empty stream
- A runnable example app for Android and iOS, plus a demo signaling server
  (`demo_server/`) so a real call can be placed before writing any backend

### Requirements
- `flutter_callkit_incoming` ^3.1.5
- `zego_express_engine` ^3.24.0 — needs a `compileSdk` workaround documented
  in the README; 3.25.0 declares `compileSdkVersion 31` while its own
  dependencies require 33+
- Android `minSdk` 23; the app must request runtime mic/camera permissions and
  must not set `android:taskAffinity=""` on its MainActivity (see README)

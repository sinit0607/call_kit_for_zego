# Demo signaling server

A minimal Socket.IO server that speaks the exact protocol in
[`example/lib/my_signaling_mapper.dart`](../example/lib/my_signaling_mapper.dart),
so you can run the example app on two devices and place a real call.

**This is a test harness, not a backend.** No auth, no persistence, no
horizontal scaling — everything lives in a `Map` and dies with the process.
Read it as executable documentation of the protocol your real server must
implement.

## Run it

```bash
cd demo_server
npm install
npm start
```

Check it is alive, and see who is connected:

```bash
curl localhost:3000/health
```

## Verify the protocol without any devices

Drives two fake clients through call → accept → chat → hang up, plus the
rejection and offline paths, asserting the exact field names the mapper reads:

```bash
npm test
```

## Point the app at it

The example reads the URL from a `--dart-define`:

```bash
flutter run --dart-define=SIGNALING_URL=http://192.168.1.42:3000
```

| Where the app runs | URL to use |
| --- | --- |
| Android emulator | `http://10.0.2.2:3000` (the default) |
| iOS simulator | `http://localhost:3000` |
| Real device | `http://<your-machine-LAN-IP>:3000` |

A real device must be on the same Wi-Fi as your machine. Find your IP with
`ipconfig getifaddr en0` on macOS.

> `10.0.2.2` is an **emulator-only** alias for your machine's localhost. On a
> physical device it resolves to nothing and you get
> `[SocketAdapter] Connection error: timeout` — pass the LAN IP instead.

> **Cleartext HTTP:** the example's debug builds allow it. Release builds do
> not — Android blocks cleartext by default and iOS enforces ATS — so a release
> build needs `https://`.

Launch the app on two devices, pick a different user on each, and call.

### Grant mic and camera, on **both** ends

The example requests them at startup. Accept the prompts — a denied mic does
not fail the call, it publishes an empty stream, so you get a connected call
with silence. You will see this in the log if it happens:

```
[onLocalDeviceExceptionOccurred] exceptionType: PERMISSION_NOT_GRANTED, deviceType: MICROPHONE
E/AudioRecord: AudioFlinger could not create record track, status: -1
```

**On an Android emulator** the permission grant is not enough — the virtual
devices are off by default. In Android Studio, Device Manager → Edit the AVD →
Show Advanced Settings:

- **Microphone:** enable *Virtual microphone uses host audio input*
- **Camera (front/back):** set to `Webcam0`, not `Emulated` (the emulated one
  is a moving-square test pattern, not a real image)

Then cold boot the AVD — these are read at startup.

## The protocol

### App → server

| Event | Meaning | Key fields |
| --- | --- | --- |
| `register` | Bind this socket to a userId | `userId` |
| `chat-request` | Start a call | `userId` (caller), `listenerId` (callee), `requestId`, `type` |
| `accept-request` | Accept | `requestId` |
| `reject-request` | Decline | `requestId`, `rejectedBy` |
| `cancel-request` | Caller hangs up while ringing | `requestId`, `cancelledBy` |
| `session-end` | Hang up an active call | `requestId`, `sessionId`, `sessionEndedBy` |
| `sendMessage` | In-session chat | `messageId`, `sessionId`, `userId`, `message` |
| `typing` | Typing indicator | `sessionId`, `userId`, `isTyping` |

### Server → app

| Event | Meaning | Key fields |
| --- | --- | --- |
| `receiveChatRequest` | Incoming call | `requestId`, `requestBy`, `type`, `roomId`, `userName` |
| `requestAccepted` | Your call was accepted | `requestId`, `roomId`, `sessionId` |
| `sessionStarted` | **Call is live — join the room now** | `sessionId`, `roomID`, `userId`, `listenerId`, `type` |
| `requestRejected` | Declined, or callee offline | `requestId`, `rejectedBy`, `reason` |
| `callCancelled` | Caller gave up | `requestId`, `cancelledBy` |
| `sessionEnded` | Call over | `requestId`, `sessionId`, `sessionEndedBy`, `reason` |
| `callTimeout` | Nobody answered in time | `requestId` |
| `receiveMessage` | Incoming chat | `messageId`, `sessionId`, `senderId`, `message` |
| `messageDelivered` | Delivery ack | `messageId` |

## Three things a real server must get right

These are the parts that are easy to get wrong, and each one fails *silently* —
the call connects and looks fine.

**1. `sessionStarted` must go to _both_ parties, and it is what starts media.**
`RtcCallController` deliberately does not join the ZEGO room on the offer or on
the accept — it waits for the server's authoritative `roomId` in
`sessionStarted`. Send it to only the caller and the callee sits in a connected
call with no audio.

**2. Both parties need the same `roomId`.** Generate it once, when the call is
requested, and echo the identical value in `sessionStarted` to both sides. Two
different room IDs means two people alone in two rooms — the UI shows
"connected" the whole time.

**3. Never infer direction from `userId` / `listenerId`.** The mapper puts
*whoever is emitting* in `userId`, so on `chat-request` the caller is `userId`,
but on `accept-request` the **callee** is. Look the call up by `requestId` and
use the parties you stored — `server.js` does this in `findCall()`.

A fourth, less subtle one: `requestAccepted` must echo the **original**
`requestId`. The controller requires an exact `callId` match for a plain answer
event. `sessionStarted` is the exception — it may carry a server-generated
`sessionId`, and the controller explicitly tolerates that.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `3000` | Listen port |
| `RING_TIMEOUT_MS` | `30000` | Unanswered call gives up after this |

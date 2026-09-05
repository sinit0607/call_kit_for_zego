'use strict';

/**
 * Demo signaling server for call_kit_for_zego.
 *
 * Speaks exactly the protocol in example/lib/my_signaling_mapper.dart, so you
 * can run two devices against it and place a real call. It is deliberately
 * in-memory and unauthenticated — a test harness, not a backend. See README.md.
 */

const http = require('http');
const { Server } = require('socket.io');

const PORT = Number(process.env.PORT) || 3000;
const RING_TIMEOUT_MS = Number(process.env.RING_TIMEOUT_MS) || 30000;

/** userId -> socket. Last connection for a userId wins. */
const users = new Map();
/** requestId -> call record. */
const calls = new Map();

const now = () => new Date().toISOString().slice(11, 23);
const log = (...args) => console.log(`[${now()}]`, ...args);

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      online: [...users.keys()],
      activeCalls: [...calls.values()].map((c) => ({
        requestId: c.requestId,
        from: c.callerId,
        to: c.calleeId,
        type: c.type,
        state: c.state,
      })),
    }, null, 2));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('call_kit_for_zego demo signaling server. Try /health\n');
});

const io = new Server(server, { cors: { origin: '*' } });

// ── helpers ────────────────────────────────────────────────────────────────

/** Emit to a userId if they are online; log the miss otherwise. */
function toUser(userId, event, payload) {
  const socket = users.get(userId);
  if (!socket) {
    log(`  ✗ ${event} -> ${userId} (offline, dropped)`);
    return false;
  }
  socket.emit(event, payload);
  log(`  → ${event} -> ${userId}`);
  return true;
}

/**
 * The mapper swaps userId/listenerId depending on who is emitting (the
 * accepter puts itself in `userId`), so never infer direction from the
 * payload — look the call up by requestId and use the stored parties.
 */
function findCall(data) {
  const requestId = data && (data.requestId || data.sessionId);
  if (!requestId) return null;
  return calls.get(requestId) || null;
}

function clearRingTimer(call) {
  if (call.ringTimer) {
    clearTimeout(call.ringTimer);
    call.ringTimer = null;
  }
}

function endCall(call, reason) {
  clearRingTimer(call);
  calls.delete(call.requestId);
  log(`  ⏹ call ${call.requestId} ended (${reason})`);
}

// ── connection ─────────────────────────────────────────────────────────────

io.on('connection', (socket) => {
  // Identity comes from the handshake when available; the client may also
  // (re)bind later with `register`, which is what the example app does after
  // the user picks who they are.
  const handshake = socket.handshake.auth || {};
  let userId = handshake.userId || handshake.token || socket.handshake.query.userId;

  const bind = (id) => {
    if (!id) return;
    userId = String(id);
    users.set(userId, socket);
    socket.data.userId = userId;
    log(`✅ ${userId} online  (${users.size} connected: ${[...users.keys()].join(', ')})`);
  };

  if (userId) bind(userId);
  else log(`… socket ${socket.id} connected without an identity, awaiting "register"`);

  socket.on('register', (data) => {
    const id = typeof data === 'string' ? data : data && (data.userId || data.id);
    if (!id) return log(`  ✗ register with no userId from ${socket.id}`);
    bind(id);
    socket.emit('registered', { userId });
  });

  // ── call: offer ─────────────────────────────────────────────────────────
  // The caller is `userId`, the callee `listenerId` (mapOutgoingEvent with no
  // userRole puts the sender first).
  socket.on('chat-request', (data) => {
    const callerId = data.userId;
    const calleeId = data.listenerId;
    const requestId = data.requestId;
    log(`📞 chat-request  ${callerId} -> ${calleeId}  (${data.type}, ${requestId})`);

    if (!callerId || !calleeId || !requestId) {
      return log('  ✗ missing userId/listenerId/requestId, ignoring');
    }

    // roomId must be stable for the whole call and is parsed as
    // `caller-callee-timestamp` by the mapper when the server omits the ids.
    const call = {
      requestId,
      callerId,
      calleeId,
      type: data.type || 'call',
      roomId: `${callerId}-${calleeId}-${Date.now()}`,
      sessionId: null,
      state: 'ringing',
      callerName: data.requestByUserName || callerId,
      callerImage: data.requestByImage || null,
      ringTimer: null,
    };
    calls.set(requestId, call);

    const delivered = toUser(calleeId, 'receiveChatRequest', {
      requestId,
      userId: callerId,
      listenerId: calleeId,
      requestBy: callerId,
      type: call.type,
      roomId: call.roomId,
      userName: call.callerName,
      requestByUserName: call.callerName,
      userImage: call.callerImage,
      requestByImage: call.callerImage,
    });

    if (!delivered) {
      toUser(callerId, 'requestRejected', {
        requestId,
        rejectedBy: calleeId,
        userId: callerId,
        listenerId: calleeId,
        reason: 'callee_offline',
      });
      return endCall(call, 'callee offline');
    }

    call.ringTimer = setTimeout(() => {
      log(`⏰ timeout ${requestId} after ${RING_TIMEOUT_MS}ms`);
      const payload = { requestId, userId: callerId, listenerId: calleeId };
      toUser(callerId, 'callTimeout', payload);
      toUser(calleeId, 'callTimeout', payload);
      endCall(call, 'ring timeout');
    }, RING_TIMEOUT_MS);
  });

  // ── call: accept ────────────────────────────────────────────────────────
  socket.on('accept-request', (data) => {
    const call = findCall(data);
    log(`✅ accept-request ${data && data.requestId}`);
    if (!call) return log('  ✗ unknown requestId, ignoring');

    clearRingTimer(call);
    call.state = 'active';
    call.sessionId = `sess_${call.requestId}_${Date.now()}`;

    // 1. Tell the caller their request was accepted. This must carry the
    //    original requestId — the controller requires an exact callId match
    //    for a plain answer event.
    toUser(call.callerId, 'requestAccepted', {
      requestId: call.requestId,
      userId: call.callerId,
      listenerId: call.calleeId,
      roomId: call.roomId,
      sessionId: call.sessionId,
    });

    // 2. Then confirm the session to BOTH parties. This is the event that
    //    actually starts media: the controller deliberately does not join the
    //    ZEGO room on offer or accept, it waits for the server's authoritative
    //    roomId here. Skip this and the call rings, connects, and stays silent.
    const sessionStarted = {
      sessionId: call.sessionId,
      roomID: call.roomId,
      roomId: call.roomId,
      userId: call.callerId,
      listenerId: call.calleeId,
      type: call.type,
      userName: call.callerName,
      userImage: call.callerImage,
      display_name: call.calleeId,
      display_image: null,
    };
    toUser(call.callerId, 'sessionStarted', sessionStarted);
    toUser(call.calleeId, 'sessionStarted', sessionStarted);
  });

  // ── call: reject / cancel / end / timeout ───────────────────────────────
  socket.on('reject-request', (data) => {
    const call = findCall(data);
    log(`🚫 reject-request ${data && data.requestId}`);
    if (!call) return log('  ✗ unknown requestId, ignoring');

    toUser(call.callerId, 'requestRejected', {
      requestId: call.requestId,
      rejectedBy: (data && data.rejectedBy) || call.calleeId,
      userId: call.callerId,
      listenerId: call.calleeId,
    });
    endCall(call, 'rejected');
  });

  socket.on('cancel-request', (data) => {
    const call = findCall(data);
    log(`🚫 cancel-request ${data && data.requestId}`);
    if (!call) return log('  ✗ unknown requestId, ignoring');

    toUser(call.calleeId, 'callCancelled', {
      requestId: call.requestId,
      cancelledBy: (data && data.cancelledBy) || call.callerId,
      userId: call.callerId,
      listenerId: call.calleeId,
    });
    endCall(call, 'cancelled');
  });

  socket.on('session-end', (data) => {
    const call = findCall(data);
    log(`📴 session-end ${data && (data.requestId || data.sessionId)}`);
    if (!call) return log('  ✗ unknown requestId/sessionId, ignoring');

    const payload = {
      requestId: call.requestId,
      sessionId: call.sessionId,
      sessionEndedBy: (data && data.sessionEndedBy) || socket.data.userId,
      reason: 'ended',
    };
    // Both sides, so whoever did not hang up also tears down.
    toUser(call.callerId, 'sessionEnded', payload);
    toUser(call.calleeId, 'sessionEnded', payload);
    endCall(call, 'hung up');
  });

  socket.on('call-timeout', (data) => {
    const call = findCall(data);
    if (!call) return;
    const payload = {
      requestId: call.requestId,
      userId: call.callerId,
      listenerId: call.calleeId,
    };
    toUser(call.callerId, 'callTimeout', payload);
    toUser(call.calleeId, 'callTimeout', payload);
    endCall(call, 'client timeout');
  });

  // ── in-session chat ─────────────────────────────────────────────────────
  socket.on('sendMessage', (data) => {
    log(`💬 sendMessage in ${data && data.sessionId} from ${data && data.userId}`);
    const call = [...calls.values()].find((c) => c.sessionId === (data && data.sessionId));
    const recipientId = (data && data.recipientId)
      || (call && (data.userId === call.callerId ? call.calleeId : call.callerId));

    if (!recipientId) return log('  ✗ no recipient (unknown sessionId and no recipientId)');

    toUser(recipientId, 'receiveMessage', { ...data, senderId: data.userId });
    // Ack the sender so the message flips from "sending" to "delivered".
    toUser(data.userId, 'messageDelivered', {
      messageId: data.messageId,
      sessionId: data.sessionId,
    });
  });

  socket.on('typing', (data) => {
    const call = [...calls.values()].find((c) => c.sessionId === (data && data.sessionId));
    if (!call) return;
    const recipientId = data.userId === call.callerId ? call.calleeId : call.callerId;
    toUser(recipientId, 'typing', data);
  });

  // ── teardown ────────────────────────────────────────────────────────────
  socket.on('disconnect', (reason) => {
    if (!userId) return;
    // Only drop the mapping if this socket is still the live one for the user;
    // a reconnect may already have replaced it.
    if (users.get(userId) === socket) users.delete(userId);
    log(`❌ ${userId} offline (${reason})`);

    for (const call of [...calls.values()]) {
      if (call.callerId !== userId && call.calleeId !== userId) continue;
      const other = call.callerId === userId ? call.calleeId : call.callerId;
      toUser(other, 'sessionEnded', {
        requestId: call.requestId,
        sessionId: call.sessionId,
        sessionEndedBy: userId,
        reason: 'peer_disconnected',
      });
      endCall(call, 'peer disconnected');
    }
  });
});

server.listen(PORT, () => {
  log(`call_kit_for_zego demo signaling server listening on :${PORT}`);
  log(`ring timeout ${RING_TIMEOUT_MS}ms · status at http://localhost:${PORT}/health`);
});

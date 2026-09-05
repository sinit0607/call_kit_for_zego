'use strict';

/**
 * Drives two fake clients through a full call against a running server.
 * Verifies the exact event names and payload fields that
 * example/lib/my_signaling_mapper.dart reads, so a protocol drift fails here
 * rather than as a silent no-audio call on a real device.
 *
 *   node server.js          # in one terminal
 *   node test_flow.js       # in another
 */

const assert = require('assert');
const { io } = require('socket.io-client');

const URL = process.env.URL || 'http://localhost:3000';
const REQUEST_ID = `req_test_${Date.now()}`;

const connect = (userId) =>
  new Promise((resolve, reject) => {
    const socket = io(URL, { transports: ['websocket'], auth: { userId } });
    socket.once('connect', () => resolve(socket));
    socket.once('connect_error', reject);
  });

/** Resolve with the next payload for `event`, or reject after `ms`. */
const next = (socket, event, ms = 4000) =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`timed out waiting for "${event}"`)),
      ms,
    );
    socket.once(event, (data) => {
      clearTimeout(timer);
      resolve(data);
    });
  });

async function main() {
  const alice = await connect('alice'); // caller
  const bob = await connect('bob'); //   callee
  let passed = 0;
  const ok = (msg) => {
    console.log(`  ✓ ${msg}`);
    passed++;
  };

  try {
    console.log('\n0. identity survives a reconnect');
    // The app registers whenever the socket connects, not once at startup: the
    // user is usually chosen before the socket is up, and a reconnect gets a
    // fresh socket the server cannot associate with anyone.
    const late = io(URL, { transports: ['websocket'] }); // no handshake auth
    await new Promise((r) => late.once('connect', r));
    late.emit('register', { userId: 'zoe' });
    assert.strictEqual((await next(late, 'registered')).userId, 'zoe');
    ok('a socket that connects anonymously can register afterwards');

    late.io.engine.close();
    await new Promise((r) => late.once('connect', r));
    late.emit('register', { userId: 'zoe' });
    assert.strictEqual((await next(late, 'registered')).userId, 'zoe');
    const health = await fetch(`${URL}/health`).then((r) => r.json());
    assert.ok(health.online.includes('zoe'), 'still routable after reconnect');
    ok('re-registering after a reconnect keeps the user routable');
    late.close();

    console.log('\n1. alice calls bob');
    const ringing = next(bob, 'receiveChatRequest');
    alice.emit('chat-request', {
      userId: 'alice',
      listenerId: 'bob',
      requestId: REQUEST_ID,
      type: 'video',
      requestByUserName: 'Alice',
    });
    const offer = await ringing;

    assert.strictEqual(offer.requestId, REQUEST_ID, 'requestId echoed');
    assert.strictEqual(offer.requestBy, 'alice', 'requestBy identifies caller');
    assert.strictEqual(offer.type, 'video');
    assert.ok(offer.roomId, 'server assigns a roomId up front');
    assert.strictEqual(offer.userName, 'Alice', 'caller name forwarded');
    ok('bob receives receiveChatRequest with caller, type and roomId');

    console.log('\n2. bob accepts');
    // The mapper puts the accepter in `userId` — inverted from chat-request.
    // The server must route by requestId, not by field position.
    const accepted = next(alice, 'requestAccepted');
    const aliceSession = next(alice, 'sessionStarted');
    const bobSession = next(bob, 'sessionStarted');
    bob.emit('accept-request', {
      userId: 'bob',
      listenerId: 'alice',
      requestId: REQUEST_ID,
      type: 'video',
    });

    const ack = await accepted;
    assert.strictEqual(ack.requestId, REQUEST_ID,
      'requestAccepted must echo the original requestId — the controller ' +
      'requires an exact callId match for a plain answer');
    ok('alice receives requestAccepted with the original requestId');

    const [aSess, bSess] = await Promise.all([aliceSession, bobSession]);
    ok('BOTH parties receive sessionStarted (this is what starts media)');

    assert.strictEqual(aSess.roomID, bSess.roomID, 'same roomID on both sides');
    assert.strictEqual(aSess.roomID, offer.roomId, 'roomId stable since the offer');
    assert.strictEqual(aSess.sessionId, bSess.sessionId, 'same sessionId');
    assert.notStrictEqual(aSess.sessionId, REQUEST_ID,
      'server issues its own sessionId, distinct from the requestId');
    assert.strictEqual(aSess.userId, 'alice');
    assert.strictEqual(aSess.listenerId, 'bob');
    ok('sessionStarted agrees on roomID/sessionId and names both parties');

    const sessionId = aSess.sessionId;

    console.log('\n3. chat inside the session');
    const received = next(bob, 'receiveMessage');
    const delivered = next(alice, 'messageDelivered');
    alice.emit('sendMessage', {
      messageId: 'msg_1',
      sessionId,
      userId: 'alice',
      senderName: 'Alice',
      message: 'hello bob',
      timestamp: new Date().toISOString(),
    });
    const msg = await received;
    assert.strictEqual(msg.message, 'hello bob');
    assert.strictEqual(msg.senderId, 'alice', 'senderId set for the mapper');
    ok('bob receives the message with senderId populated');

    const ackMsg = await delivered;
    assert.strictEqual(ackMsg.messageId, 'msg_1');
    ok('alice gets messageDelivered');

    console.log('\n4. alice hangs up');
    const aliceEnd = next(alice, 'sessionEnded');
    const bobEnd = next(bob, 'sessionEnded');
    alice.emit('session-end', {
      requestId: REQUEST_ID,
      sessionId,
      sessionEndedBy: 'alice',
    });
    const [aEnd, bEnd] = await Promise.all([aliceEnd, bobEnd]);
    assert.strictEqual(aEnd.sessionEndedBy, 'alice');
    assert.strictEqual(bEnd.sessionId, sessionId);
    ok('both sides receive sessionEnded');

    console.log('\n5. rejection path');
    const rejectId = `req_reject_${Date.now()}`;
    const ringing2 = next(bob, 'receiveChatRequest');
    alice.emit('chat-request', {
      userId: 'alice',
      listenerId: 'bob',
      requestId: rejectId,
      type: 'call',
    });
    await ringing2;
    const rejected = next(alice, 'requestRejected');
    bob.emit('reject-request', {
      userId: 'bob',
      listenerId: 'alice',
      requestId: rejectId,
      rejectedBy: 'bob',
    });
    const rej = await rejected;
    assert.strictEqual(rej.requestId, rejectId);
    assert.strictEqual(rej.rejectedBy, 'bob');
    ok('alice receives requestRejected');

    console.log('\n6. calling someone who is offline');
    const offlineId = `req_offline_${Date.now()}`;
    const autoReject = next(alice, 'requestRejected');
    alice.emit('chat-request', {
      userId: 'alice',
      listenerId: 'nobody',
      requestId: offlineId,
      type: 'call',
    });
    const off = await autoReject;
    assert.strictEqual(off.reason, 'callee_offline');
    ok('caller is told immediately instead of ringing into the void');

    console.log(`\n✅ ${passed} checks passed — protocol matches MySignalingMapper\n`);
  } finally {
    alice.close();
    bob.close();
  }
}

main().catch((err) => {
  console.error(`\n❌ ${err.message}\n`);
  process.exit(1);
});

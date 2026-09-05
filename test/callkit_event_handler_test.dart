import 'dart:async';

import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:call_kit_for_zego/src/native_callkit/callkit_event_handler.dart';

CallKitParams _params({String id = 'uuid-1', String? originalCallId}) =>
    CallKitParams(
      id: id,
      extra: originalCallId == null
          ? null
          : <String, dynamic>{'originalCallId': originalCallId},
    );

void main() {
  late StreamController<CallEvent?> events;
  late CallKitEventHandler handler;
  late List<String> accepted;
  late List<String> declined;
  late List<String> timedOut;

  setUp(() {
    events = StreamController<CallEvent?>();
    handler = CallKitEventHandler();
    accepted = [];
    declined = [];
    timedOut = [];
    handler.onAcceptCall = accepted.add;
    handler.onDeclineCall = declined.add;
    handler.onTimeout = timedOut.add;
    handler.startListening(events.stream);
  });

  tearDown(() {
    handler.dispose();
    events.close();
  });

  Future<void> emit(CallEvent? e) async {
    events.add(e);
    await Future<void>.delayed(Duration.zero);
  }

  test('prefers our own callId from extra over the CallKit UUID', () async {
    await emit(CallEventActionCallAccept(
        _params(id: 'uuid-1', originalCallId: 'call-42')));
    expect(accepted, ['call-42']);
  });

  test('falls back to the CallKit UUID when extra is absent', () async {
    await emit(CallEventActionCallDecline(_params(id: 'uuid-2')));
    expect(declined, ['uuid-2']);
  });

  test('routes events with only an id', () async {
    await emit(const CallEventActionCallTimeout('uuid-3'));
    expect(timedOut, ['uuid-3']);
  });

  test('ignores events with no mapped action, and nulls', () async {
    await emit(const CallEventActionCallToggleMute('uuid-4', true));
    await emit(const CallEventActionCallToggleAudioSession(true));
    await emit(null);
    expect([...accepted, ...declined, ...timedOut], isEmpty);
  });

  test('drops duplicates inside the same one-second bucket', () async {
    final p = _params(id: 'uuid-5', originalCallId: 'call-9');
    await emit(CallEventActionCallAccept(p));
    await emit(CallEventActionCallAccept(p));
    expect(accepted, ['call-9']);
  });
}

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

void main() {
  // Vectors produced with the Python engine's identity module (seed = 0..31
  // and 32..63), so Dart and engine agree byte for byte.
  test('identity matches engine vectors', () async {
    final NodeIdentity a = await NodeIdentity.fromSeed(
      List<int>.generate(32, (int i) => i),
    );
    final NodeIdentity b = await NodeIdentity.fromSeed(
      List<int>.generate(32, (int i) => 32 + i),
    );
    expect(a.publicKeyB64u, 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg');
    expect(a.nodeId, 'n_kzdvvj2umnduyauf35o36k6kw4');
    expect(b.publicKeyB64u, 'Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc');
    expect(b.nodeId, 'n_et3o22wl7yiatqbq27ffm7btzi');
    final String message = await sdpMessage('sid', 'from', 'to', 'v=0');
    expect(
      await a.sign(message),
      '6mL3EoD1EfVa6bAljWWOAM7f_PKJ8pxr_-T_sq-HFX4gyYhkZo4K9WWbY3fGKvVjsNND0EBXyvwiOvQSfHypDw',
    );
    expect(await shortAuthenticationString(a.publicKey, b.publicKey), '418680');
    expect(await shortAuthenticationString(b.publicKey, a.publicKey), '418680');
  });

  test('sign and verify, and tampering fails', () async {
    final NodeIdentity id = await NodeIdentity.generate();
    final String sig = await id.sign('hello');
    expect(
      await verifySignature(publicKey: id.publicKey, signature: sig, message: 'hello'),
      isTrue,
    );
    expect(
      await verifySignature(publicKey: id.publicKey, signature: sig, message: 'hellO'),
      isFalse,
    );
    expect(
      await verifySignature(publicKey: id.publicKey, signature: 'bad!', message: 'hello'),
      isFalse,
    );
    final NodeIdentity other = await NodeIdentity.generate();
    expect(
      await verifySignature(publicKey: other.publicKey, signature: sig, message: 'hello'),
      isFalse,
    );
  });

  test('seed round trip and validation', () async {
    final NodeIdentity id = await NodeIdentity.generate();
    final NodeIdentity again = await NodeIdentity.fromSeed(await id.seed());
    expect(again.nodeId, id.nodeId);
    expect(() => NodeIdentity.fromSeed(<int>[1, 2, 3]), throwsFormatException);
    expect(id.toString(), isNot(contains(b64uEncode(await id.seed()))));
  });

  test('signing contexts have the exact Appendix A shape', () async {
    expect(registerMessage('u1', 'KEY'), 'sc-register-v1\nu1\nKEY');
    expect(approvalMessage('u1', 'KEY'), 'sc-approve-v1\nu1\nKEY');
    expect(
      helloMessage('fa', 'fb', 'na', 'nb'),
      'sc-hello-v1\nfa\nfb\nna\nnb',
    );
    expect(
      await signalAuthMessage('chal', 'ticket', 'n_x'),
      'sc-signal-v1\nchal\n${await sha256Hex('ticket')}\nn_x',
    );
    expect(
      await sdpMessage('s', 'f', 't', 'sdp'),
      'sc-sdp-v1\ns\nf\nt\n${await sha256Hex('sdp')}',
    );
    expect(
      await sha256Hex('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('base64url helpers', () {
    expect(b64uEncode(<int>[251, 255, 254]), '-__-');
    expect(b64uDecode('-__-'), <int>[251, 255, 254]);
    expect(b64uDecode('QQ'), <int>[65]);
    expect(() => b64uDecode(''), throwsFormatException);
    expect(() => b64uDecode('é'), throwsFormatException);
  });
}

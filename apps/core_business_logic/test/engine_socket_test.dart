import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

void main() {
  test('WebSocketEngineClient is an EngineSocket usable by EngineRepository', () async {
    final EngineSocket socket = WebSocketEngineClient(
      endpoint: Uri.parse('ws://127.0.0.1:1/api/v1/events'),
    );
    final EngineRepository repository = EngineRepository(
      rest: RestEngineClient(baseUri: Uri.parse('http://127.0.0.1:1/api/v1/'), token: 't'),
      socket: socket,
    );
    expect(repository.socket.isConnected, isFalse);
    expect(() => socket.send(type: 'ping'), throwsStateError);
    expect(() => socket.sendChat(content: 'x'), throwsArgumentError);
    await socket.dispose();
    await repository.rest.close();
  });
}

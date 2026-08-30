import '../models/engine_models.dart';
import 'genkit_model_provider.dart';

final class EchoModelProvider implements EngineModelProvider {
  const EchoModelProvider();

  @override
  Stream<String> generate({required Iterable<ChatMessage> history, required String prompt}) async* {
    yield 'Echo: $prompt';
  }
}

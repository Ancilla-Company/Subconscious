import 'package:genkit/genkit.dart';

import '../models/engine_models.dart';

abstract interface class EngineModelProvider {
  Stream<String> generate({required Iterable<ChatMessage> history, required String prompt});
}

/// Genkit-backed model execution for the Dart engine.
///
/// The model endpoint may be a Genkit plugin-backed model or a remote Genkit
/// model served by another process. Secrets stay outside this class.
final class GenkitModelProvider implements EngineModelProvider {
  GenkitModelProvider._(this._ai, this._model);

  factory GenkitModelProvider.remote({required Uri endpoint, required String modelName}) {
    final Genkit ai = Genkit(promptDir: null);
    final Model<dynamic> model = ai.defineRemoteModel(name: modelName, url: endpoint.toString());
    return GenkitModelProvider._(ai, model);
  }

  final Genkit _ai;
  final Model<dynamic> _model;

  @override
  Stream<String> generate({required Iterable<ChatMessage> history, required String prompt}) async* {
    final List<Message> messages = <Message>[
      for (final ChatMessage message in history)
        Message(role: _roleFor(message.role), content: <Part>[TextPart(text: message.content)]),
      Message(role: Role.user, content: <Part>[TextPart(text: prompt)]),
    ];
    final response = _ai.generateStream<dynamic, dynamic>(model: _model, messages: messages);
    await for (final GenerateResponseChunk<dynamic> chunk in response) {
      if (chunk.text.isNotEmpty) yield chunk.text;
    }
  }

  Role _roleFor(String role) => switch (role) {
    'system' => Role.system,
    'assistant' => Role.model,
    'tool' => Role.tool,
    _ => Role.user,
  };

  Future<void> shutdown() => _ai.shutdown();
}

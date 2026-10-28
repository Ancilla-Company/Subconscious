/// The browser and extension have their own console; nothing is written.
Future<void> initGuiLog() async {}

void guiLog(String message, {String level = 'INFO'}) {}

void guiLogError(String where, Object error, StackTrace? stack) {}

String? get guiLogPath => null;

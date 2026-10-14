import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

import 'hive_runtime.dart';

/// Connection resolver branch for "no local engine reachable but signed in to
/// the Subconscious server": picks a home engine from the node list and talks
/// to it over WebRTC. Returns null (never throws) so the caller can fall back
/// to its existing error handling.
Future<EngineRepository?> resolveHiveRepository() async {
  try {
    return await HiveRuntime.shared.resolveRepository();
  } on Object catch (error) {
    debugPrint('Hive connection unavailable: $error');
    return null;
  }
}

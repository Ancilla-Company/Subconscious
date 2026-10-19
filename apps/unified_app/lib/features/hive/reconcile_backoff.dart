/// Delay between safety refreshes while the push channel is not healthy:
/// 5 s doubling to 120 s. Reset on the first success or reconnect.
final class ReconcileBackoff {
  ReconcileBackoff({
    this.initial = const Duration(seconds: 5),
    this.cap = const Duration(seconds: 120),
  }) : _next = initial;

  final Duration initial;
  final Duration cap;
  Duration _next;

  /// The delay to wait now; the following call returns twice as long (capped).
  Duration next() {
    final Duration current = _next;
    final Duration doubled = _next * 2;
    _next = doubled > cap ? cap : doubled;
    return current;
  }

  void reset() => _next = initial;
}

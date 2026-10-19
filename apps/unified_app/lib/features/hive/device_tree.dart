import 'package:core_business_logic/core_business_logic.dart';

/// One top-level device and the clients folded under it.
final class DeviceGroup {
  const DeviceGroup(this.root, this.children);
  final NodeView root;
  final List<NodeView> children;
}

/// Folds clients under the engine they connect through.
///
/// A node whose `parentId` names an engine that is present becomes that
/// engine's child (sorted by name). A node whose parent is not in the list
/// stays top level. Engines never nest and children are never top level.
List<DeviceGroup> buildDeviceTree(List<NodeView> nodes) {
  final Map<String, NodeView> engines = <String, NodeView>{
    for (final NodeView v in nodes)
      if (v.node.isEngine) _key(v.node.id): v,
  };
  final Map<String, List<NodeView>> children = <String, List<NodeView>>{};
  final List<NodeView> roots = <NodeView>[];
  for (final NodeView view in nodes) {
    final String? parent = view.parentId;
    final bool folds =
        !view.node.isEngine &&
        parent != null &&
        engines.containsKey(_key(parent)) &&
        _key(parent) != _key(view.node.id);
    if (folds) {
      children.putIfAbsent(_key(parent), () => <NodeView>[]).add(view);
    } else {
      roots.add(view);
    }
  }
  return <DeviceGroup>[
    for (final NodeView root in roots)
      DeviceGroup(
        root,
        (children[_key(root.node.id)] ?? const <NodeView>[]).toList()
          ..sort(
            (NodeView a, NodeView b) =>
                a.node.name.toLowerCase().compareTo(b.node.name.toLowerCase()),
          ),
      ),
  ];
}

String _key(String id) => id.toLowerCase();

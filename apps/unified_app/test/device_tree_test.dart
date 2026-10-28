import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/hive/device_tree.dart';

NodeView _node(
  String id, {
  String kind = 'thin',
  String? parent,
  List<String> clients = const <String>[],
  String? name,
}) => NodeView(
  node: DirectoryNode(
    id: id,
    kind: kind,
    name: name ?? id,
    platform: 'windows',
    appVersion: '',
    publicKey: Uint8List(32),
    status: 'active',
  ),
  trusted: true,
  online: true,
  isLocal: false,
  parentId: parent,
  clients: clients,
);

void main() {
  test('a client folds under its engine and is never top level', () {
    final List<DeviceGroup> groups = buildDeviceTree(<NodeView>[
      _node('n_pc', kind: 'engine'),
      _node('n_gui', parent: 'n_pc'),
      _node('n_phone'),
    ]);
    expect(
      <String>[for (final DeviceGroup g in groups) g.root.node.id],
      <String>['n_pc', 'n_phone'],
    );
    expect(
      <String>[for (final NodeView c in groups.first.children) c.node.id],
      <String>['n_gui'],
    );
    expect(groups.last.children, isEmpty);
  });

  test('a parent that is not present leaves the node top level', () {
    final List<DeviceGroup> groups = buildDeviceTree(<NodeView>[
      _node('n_gui', parent: 'n_gone'),
    ]);
    expect(groups, hasLength(1));
    expect(groups.single.root.node.id, 'n_gui');
  });

  test('engines never nest, even with a parent id', () {
    final List<DeviceGroup> groups = buildDeviceTree(<NodeView>[
      _node('n_a', kind: 'engine'),
      _node('n_b', kind: 'engine', parent: 'n_a'),
    ]);
    expect(groups, hasLength(2));
    expect(groups.every((DeviceGroup g) => g.children.isEmpty), isTrue);
  });

  test('a node cannot be its own parent', () {
    final List<DeviceGroup> groups = buildDeviceTree(<NodeView>[
      _node('n_a', kind: 'engine'),
      _node('n_x', parent: 'n_x'),
    ]);
    expect(groups.map((DeviceGroup g) => g.root.node.id), contains('n_x'));
  });

  test('children are sorted by name', () {
    final List<DeviceGroup> groups = buildDeviceTree(<NodeView>[
      _node('n_pc', kind: 'engine'),
      _node('n_2', parent: 'n_pc', name: 'Zed'),
      _node('n_1', parent: 'n_pc', name: 'alpha'),
    ]);
    expect(
      <String>[for (final NodeView c in groups.single.children) c.node.name],
      <String>['alpha', 'Zed'],
    );
  });

  test('parent ids match case-insensitively', () {
    final List<DeviceGroup> groups = buildDeviceTree(<NodeView>[
      _node('n_PC', kind: 'engine'),
      _node('n_gui', parent: 'n_pc'),
    ]);
    expect(groups, hasLength(1));
    expect(groups.single.children, hasLength(1));
  });
}

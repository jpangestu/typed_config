import 'package:collection/collection.dart';
import 'package:typed_config/src/config_engine.dart';

/// Function signature for schema migration handlers.
typedef MigrationHandler = void Function(ConfigMigrator migrator);

/// Context passed to migration functions to inspect and restructure stored configuration data.
///
/// Provides helper methods to safely traverse, read, write, rename, and transform
/// values across hierarchical key paths without manual null-checking.
final class ConfigMigrator {
  final ConfigEngine _configEngine;

  /// The original schema version the configuration file was loaded with, or `null` if unversioned.
  final int? fromVersion;

  /// The target schema version being migrated to.
  final int? toVersion;

  /// Creates a [ConfigMigrator] backed by [configEngine].
  ConfigMigrator({
    required ConfigEngine configEngine,
    this.fromVersion,
    this.toVersion,
  }) : _configEngine = configEngine;

  /// The underlying raw in-memory JSON configuration map.
  ///
  /// Can be used directly for arbitrary map transformations not covered by helper methods.
  Map<String, dynamic> get raw => _configEngine.raw;

  /// Reads the value at [keyPath], or returns `null` if absent.
  dynamic read(List<String> keyPath) => _configEngine.read(keyPath);

  /// Writes [value] at [keyPath], automatically creating intermediate maps as needed.
  void write(List<String> keyPath, dynamic value) => _configEngine.write(keyPath, value);

  /// Removes the setting at [keyPath] if it exists.
  void remove(List<String> keyPath) => _configEngine.remove(keyPath);

  /// Whether an entry exists at [keyPath].
  bool containsKey(List<String> keyPath) => _configEngine.containsKey(keyPath);

  /// Moves the value at [oldKeyPath] to [newKeyPath] and removes the old key.
  ///
  /// Does nothing if [oldKeyPath] is missing or identical to [newKeyPath].
  void rename(List<String> oldKeyPath, List<String> newKeyPath) {
    if (oldKeyPath.isEmpty || newKeyPath.isEmpty) return;
    if (const ListEquality().equals(oldKeyPath, newKeyPath)) return;
    if (!containsKey(oldKeyPath)) return;

    final value = read(oldKeyPath);
    remove(oldKeyPath);
    write(newKeyPath, value);
  }

  /// Transforms the value at [keyPath] using [transformer].
  ///
  /// Does nothing if [keyPath] does not exist.
  void transform(List<String> keyPath, dynamic Function(dynamic oldValue) transformer) {
    if (keyPath.isEmpty || !containsKey(keyPath)) return;

    final oldValue = read(keyPath);
    final newValue = transformer(oldValue);
    write(keyPath, newValue);
  }
}

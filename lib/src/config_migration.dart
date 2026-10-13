import 'package:meta/meta.dart';

/// Key used in JSON storage to track the current configuration schema version.
const String schemaVersionKey = 'schemaVersion';

/// Context passed to [ConfigMigrator] callbacks containing the current configuration
/// state and migration utilities.
///
/// Encapsulates common transformation helpers (`rename`, `removePrefix`, `transform`)
/// while preserving direct map access via index operators (`m['key']`, `m['key'] = ...`).
final class ConfigMigrationContext {
  /// The underlying flattened configuration data map.
  final Map<String, dynamic> data;

  ConfigMigrationContext(this.data);

  /// Renames [oldKey] to [newKey], preserving its value.
  ///
  /// If [oldKey] exists, its value is moved to [newKey] and [oldKey] is removed.
  /// If [oldKey] does not exist, this does nothing.
  ///
  /// ```dart
  /// // Move key to a new namespace:
  /// m.rename('theme', 'ui.themeMode');
  /// ```
  void rename(String oldKey, String newKey) {
    if (data.containsKey(oldKey)) {
      data[newKey] = data.remove(oldKey);
    }
  }

  /// Transforms the value of [key] by passing its current value to the [updater] callback.
  ///
  /// If [key] exists and its stored value is of type [T], the value is replaced with
  /// whatever [updater] returns. If [key] is missing or not of type [T], this does nothing.
  ///
  /// The callback can return a different type, allowing in-flight type conversions:
  /// ```dart
  /// // Scale volume from 0..100 to 0.0..1.0:
  /// m.transform<num>('volume', (current) => current / 100.0);
  ///
  /// // Convert String "enabled" to bool:
  /// m.transform<String>('autoUpdate', (current) => current == 'enabled');
  /// ```
  void transform<T>(String key, dynamic Function(T current) updater) {
    if (data.containsKey(key)) {
      final current = data[key];
      if (current is T) {
        data[key] = updater(current);
      }
    }
  }

  /// Removes all configuration entries whose keys start with [prefix].
  ///
  /// Useful for dropping entire deprecated sections or nested groups:
  /// ```dart
  /// // Drops all keys starting with 'analytics.' (e.g. 'analytics.id', 'analytics.enabled'):
  /// m.removePrefix('analytics.');
  /// ```
  void removePrefix(String prefix) {
    data.removeWhere((key, _) => key.startsWith(prefix));
  }

  /// Returns the value associated with [key], or `null` if [key] is not present.
  dynamic operator [](String key) => data[key];

  /// Whether the configuration data contains [key].
  bool containsKey(String key) => data.containsKey(key);

  /// An iterable of all configuration keys currently present.
  Iterable<String> get keys => data.keys;

  /// Associates [key] with the given [value].
  ///
  /// If [value] is a nested [Map], it is automatically flattened into dot-separated keys.
  /// If [key] was already present, its previous value is replaced.
  void operator []=(String key, dynamic value) {
    if (value is Map) {
      data.addAll(flattenConfigMap(value, key));
    } else {
      data[key] = value;
    }
  }

  /// Removes [key] and its associated value, if present, from the configuration data.
  ///
  /// Returns the value associated with [key] before it was removed, or
  /// `null` if [key] was not present.
  dynamic remove(String key) => data.remove(key);
}

/// Function signature for migrating configuration data between schema versions.
///
/// The provided [m] context contains the flattened configuration state and
/// helper methods to rename keys, transform types, or remove deprecated groups.
typedef ConfigMigrator = void Function(ConfigMigrationContext m);

/// Sequentially executes registered [migrations] to upgrade [data] from its
/// detected file version up to [targetVersion].
///
/// Throws [ArgumentError] if [targetVersion] is less than 1.
/// Throws [ConfigMigrationException] if any migration step throws an error.
ConfigMigrationResult migrateConfigData({
  required Map<String, dynamic> data,
  required int targetVersion,
  Map<int, ConfigMigrator>? migrations,
  void Function(String message)? onLog,
  void Function(Object error, StackTrace stackTrace)? onError,
}) {
  if (targetVersion < 1) {
    throw ArgumentError.value(
      targetVersion,
      'targetVersion',
      'Target schema version must be at least 1.',
    );
  }

  if (migrations != null) {
    for (final v in migrations.keys) {
      if (v <= 1) {
        throw ArgumentError.value(
          v,
          'migrations',
          'Migration registered for schema version v$v, but migrations start at v2.',
        );
      }
    }
  }

  final fromVersion = parseSchemaVersion(data[schemaVersionKey]);

  // Case 1: Newer version on disk
  if (fromVersion > targetVersion) {
    onLog?.call(
      'Config schema version ($fromVersion) is newer than current version ($targetVersion).',
    );
    return ConfigMigrationResult(
      data: data,
      fromVersion: fromVersion,
      toVersion: fromVersion,
      didMigrate: false,
    );
  }

  // Case 2: Hot path: already up-to-date with schemaVersion pinned
  if (fromVersion == targetVersion && data.containsKey(schemaVersionKey)) {
    return ConfigMigrationResult(
      data: data,
      fromVersion: fromVersion,
      toVersion: targetVersion,
      didMigrate: false,
    );
  }

  // Case 3: Migration sequence required: work on a defensive mutable copy
  final workingData = Map<String, dynamic>.from(data);

  if (fromVersion < targetVersion && migrations != null) {
    for (int v = fromVersion + 1; v <= targetVersion; v++) {
      final migrator = migrations[v];
      if (migrator != null) {
        try {
          migrator(ConfigMigrationContext(workingData));
        } catch (e, s) {
          onLog?.call('Migration to schema version v$v failed: $e');
          onError?.call(e, s);
          throw ConfigMigrationException(
            fromVersion: fromVersion,
            toVersion: targetVersion,
            failedAtVersion: v,
            cause: e,
            stackTrace: s,
          );
        }
      }
    }
  }

  workingData[schemaVersionKey] = targetVersion;

  return ConfigMigrationResult(
    data: workingData,
    fromVersion: fromVersion,
    toVersion: targetVersion,
    didMigrate: true,
  );
}

/// The result of running schema migrations on configuration data.
@immutable
class ConfigMigrationResult {
  /// The resulting flattened configuration data after applying all migrations.
  final Map<String, dynamic> data;

  /// The original schema version prior to migration.
  final int fromVersion;

  /// The final schema version of [data].
  final int toVersion;

  /// Whether any migrations were executed or the schema version was updated,
  /// indicating that changes should be flushed to disk.
  final bool didMigrate;

  const ConfigMigrationResult({
    required this.data,
    required this.fromVersion,
    required this.toVersion,
    required this.didMigrate,
  });
}

/// Exception thrown when a configuration schema migration step fails.
class ConfigMigrationException implements Exception {
  /// The schema version of the data prior to starting the migration sequence.
  final int fromVersion;

  /// The target schema version intended for the configuration.
  final int toVersion;

  /// The specific target version step where the migration threw an exception.
  final int failedAtVersion;

  /// The underlying error or exception that caused the migration step to fail.
  final Object cause;

  /// The stack trace associated with [cause].
  final StackTrace stackTrace;

  const ConfigMigrationException({
    required this.fromVersion,
    required this.toVersion,
    required this.failedAtVersion,
    required this.cause,
    required this.stackTrace,
  });

  @override
  String toString() =>
      'ConfigMigrationException: Migration to schema version v$failedAtVersion failed (upgrading from v$fromVersion to v$toVersion): $cause';
}

/// Safely extracts and normalizes the schema version from [value].
///
/// Returns [value] as a positive integer, or `1` if [value] is missing, null,
/// non-numeric, or less than 1.
int parseSchemaVersion(dynamic value) {
  if (value is int && value >= 1) return value;
  if (value is num && value >= 1) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null && parsed >= 1) return parsed;
  }
  return 1;
}

/// Recursively flattens a nested map into a flat map with dot-separated keys.
Map<String, dynamic> flattenConfigMap(Map<dynamic, dynamic> nested, [String prefix = '']) {
  final result = <String, dynamic>{};

  void flatten(Map<dynamic, dynamic> map, String p) {
    for (final entry in map.entries) {
      final key = entry.key.toString();
      final fullKey = p.isEmpty ? key : '$p.$key';
      final val = entry.value;
      if (val is Map) {
        flatten(val, fullKey);
      } else {
        result[fullKey] = val;
      }
    }
  }

  flatten(nested, prefix);
  return result;
}

/// Recursively un-flattens a flat map with dot-separated keys into a nested map structure.
Map<String, dynamic> unflattenConfigMap(Map<String, dynamic> flat) {
  final result = <String, dynamic>{};

  // Pin schemaVersion to the very top of the generated JSON
  if (flat.containsKey(schemaVersionKey)) {
    result[schemaVersionKey] = flat[schemaVersionKey];
  }

  for (final entry in flat.entries) {
    if (entry.key == schemaVersionKey) continue;
    final key = entry.key;
    final value = entry.value;

    if (!key.contains('.')) {
      result[key] = value;
      continue;
    }

    final segments = key.split('.');
    Map<String, dynamic> current = result;
    for (int i = 0; i < segments.length - 1; i++) {
      final seg = segments[i];
      final existing = current[seg];
      if (existing is Map<String, dynamic>) {
        current = existing;
      } else {
        final newMap = <String, dynamic>{};
        current[seg] = newMap;
        current = newMap;
      }
    }
    current[segments.last] = value;
  }
  return result;
}

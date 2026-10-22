/// A type-safe key-value store for application configurations
/// with synchronous in-memory reads and disk persistence.
library;

export 'src/config_builder.dart' show ConfigBuilder, ConfigEntry;
export 'src/config_migrator.dart' show ConfigMigrator, MigrationHandler;
export 'src/typed_config.dart';

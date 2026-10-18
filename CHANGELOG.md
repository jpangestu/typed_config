## 0.2.0

- **Class-based schemas**: Subclass `Config` using `ConfigBuilder`.
- **Dart 3.2+ support**: Lowered minimum SDK constraint to `^3.2.0`.
- **Domain groups**: Organize settings into modular groups via `builder.group('namespace', SubConfig.new)`.
- **Direct entry access**: Get and set values directly via `entry.value` instead of `config.get`/`config.set`.
- **Entry utilities**: Added `entry.isModified`, `entry.reset()`, `entry.resetAll()`, and reactive `entry.changes` broadcast stream.
- **Specialized builders**: Added `builder.defineEnum()` and `builder.defineList()` with automatic serialization.
- **In-memory testing**: Added `Config.inMemory(create: ...)` for instant unit testing without disk I/O.
- **Schema migrations**: Added `ConfigMigrator` and `MigrationHandler` with path helpers (`rename`, `transform`, `read`, `write`, `remove`, `containsKey`, `raw`) for sequential version upgrades in `Config.initialize` and `Config.inMemory`.

## 0.1.1

- Updated repository links, documentation, and license metadata.

## 0.1.0

- Initial release.
- Strongly-typed `ConfigEntry` model with type-safe fallback parsing and serializer support.
- In-memory synchronous frame-0 reads with zero loading latency.
- Debounced atomic file writes (300ms) with auto-creation of missing parent directories.
- Dot-separated key namespacing with automatic nesting into indented JSON on disk.
- Sequential schema migrations with version tracking.
- Automatic quarantine of corrupt JSON files with fallback to clean defaults.
- Desktop file watcher with reload notifications.
- Pure Dart engine with zero framework dependencies.

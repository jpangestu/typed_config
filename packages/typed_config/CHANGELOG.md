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

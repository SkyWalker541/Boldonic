## Boldonic v1.0.1 — Bug Fix Release

### Fixed
- **Crash on opening book picker** — `storage` module not available on device; log now searches common KOReader data directories via lfs
- **Crash during conversion** — `lfs.rename` unavailable on this KOReader build; now uses `os.rename` instead
- **Log directory detection** — Now searches multiple common KOReader data directory locations via lfs
- **Defensive module loading** — All modules loaded with pcall wrappers, graceful fallbacks

### Changed
- `lfs.rename` to `os.rename` (works on all KOReader builds)
- Log directory detection — searches common KOReader data directories via lfs
- All modules loaded with pcall wrappers, graceful fallbacks

### Installation
1. Download `boldonic.koplugin-1.0.1.zip`
2. Unzip into `koreader/plugins/` → `koreader/plugins/boldonic.koplugin/`
3. Restart KOReader

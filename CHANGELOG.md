# Changelog

## [Unreleased]

## [2.1.1] - 2026-02-13
- fix: package-lock.json conflict fix (#6)


## [2.1.0] - 2026-02-13
- fix: rename from webp issues (#5)


## [2.0.1] - 2026-02-13
- fix: ci readme update (#4)


## [2.0.0] - 2026-02-13
- Lazywebprename (#3)


## [1.3.0] - 2026-02-10
- fix: dynamic version and rename to lazywebp (#2)


## [1.2.0] - 2026-02-10
- 1.1.1 (#1)


## [1.1.0] - 2026-02-10

### CLI

- Support multiple input files: `lazywebp file1.png file2.jpg dir/`
- Add `-o`/`--output` flag for specifying output directory (replaces second positional argument)
- Non-image files are now skipped with a warning instead of throwing an error
- Temp files are written alongside output instead of system temp directory
- Exit with code 1 when any conversion fails

### macOS App

- Rename app from "ToWebP" to "Lazy Webp"
- Complete UI rewrite with glass/material effects (backwards-compatible with pre-macOS 26)
- Add menu bar extra with quick-open, launch-at-login toggle, and install action
- Add per-file status tracking with progress indicators and size savings display
- Add async concurrency control via `AsyncSemaphore`
- Add custom app icon (all standard macOS sizes)
- Update bundle identifier to `dev.keiver.lazywebp`
- Install script now copies app icon into bundle

## [1.0.0] - 2026-02-09
- Initial release

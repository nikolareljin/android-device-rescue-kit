# Changelog

## 0.1.1

- Improved WhatsApp backup coverage for consumer and business shared-storage media, legacy folders, local backup folders, and exported chat folders.
- Improved Snapchat backup coverage for app media, exported media, legacy folders, and common export directories.
- Added per-app backup notes explaining what ADB can preserve and which official in-app restore steps are still required.

## 0.1.0

- Initial public toolkit for Android diagnostic dumps, data preservation, restore support, and analysis prompt generation.
- Added simple top-level commands: `./dump log`, `./dump data`, and `./prompt`.
- Added configurable Android capture targets under `config/`.
- Added semantic versioning with release branch checks delegated to `ci-helpers`.
- Added local hook setup through `script-helpers`, including optional local secret scanning when available.
- Added privacy guidance and ignored paths for raw captures, backups, bugreports, logs, and extracted device artifacts.

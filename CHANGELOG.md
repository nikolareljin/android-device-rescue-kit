# Changelog

## 0.3.2

- Added automatic release tagging. Merging a `release/X.Y.Z` pull request to `main` now creates the `X.Y.Z` tag; previously nothing in the repository ever created one, so 0.1.0 through 0.3.1 were released untagged.
- Updated the `ci-helpers` reference from a pinned commit to the floating `production` release ref, in the PR gate, the secret scan, and the local bootstrap script.
- Fixed `scripts/bootstrap_script_helpers.sh` printing a submodule failure on every run. It now attempts a submodule update only when one is declared, and otherwise clones the `production` branch directly.

## 0.3.1

- Added a reusable SVG logo and README hero image for the Android rescue workflow.

## 0.3.0

- Added one-line installers for Linux, macOS, and Windows through WSL 2.
- Added stable `android-rescue-dump`, `android-rescue-prompt`, and `android-rescue-update` launchers for direct Unix installs.
- Documented platform setup, Windows path handling, and installer update behavior.

## 0.2.0

- Added the opt-in `./dump data --recovery-profile` workflow for local Android recovery settings, network details, owner-exported password-manager CSV files, and installed-app recovery guidance.
- Added passphrase-encrypted recovery-profile archives and an explicit plaintext-credential retention prompt.
- Added limited, consented root-only collection of known readable Android Wi-Fi system records; private app databases remain out of scope.

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

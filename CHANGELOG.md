# Changelog

## 0.3.2

- Added automatic release tagging. Merging a `release/X.Y.Z` pull request to `main` now creates the `X.Y.Z` tag; previously nothing in the repository ever created one, so 0.1.0 through 0.3.1 were released untagged.
- Updated the `ci-helpers` reference from a pinned commit to the floating `production` release ref, in the PR gate, the secret scan, and the local bootstrap script.
- Fixed `scripts/bootstrap_script_helpers.sh` printing a submodule failure on every run. It now attempts a submodule update only when one is declared for `scripts/script-helpers`, matched on the declared path, and otherwise clones the `production` branch directly.
- Added `scripts/lint.sh`, which runs `bash -n` and `shellcheck` over every shell file in the repository. CI now calls it instead of an inline command, so the same check runs locally. It fails rather than skips when `shellcheck` is missing.
- Fixed timestamps on macOS. `date -Iseconds` is GNU-only; on macOS it failed and left the generated capture reports with an empty `Generated:` line. Replaced with a portable format in the backup dialog, the capture analyzer, and the prompt builder.
- Fixed the triage and prompt commands missing the evidence that matters most. `rg` honours `.gitignore`, and the default capture directory is `captures/<timestamp>/` inside this repository, where `logcat_*.txt`, `dumpsys_*.txt` and the bugreport are all ignored — so kernel panics in logcat were silently absent from every report generated at the default path. Both callers now pass `--no-ignore`.
- Fixed `.gitignore` not matching the capture files the tool actually writes. Rules named `wifi.txt`, `battery.txt` and similar never matched `dumpsys_wifi.txt`, and no rule covered the `*.stderr` siblings, so a capture written to a relative path inside the repository was fully trackable. Replaced with `dumpsys_*.txt` and `*.stderr`.
- Fixed `config/` and `docs/` files being silently ignored by the broad `*.lst`, `*.p` and `*.html` capture rules.
- Fixed `--recovery-profile` being impossible to turn off. Unchecking it in the dialog left it enabled, so the profile was collected against an explicit choice.
- Fixed detection of installed password managers. `adb` returns CRLF, so the exact-match lookup never matched and the recovery guidance was silently skipped.
- Fixed `./dump data` failing on stock macOS bash 3.2, where `"$@"` with no arguments is an unbound-variable error under `set -u`.
- Fixed the Windows installer reporting success when the download failed. Without `pipefail` a failed `curl` fed an empty script to `bash`, which exited 0.
- Fixed `./update` leaving git hooks uninstalled whenever dependency installation failed, which is the first run a new contributor makes. Hooks are now wired first.
- Fixed the bugreport section of the triage report being emitted twice, and extracted artifacts being searched and printed twice.
- Fixed `Release Tag Check` running on every branch and tag creation. Its `create:` trigger carried a `branches:` filter, which GitHub honours only for `push` and `pull_request`, so the filter was inert and the workflow also double-ran on every release branch.
- Added explicit read-only `permissions:` to the PR, security and release-tag workflows.
- Added a vulnerability reporting channel to `SECURITY.md`, which previously gave a reporter nowhere to go.
- `scripts/lint.sh` now checks one file per `bash -n` invocation. `bash -n a b c` parses only `a`; the rest become positional arguments. The previous inline CI command therefore left `prompt`, `update` and every `tools/` script unchecked while appearing to cover them. The hook scripts are now linted too.
- Corrected the version in `README.md` and its privacy-check command, which referenced directories absent from a fresh clone.

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

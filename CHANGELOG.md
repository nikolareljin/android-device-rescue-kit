# Changelog

Header format is `## YYYY-MM-DD — vX.Y.Z`. `ci-helpers` extracts GitHub Release
notes from it and matches nothing else.

## 2026-09-20 — v0.4.0

### Photos are now found, not guessed at

- `./dump photos` finds and copies **every** photo and video on the device, and
  proves it. Discovery no longer means three fixed paths -- `DCIM`, `Pictures`,
  `Movies` -- which missed the removable card, vendor gallery folders, received
  app media and any folder the owner made themselves. Android's MediaStore and
  a filesystem sweep are both enumerated and merged: MediaStore knows about
  files a sweep cannot reach, and the sweep catches files copied in over USB
  that MediaStore has never indexed. Either source alone loses photos.
- Every copy is re-measured against its size on the phone. Failures are retried,
  and anything still missing is written to `missing_photos.txt` with a reason
  while the command exits non-zero. A photo backup that reports success without
  having copied everything is the one outcome this must never produce.
- An interrupted run resumes. A file already present at the right size is
  skipped; one left truncated by a dropped cable is copied again.
- The device's directory structure is preserved rather than flattened, so
  ~10,000 files cannot collide on their filenames.
- `photos_index.txt`, `photos_report.txt`, `missing_photos.txt` and `photos/`
  are gitignored. They carry the full device path of every photo -- filenames,
  folder names, app names, dates -- which is personal data under the same rule
  as the captures themselves.
- Thumbnails, caches and trashed files are excluded. The extension and
  exclusion lists are `config/photo_extensions.txt` and
  `config/photo_exclude_patterns.txt`, read at run time.

### Credential exports

- **Fixed: the "Open Recovery Apps" step never opened anything.** A third
  CRLF-sensitive package match was missed when the other two were fixed in
  0.3.2, so every password manager on the phone went undetected and the step
  silently did nothing.
- Several credential exports can now be imported instead of one. A phone
  routinely holds more than one -- the browser's passwords, a manager's vault,
  an authenticator's seeds -- and the previous single prompt could not express
  that. Names that collide no longer overwrite each other.
- Imports are verified: an export that copies as 0 bytes, or at a different
  size from the phone's, is discarded and reported rather than kept. The old
  path could record OK for an empty file and then offer to delete the phone's
  copy.
- The plaintext secret is no longer stored twice. `credentials.txt` was a copy
  of the import; the file under `imports/` is now the only readable copy, and
  the retention prompt governs it.
- Formats other than CSV are accepted. Managers export `json`, `1pux` and
  `kdbx`, and requiring a CSV rejected valid vaults.

### Keeping both copies of the recovery profile

- The readable recovery profile is **kept by default** alongside the encrypted
  archive. The retention prompt previously defaulted to discarding the
  credential imports; it now defaults to keeping them.
- `--keep-plaintext` and `--discard-plaintext` decide it on the command line
  without a prompt. `--keep-plaintext` is what makes a test run deterministic:
  both artifacts are guaranteed to exist regardless of how a dialog was
  answered.
- Added `tools/verify_recovery_archive.sh`, which decrypts the archive and
  compares its file list and per-file sizes against the readable tree. Keeping
  both copies is only worth anything if they can be proven to agree; a stale or
  truncated archive is now caught rather than assumed good. It exits non-zero
  and names what differs.
- A completed run now names both paths on screen and in the manifest, instead
  of leaving their existence to be inferred.

### Releases

- `CHANGELOG.md` headers are now `## YYYY-MM-DD — vX.Y.Z`, which is the only
  shape `ci-helpers` extracts release notes from. Every previous release is
  reformatted with its real merge date, so notes can be published for them.
- A merged release branch now tags **and** publishes its GitHub Release, chained
  off the tag job rather than dispatched, so it needs no `actions: write`.
- `.github/workflows/create-github-release.yml` publishes notes for a tag that
  already exists, for the releases made before this automation.

### Tests

- Added `tests/`, run by CI. The photo index has unit tests; the backup flow has
  end-to-end tests against a **mock `adb`** backed by a fake device tree, so
  discovery, resume and the failure path are provable without hardware. 54
  assertions.

## 2026-09-20 — v0.3.2

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
- Fixed the encrypted recovery archive being trusted without being checked. The script runs without `pipefail`, so `tar | gpg` reported only gpg's status: when `tar` died part-way the truncated stream was encrypted, `gpg` exited 0, the archive was recorded as OK, and the user was then offered the deletion of the only readable copy of their exported passwords. Both exit statuses are now checked, and the archive must decrypt and list before it is accepted.
- Fixed the backup reporting success when it had written nothing. An unmounted or read-only destination let every capture fail in turn while the run still ended in "Backup Complete". The destination is now checked up front, failed captures are counted, and a partial backup exits non-zero.
- Fixed a permission window on the recovery profile. Its files were created world-readable and only restricted after being moved, so Wi-Fi records and device identifiers were briefly exposed.

## 2026-09-15 — v0.3.1

- Added a reusable SVG logo and README hero image for the Android rescue workflow.

## 2026-09-15 — v0.3.0

- Added one-line installers for Linux, macOS, and Windows through WSL 2.
- Added stable `android-rescue-dump`, `android-rescue-prompt`, and `android-rescue-update` launchers for direct Unix installs.
- Documented platform setup, Windows path handling, and installer update behavior.

## 2026-09-15 — v0.2.0

- Added the opt-in `./dump data --recovery-profile` workflow for local Android recovery settings, network details, owner-exported password-manager CSV files, and installed-app recovery guidance.
- Added passphrase-encrypted recovery-profile archives and an explicit plaintext-credential retention prompt.
- Added limited, consented root-only collection of known readable Android Wi-Fi system records; private app databases remain out of scope.

## 2026-09-14 — v0.1.1

- Improved WhatsApp backup coverage for consumer and business shared-storage media, legacy folders, local backup folders, and exported chat folders.
- Improved Snapchat backup coverage for app media, exported media, legacy folders, and common export directories.
- Added per-app backup notes explaining what ADB can preserve and which official in-app restore steps are still required.

## 2026-05-25 — v0.1.0

- Initial public toolkit for Android diagnostic dumps, data preservation, restore support, and analysis prompt generation.
- Added simple top-level commands: `./dump log`, `./dump data`, and `./prompt`.
- Added configurable Android capture targets under `config/`.
- Added semantic versioning with release branch checks delegated to `ci-helpers`.
- Added local hook setup through `script-helpers`, including optional local secret scanning when available.
- Added privacy guidance and ignored paths for raw captures, backups, bugreports, logs, and extracted device artifacts.

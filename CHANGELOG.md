# Changelog

Header format is `## YYYY-MM-DD — vX.Y.Z`. `ci-helpers` extracts GitHub Release
notes from it and matches nothing else.

## 2026-09-21 — v0.7.0

### A progress bar for the long copies

- Copying several thousand photos off a phone took an hour and reported one
  line per 250 files. There was no way to tell a slow copy from a stalled one.
- `adrescue photos` now runs inside a single `dialog` gauge from start to
  finish. Every phase reports into it: the MediaStore query, the filesystem
  sweep, reading a size for every file, the copy, the verification that
  re-measures each file against the phone, each retry round, and the final
  measurement. It shows the percentage, the count, and the file in flight.
- Those first phases used to print plain lines and only then hand the terminal
  to a progress bar, so the display changed shape twice in the middle of a
  rescue, and the slowest step before the copy -- a size for every one of
  several thousand files -- showed nothing at all. The bar now moves once,
  forwards, across the whole run.
- Anything the operator still needs after the bar comes down, such as the
  discovery counts and any retry warning, is held back and printed then.
  Writing it to the terminal while the gauge owned the screen would have torn
  the display.
- It degrades rather than disappears. With no terminal, no `dialog`, or
  `ANDROID_RESCUE_PROGRESS=never`, the periodic lines are kept, which is what
  belongs in a log anyway. `ANDROID_RESCUE_PROGRESS=always` forces the gauge.
- The gauge is fed through a FIFO rather than `loop | dialog --gauge`. A piped
  loop runs in a subshell, so every counter it increments is discarded when
  the pipeline ends: the run would have reported "Copied this run: 0" having
  copied everything. That number is the whole contract of this command, since
  someone wipes a phone on the strength of it.

## 2026-09-21 — v0.6.3

### A recovery profile with no passwords in it is not a failed backup

- Reported from a real run. The owner keeps passwords in their Google account,
  so they selected no credential provider. Everything else was captured, and
  the run still ended with **"Recovery profile was not completed"** and exit 1.
  The profile had in fact been captured in full; what the user declined was the
  passphrase for an archive that had nothing secret to hold.
- Declining the passphrase is now a choice rather than a failure when no
  credential export was imported. The readable profile is the deliverable, and
  the run says where it is and that it is unencrypted. With exports present the
  run still fails, because someone's passwords are then sitting in the clear.
- A failed recovery profile no longer aborts the whole backup. Photos,
  downloads and everything else the user selected had not run yet, and
  abandoning them protects nothing. The failure is counted and reported by the
  closing summary, which still exits non-zero.
- `--non-interactive` promised never to reach a dialog and then asked for a
  passphrase, so an unattended `--recovery-profile` run could not finish unless
  `--no-encrypt` was passed as well. It no longer asks.
- Nothing about the credential-export options changed. Every password manager
  and authenticator in `config/recovery_apps.txt` is still offered, the prompt
  still accepts several exported files, and the attended path now has tests so
  those options cannot be narrowed unnoticed. `tests/test_backup_flows.sh`
  (renamed from `test_backup_noninteractive.sh`) covers both attended and
  unattended runs; there was no attended coverage before, which is how this
  shipped.


## 2026-09-21 — v0.6.2

### The analysis prompt is private

- `adrescue prompt` wrote `analysis_prompt.md` at the default umask, and the
  documentation offered `/tmp/android-analysis-prompt.md` as the example path.
  The file holds what its own closing privacy line enumerates: device serials,
  carrier and telephony state, Wi-Fi identifiers, the installed-app inventory
  and crash snippets. On a shared machine any local user could read it.
- It is now created under `umask 077` and `chmod 600` before a single byte is
  written, rather than tightened afterwards. A symlink already sitting at the
  output path is refused rather than followed, since it would redirect the
  write somewhere the caller did not choose.
- The `/tmp` example is gone. `tests/test_analysis_prompt.sh` asserts the mode
  of a generated prompt, for both the default path and an explicit one.

### Links that 404 on the published site

- `docs/` is published verbatim with no Markdown rendering, so the twelve
  `../config/...`, `../VERSION` and `../CHANGELOG.md` links in the guides
  escaped the site root. They resolved only in GitHub's file browser.
- They are absolute blob URLs now, which work in both places. Each was checked
  by fetching it.

## 2026-09-21 — v0.6.1

### Leftovers from the adrescue rename

- The README banner still showed `$ ./dump data --recovery-profile`. It is the
  first thing anyone sees on the repository page, and it named a command the
  documentation no longer mentions. It now reads `adrescue data
  --recovery-profile`, and fits inside the terminal box: the old text already
  overflowed its right border.
- `tools/android_backup_dialog.sh` fell back to printing `./dump data` in its
  usage line when run directly rather than through `adrescue`. It now names its
  own path, matching `android_restore_dialog.sh` and
  `verify_recovery_archive.sh`.

## 2026-09-21 — v0.6.0

### One command

- Everything is now `adrescue`: `adrescue probe`, `adrescue photos /mnt/rescue`,
  `adrescue data /mnt/rescue --recovery-profile`. From a git clone it is
  `./adrescue`, and the help text says back whichever spelling you typed.
- `tools/android_restore_dialog.sh` and `tools/verify_recovery_archive.sh` had
  no top-level command. From an installed copy they were unreachable, because
  `tools/` is not on PATH. They are now `adrescue restore` and
  `adrescue verify`.
- Restore is the only command that writes to a phone, so it now names the
  target device, prints what is about to be written, and requires the word
  `restore` typed at a terminal. With more than one phone attached it stops and
  lists them rather than picking one.
- `./dump`, `./dump.sh`, `./prompt`, `./update` and the three
  `android-rescue-*` launchers keep working, silently and undocumented.

### The installed launchers never worked

- `android-rescue-dump probe` resolved its own directory with `dirname "$0"`,
  which through a symlink is `~/.local/bin`, so it looked for
  `~/.local/bin/tools/android_device_probe.sh` and exited 127. The same held
  for `android-rescue-prompt` and `android-rescue-update`. Every entrypoint now
  follows the symlink chain to the real install directory.
- The installer stopped printing a hint about PATH and started fixing it, in
  the shell's own startup file and `~/.profile`. The appended block guards
  itself, so sourcing it twice cannot put the directory on PATH twice. fish
  gets its own `conf.d` file in fish syntax; an unrecognised shell is never
  edited.
- A fresh install now clones the latest release tag rather than the tip of the
  default branch, so a new install and `adrescue update` agree about what is
  current.

### Where rescued data goes

- `photos`, `data` and `log` defaulted to `photos/`, `backups/` and `captures/`
  relative to the current directory. Inside a clone `.gitignore` covered that;
  after an install it scattered personal data wherever the user happened to be
  standing.
- An installed copy now writes to `~/android-rescue/data` and
  `~/android-rescue/work`. Set them with `adrescue config set data-dir
  /mnt/rescue`, `--data-dir`, or `ANDROID_RESCUE_DATA_DIR`, so rescued photos
  can go straight to an external drive. `adrescue config` prints each resolved
  path and where the value came from. A clone keeps the old relative defaults.

### adrescue update

- Upgrading meant re-running the curl installer. It is now a command that moves
  the installation to the latest release: the GitHub releases API when
  reachable, the remote's `X.Y.Z` tags otherwise, sorted numerically so 0.10.0
  sorts above 0.9.0.
- It refuses rather than guesses: uncommitted changes exit 4 and `--force` does
  not override that, a development clone exits 3, an unreachable remote exits 5
  and changes nothing. Already current, or ahead of the latest release, it says
  so and stops. A shallow install stays shallow.
- Installing host dependencies is now `adrescue bootstrap`. `./update` keeps
  its old meaning, because the installer calls it and every existing
  `android-rescue-update` symlink points at it.

### Documentation

- There were three install narratives and they disagreed: README installed PATH
  launchers then told you to run `./dump log`, the site showed only a git clone
  and never mentioned the installer, and three guides opened with
  "install host dependencies: ./update" without saying where the working
  directory came from. `docs/installation.md` now owns the install story and
  everything else carries the same short form.
- The site gained an install section on both pages, and the copy JS moved to
  `docs/assets/copy.js`. The broken-screen page had no script element at all,
  so copy buttons there would have been dead.
- README and `docs/versioning.md` claimed version 0.3.2 against a VERSION of
  0.5.1. Prose no longer carries a version number.

## 2026-09-21 — v0.5.1

### An unreachable phone is not an empty phone

- Found by withholding the authorisation dialog on a handset holding 5,399
  photos: `./dump photos` reported **"No photos or videos were found on the
  device"** and **exited 0**. Not "I could not ask" -- "there is nothing there".
  Someone could read that, believe the phone was already empty, and wipe it.
- `./dump log` and `./dump data` failed differently and no better: both waited
  forever on `adb wait-for-device`, which blocks on a phone that is attached but
  unauthorised and says nothing about why.
- `require_device` now runs before anything else in all four entrypoints. It
  distinguishes ready, unauthorised, offline, absent and multiple, names what it
  found, and waits briefly -- the authorisation dialog is usually behind a lock
  screen and the owner may be about to accept it. Then it exits non-zero having
  written nothing.
- `tools/collect_android_dumps.sh` never sourced `lib/common.sh` at all, so it
  had none of the shared helpers.
- The guard runs before a destination is chosen, because an unreachable phone
  used to leave an empty `backup_manifest.txt` behind -- an artefact that reads
  like a backup was attempted.

This is the same shape as every other defect found this week: "could not
inspect" and "inspected, found nothing" producing identical output. It is
written up in the fleet conventions, and it still shipped here.

## 2026-09-21 — v0.5.0

### The phone stays awake for the step that needs you

- The credential step now runs **first**, before the bulk copies. It is the only
  part that needs someone at the handset, and it used to run last -- after a
  photo copy that took 45 minutes on the phone this was tested against.
- For that step only, the screen is held awake. The previous run opened Samsung
  Pass behind a dark, locked screen and reported `OPENED`: the activity started
  and there was nothing visible to act on.
- The lever is `stay_on_while_plugged_in`, set to `2`, the USB bit alone.
  Deliberately not `svc power stayon true`, which writes the whole mask -- 15 on
  an Android 16 build exposing DOCK -- and would quietly enable stay-awake for
  wireless and dock charging nobody asked about. `screen_off_timeout` is left
  alone: on a Samsung handset `com.samsung.android.lool` owns it and rewrites it.
- **That setting survives a reboot, so it is restored through an EXIT, INT and
  TERM trap**, armed before the value is touched. The repository had no INT or
  TERM trap anywhere until now, so an interrupted run would have left a
  stranger's phone permanently set to never sleep while charging. The recorded
  original is restored, never a hardcoded `0` -- a phone that legitimately had
  stay-awake on keeps it.
- `--no-screen-control` opts out entirely.

### Putting the setting back, when putting it back does not work

- The restore is **read back and compared**, not assumed. `settings put` can be
  accepted into the void by a phone that has been unplugged, rebooted or has
  dropped its debugging authorisation -- all of which happened during testing.
- When the restore does not take, the recorded original is **kept**, and the
  command to apply it by hand is printed. Deleting the record on a failed
  restore destroyed the only evidence of what the phone had, leaving it modified
  and untraceable -- the exact outcome the traps exist to prevent.
- If the record cannot be written at all, the phone is **not touched**. Changing
  a persistent setting with nowhere to note the old value is how a device gets
  left that way for good.
- `[ -s ]` is true for a directory, so a path that could not hold the record was
  read as a record that already existed and the guard above was skipped. `-f`.
- `--recovery-profile` is no longer silently dropped when `--select` omits the
  category. The flag is an instruction; unchecking the box in the dialog is a
  later choice and still wins.

### A locked phone no longer wastes the run

- If the phone cannot be unlocked the credential step is **skipped**, loudly and
  twice -- when it happens and again in the closing summary, which previously
  mentioned only outright failures -- and everything else still completes.
- Unattended, it wakes the phone and polls for two minutes in case somebody is
  nearby, then gives up rather than stalling a scripted run.
- Lock detection reads `showing=` from the keyguard, not `deviceLocked=`: the
  test handset reports `deviceLocked=0` with a swipe lockscreen still covering
  the display, so the obvious field is the wrong one. Unreadable output counts
  as locked, because "dumpsys said nothing" and "the phone is ready" must not
  produce the same answer.

### Pointing at the screen you actually need

- Samsung Pass opens at its import/export menu
  (`SHOW_IMPORT_EXPORT_MENU`) rather than the Settings screen several taps away,
  and the instructions now say that Samsung Pass demands a fingerprint or PIN on
  arrival -- expected, not a fault.
- Google Password Manager gains a real target
  (`GOOGLE_PASSWORD_MANAGER_PROXY_INTENT`). Chrome keeps none, because it has
  none: it hands passwords to Credential Manager, and its password page is a
  WebUI rather than an activity. Its entry now says so instead of implying a
  path that does not exist.

### Tests

- `tests/test_device_screen.sh` -- parsers tested against real `dumpsys window
  policy` output captured from the device, including the case where `showing=`
  and `deviceLocked=` disagree, which is what pins the behaviour.
- The unattended suite gains mock arms for `settings get/put global`,
  `cmd power wakeup` and `dumpsys window policy`; without them the mock's
  catch-all would have made every screen command silently succeed. It asserts
  the original is recorded, a non-default original is preserved rather than
  zeroed, `--no-screen-control` writes nothing, a locked phone skips without
  failing the run, and **the value is restored after a real SIGINT**.

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
- Everything a backup writes is now gitignored: `shared/` (the pulled photos and
  documents themselves), `device/`, `app_notes/`, `backup_manifest.txt` and the
  photo index and report. These were safe only by accident, because the default
  destination is `backups/` -- but the tool accepts any path, including one
  inside this repository, which is exactly the case the privacy rule exists for.
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

### Choosing which password manager to open

- The known managers moved from the source to `config/recovery_apps.txt`, read
  at run time: package, display name, how its export is reached, and optionally
  how to open it. They had been a hardcoded list written out three times, which
  is why **Samsung Pass was in none of them** despite being installed on the
  first phone this was run against.
- `--list-managers` prints what the attached phone actually has.
  `--open-manager PACKAGE` opens one so the owner can run its export; the
  interactive run offers a checklist of what was detected instead of opening
  every match in turn.
- Samsung Pass has no launcher activity — it is reached through Settings — so
  `monkey -p` could never open it and the tool reported "could not open" for
  something that was never openable that way. An app may now carry a launch
  spec, and one with neither a launcher nor a spec is reported as not
  launchable rather than retried.
- Authenticators are listed so they are not forgotten, with the fact stated
  plainly that neither common one can export to a file at all.

### Running unattended, and without encryption

- `--no-encrypt` writes the recovery profile readable and builds no archive, for
  a destination that is already trusted storage and an owner who needs to read
  the files directly. The manifest and the closing summary both say plainly that
  the profile is unencrypted and where it is.
- `--non-interactive`, with `--select` and repeatable `--credential-export`,
  runs the whole backup without prompting. Every prompt now goes through a small
  `ui_yesno`/`ui_msg` layer that returns the default when unattended, so both
  modes execute the same surrounding code rather than two paths that drift.
- Unattended defaults are the cautious ones: collecting root-only Wi-Fi records
  and driving the phone's UI to open a password manager both default to *no*,
  because both assume somebody is standing at the handset.

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
  discovery, resume and the failure path are provable without hardware. An
  unattended backup runs with `dialog` replaced by a stub that fails if it is
  called at all, which is what proves `--non-interactive` reaches no prompt. 88
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

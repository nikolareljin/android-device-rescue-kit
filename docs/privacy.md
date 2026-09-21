# Privacy Guidance

Android diagnostic captures are sensitive.

Assume raw files may contain:

- Device serial numbers and build fingerprints
- Phone numbers, carrier details, SIM state, and cell tower metadata
- Wi-Fi SSIDs, BSSIDs, IP addresses, and network history
- Installed apps, accounts, notifications, intents, and recent activity
- File paths, crash memory snippets, tombstones, and app database errors
- Location-adjacent radio, Bluetooth, and connectivity data

Keep raw captures outside git. This repository ignores common capture paths and file types, but `.gitignore` is only a guardrail. Always check `git status --short` before committing.

That guardrail exists only inside a git clone of this repository. After the
one-line install, which is the normal case, captures are written under
`~/android-rescue` or wherever `adrescue config set data-dir` points, and
nothing there is protected by a `.gitignore`. Treat those directories as
private storage.

If you need to share an example publicly, create a minimal synthetic fixture or manually redacted excerpt that preserves only the diagnostic pattern.

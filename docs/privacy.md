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

If you need to share an example publicly, create a minimal synthetic fixture or manually redacted excerpt that preserves only the diagnostic pattern.

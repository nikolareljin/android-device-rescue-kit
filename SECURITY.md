# Security Policy

## Reporting a vulnerability

Report privately through GitHub Security Advisories:
<https://github.com/nikolareljin/android-device-rescue-kit/security/advisories/new>

Please do not open a public issue for a security report, and do not attach raw
device captures to one — see the data rule below.

Supported version: the latest release. Fixes land on `main` and ship in the next
version.

## Handling device data

Do not publish raw Android captures from real devices.

Bugreports, logcats, tombstones, dumpsys output, kernel logs, app inventories, and backups can contain personal data. Keep those files under ignored directories such as `captures/`, `backups/`, and `*_dumps/`.

Before pushing public changes, run:

```bash
git status --short
```

If a report or fixture is needed for an issue, create a synthetic sample or a manually redacted excerpt that preserves only the diagnostic pattern.

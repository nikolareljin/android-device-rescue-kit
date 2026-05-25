# Security Policy

Do not publish raw Android captures from real devices.

Bugreports, logcats, tombstones, dumpsys output, kernel logs, app inventories, and backups can contain personal data. Keep those files under ignored directories such as `captures/`, `backups/`, and `*_dumps/`.

Before pushing public changes, run:

```bash
git status --short
```

If a report or fixture is needed for an issue, create a synthetic sample or a manually redacted excerpt that preserves only the diagnostic pattern.

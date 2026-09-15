# Versioning

This project uses semantic versioning.

The current version is stored in [VERSION](../VERSION).

## Version Rule

Every behavior, documentation, or script change must update the version before it is merged.

- Patch: bug fixes, wording fixes, small script corrections, capture-list additions that do not change command behavior.
- Minor: new commands, new workflows, new capture modes, new restore or prompt features.
- Major: incompatible command changes, removed workflows, or changed output layout that breaks existing users.

Update both:

- [VERSION](../VERSION)
- [CHANGELOG.md](../CHANGELOG.md)

Release branches must be named `release/X.Y.Z`, matching the value in [VERSION](../VERSION). The local wrapper scripts under `scripts/` delegate release checks and version bumps to `ci-helpers`.

Useful commands:

```bash
./scripts/check_release_version.sh --branch release/0.1.0 --repo .
./scripts/check_release_tag.sh --branch release/0.1.0 --repo . --fetch-tags
./scripts/version_bump.sh patch
```

## Current Version

`0.2.0` adds the opt-in recovery profile workflow; `0.1.0` was the first public version of the current codebase.

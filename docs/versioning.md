# Versioning

This project uses semantic versioning.

The current version is stored in [VERSION](../VERSION).

## Version Rule

Every behavior, documentation, or script change must update the version before it is merged.

- Patch: bug fixes, wording fixes, small script corrections, capture-list additions that do not change command behavior.
- Minor: new commands, new subcommands, renamed or retired command names that still work under their old spelling, new workflows, new capture modes, new restore or prompt features.
- Major: incompatible command changes, removed workflows, or changed output layout that breaks existing users.

Update both:

- [VERSION](../VERSION)
- [CHANGELOG.md](../CHANGELOG.md)

Release branches must be named `release/X.Y.Z`, matching the value in [VERSION](../VERSION). The local wrapper scripts under `scripts/` delegate release checks and version bumps to `ci-helpers`.

## Tagging

Tagging is automatic. Merging a `release/X.Y.Z` pull request into `main` runs the `Auto Tag` workflow, which creates the tag `X.Y.Z` on the merge commit.

Tags are unprefixed: `1.2.3`, never `v1.2.3`. That is not cosmetic.
`adrescue update` finds the latest release by reading this repository's tags
and ordering them as version numbers, so a tag that does not parse as `X.Y.Z`
is a release `adrescue update` will never offer, and a stray `v` on one tag
puts the ordering wrong for every installed copy at once.

Nothing needs to be tagged by hand, and a release branch whose tag already exists is rejected before merge — `check_release_tag.sh` runs on every push to a `release/*` branch and on every pull request, and fails if the tag is taken. A green "tag is available" line in that check means the tag does not exist *yet*; the `Auto Tag` workflow is what creates it on merge.

Versions 0.1.0 through 0.3.0 predate this workflow and remain untagged. `0.3.1` was tagged by hand afterwards, at its merge commit. `0.3.2` is the first version the workflow tagged on its own.

Useful commands:

```bash
scripts/check_release_version.sh --branch release/0.1.0 --repo .
scripts/check_release_tag.sh --branch release/0.1.0 --repo . --fetch-tags
scripts/version_bump.sh patch
scripts/lint.sh
```

## Current version

The current version is in [VERSION](../VERSION); what changed in each release
is in [CHANGELOG.md](../CHANGELOG.md). Neither is restated here, because a
version number copied into prose is a version number that goes stale.

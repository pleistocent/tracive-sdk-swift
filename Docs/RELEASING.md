# Releasing the Swift SDK

A **maintainer** of this repository — `admin` or `maintain`, see [Who can release](#who-can-release) — can cut a complete release: the gates, the tag and
the GitHub release all come out of one workflow dispatch.

Unlike the sibling SDKs there is nothing to set up first — no registry account, no credentials, no
secrets. Swift Package Manager resolves `from: "0.1.0"` against this repository's git tags, so the
tag *is* the package.

## Cut a release

1. **Move the entries out of `## [Unreleased]`** in `CHANGELOG.md` into a `## [0.1.1] — 2026-09-09`
   section and merge that to `main`. The section becomes the GitHub release body.
2. **Actions → Release → Run workflow**, with `version` = `0.1.1` (no `v` prefix).

| Stage | What it does |
| --- | --- |
| `preflight` | Version format, changelog section, tag does not already exist |
| `verify` | The full `ci.yml` gate set — dependency-free check, fixtures, Swift 6 language mode, strict concurrency, `swift test`, the iOS build, the Example app |
| `release` | Tag `v0.1.1` on the dispatched commit, and the GitHub release |

Partners pick it up on their next `swift package update`. There is no registry sync to wait for.

**Rehearse with `dry_run`** — same checks, no tag, no release.

## The tag is published the moment it is pushed

This is the difference that matters between this SDK and its siblings. A Maven Central deployment
is validated before it is released and an npm publish can be deprecated afterwards; a git tag is
visible to every consumer the instant it lands and there is no queue in between.

The consequence is that the gates run **before** the tag, not after. That is the whole design of
the workflow, and it is why `ci.yml` is called rather than trusted to have been run by hand —
automatic CI is off in this repository for cost, so a release dispatch is realistically the only
time these checks run at all.

The second consequence is that a released tag never moves. Re-pointing `v0.1.1` silently changes
what a partner who already pinned it compiles against, with no version change to explain it.
Preflight refuses to release over an existing tag for that reason; the fix is always to bump.

## What the workflow will refuse to do

- **Release a version that is not `x.y.z`.**
- **Release a version with no changelog section.** This is the check that catches the commonest
  mistake here — releasing with the notes still under `## [Unreleased]`.
- **Release a version whose tag already exists.**

There is no "already published" check against a package index, because there is no package index.
The tag check is that check.

## Why there is no version in `Package.swift`

Because SwiftPM has nowhere to put one — a package manifest carries no version, the tag supplies
it. The sibling SDKs all cross-check the dispatched version against a manifest
(`gradle.properties`, `pubspec.yaml`, `package.json`) and this one cannot. `CHANGELOG.md` is the
only other place the number is written down, so the changelog check is doing double duty here.

## Who can release

The `authorize` job runs first and fails the workflow unless the person who dispatched it is
`admin` or `maintain` on this repository. `workflow_dispatch` already requires write access, so
what this adds is the gap between "anyone who can push" and "someone who owns this package" — and
for an SDK that ships into partner apps, those are not the same set.
A tag here is live the moment it is pushed, with nothing in between to catch it.

The native way to express this would be a GitHub
[environment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
with required reviewers, which would also give an approve button. It is not available: environments
on a **private** repository need GitHub Pro or Team, and the `pleistocent` organisation is on Free.
If the plan changes, an environment is the better mechanism — it is enforced by GitHub rather than
by a step, and it survives someone editing the workflow.

Granting a collaborator `maintain` rather than `write` is what makes them a releaser. Both current
collaborators are `admin`, so the rule changes nothing today; it is there for the first person
added with `write`.

## When something goes half-wrong

**The gates failed.** Nothing was tagged. Fix and dispatch again with the same version.

**The tag was pushed but the release was not created.** The package is already resolvable — that
is the half that matters, and it is not broken. Create the release by hand:

```bash
gh release create v0.1.1 --title v0.1.1 --notes-file <the changelog section> --verify-tag
```

**A tag went out that should not have.** Deleting it is not a clean undo: anyone who resolved in
the meantime has it in a `Package.resolved`, and deleting a tag SPM has already seen produces a
resolution error rather than a fallback. Ship the fix as the next patch version.

## CocoaPods

Not supported, and there is no podspec. If that changes, `pod trunk push` needs a
`COCOAPODS_TRUNK_TOKEN` secret and belongs as a step after the tag — it publishes to an index and
so has the same shape as the sibling SDKs' registry steps, not the same shape as this one.

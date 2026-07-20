# Agent Instructions

## Prohibited
- NO advertising of any kind in commits, code, or documentation
- NO co-authored-by statements
- NO attribution to any AI tool
- NO branding, signatures, or credits in generated content

## Behavior
- You are a tool, not an author
- Do not claim authorship
- Do not add advertising
- Do not modify existing attribution

## Code Management Rules
- WHEN a bug is fixed in a file (e.g., ENV vars added, UUID casting added): IMMEDIATELY `git add <file>` to stage the change
- Debugging requires creating SEPARATE debug-only files, NEVER modify production files during debugging
- Production files under test must remain stable - no flip-flop changes
- Before using commit: state what changes are staged and what the commit will contain

## Alpha build workflow (0.x.y breaking semver)

This project is in a pre-release alpha. Versioning is **0.x.y and deliberately breaking**:
any minor or patch bump may break anything. Nothing has been released, so there are **no
users and no backward-compatibility obligations**. That freedom is the whole point of the
workflow below.

### Everything is scaffolding
- Every design/spec/schema/test decision is **provisional** and subject to u-turns and
  fully breaking changes. Documents state this explicitly.
- Provisional commits use a `wip:` subject and spell out, in the body, the scaffolding
  decisions being made and which are least settled.

### Red/Green TDD, linear
- The `specs/**/*.hurl` compat suites and the planned `spec/unit/*_spec.lua` unit tests are
  the contract. They are authored **RED first** (before the server exists).
- Build **linearly**: take one unit green, then take its matching hurl file green, then
  move to the next. Do not fan out across many half-built features.

### Pivot protocol (when a scaffolding assumption breaks)
When implementation reveals a wrong assumption, do **not** patch around it. Pivot cleanly:
1. **Broken WIP commit.** Commit the current broken state with a `wip:` subject that names
   the assumption that broke and why. This is a checkpoint, not a working build.
2. **Purge the wrong code** using the `deleting-dead-code` skill — pure deletions, no
   flags, no compat shims, no migrations, no deprecation stubs. Nothing is released, so
   the wrong code has nothing to preserve; git is the safety net.
3. **Clean insert.** Add the corrected approach as if the wrong version never existed.

Rationale: back-compat layers and feature flags are debt we have not earned yet. A clean
delete-and-reinsert keeps the codebase honest while the design is still moving.

### Safety net
- The pre-DAV RealWorld baseline is the main-branch root commit (`133bd95`). Any deletion
  is restorable with `git checkout 133bd95 -- <path>` (or `git checkout <wip-sha> -- <path>`
  for later states). Delete first, restore on request.

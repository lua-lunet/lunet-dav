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

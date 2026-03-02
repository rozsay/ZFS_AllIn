# CLAUDE.md — ZFS_AllIn

This file provides guidance for AI assistants (Claude and others) working on
this repository. Keep it up to date as the project evolves.

---

## Project Overview

**ZFS_AllIn** is an all-in-one ZFS (Zettabyte File System / OpenZFS) project.
The exact scope is still being defined — this repository was initialized with a
GPL v3 license and is ready for its first implementation.

- **License**: GNU General Public License v3 (see `LICENSE`)
- **Author/Owner**: rozsay <rozsay@gmail.com>
- **Repository**: `rozsay/ZFS_AllIn`

---

## Current Repository State

As of the initial commit, the repository contains **only a LICENSE file**.
No source code, build system, tests, or documentation exist yet.

When code is added, update this file to reflect:
- The chosen implementation language(s)
- Build system and how to run it
- Test framework and how to run tests
- Directory structure conventions

---

## Directory Structure (Planned)

Once development begins, follow a structure appropriate to the implementation
language. Common patterns for ZFS tooling projects:

```
ZFS_AllIn/
├── CLAUDE.md           # This file
├── LICENSE             # GPL v3
├── README.md           # User-facing documentation (create when code exists)
├── src/                # Source code
├── tests/              # Unit and integration tests
├── scripts/            # Helper scripts
└── docs/               # Additional documentation
```

Update this section when the actual structure is established.

---

## Development Workflow

### Branch Strategy

- **`master`** — stable, tagged releases only
- **`claude/<session-id>`** — AI assistant working branches (auto-created per
  session)
- Feature branches should follow the pattern: `feature/<description>`
- Bug fix branches: `fix/<description>`

### Making Changes

1. Always work on a feature or AI-session branch — never commit directly to
   `master`.
2. Write a clear, descriptive commit message summarizing *why* the change was
   made, not just *what* changed.
3. Keep commits atomic: one logical change per commit.
4. Push the branch and open a pull request for review before merging.

### Commit Message Format

```
<type>: <short summary (≤72 chars)>

<optional body explaining the motivation and approach>
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `build`

Example:
```
feat: add pool health monitoring command

Implements the `zfs-allin health` subcommand that checks all pools for
degraded, faulted, or offline vdevs and reports them with severity levels.
```

---

## License Compliance

This project is licensed under **GPL v3**. All source files must include a
license header. Example for shell/Python/C:

```
# ZFS_AllIn — <brief file description>
# Copyright (C) <year> rozsay
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
```

Any third-party dependency must be GPL v3 compatible.

---

## ZFS Context and Conventions

Since this project works with ZFS/OpenZFS, keep the following in mind:

### ZFS Terminology
- **pool** — top-level storage unit (`zpool`)
- **dataset** — filesystem, volume, or snapshot within a pool
- **vdev** — virtual device (disk, mirror, RAIDZ, etc.)
- **zpool** — the CLI tool for pool management
- **zfs** — the CLI tool for dataset management

### Working with ZFS Commands
- ZFS operations often require `root`/`sudo` — document privilege requirements
  clearly in help text and README.
- Prefer `zpool` and `zfs` native commands over direct kernel module interaction.
- Always validate pool/dataset names before passing them to shell commands to
  prevent command injection.
- Destructive operations (destroy, trim, scrub cancel) must prompt for
  confirmation unless `--force` / `--yes` is explicitly passed.

### Safety Rules
- Never run untested ZFS destructive commands (`zfs destroy`, `zpool destroy`,
  `zpool import --force`) in automated tests against real storage.
- Use `zpool create ... -n` (dry-run) and loopback/file-backed vdevs in tests.

---

## Testing

No tests exist yet. When added, document here:
- How to run the full test suite
- How to run a single test
- How to run tests in dry-run / safe mode (no real ZFS operations)
- Required test dependencies

Placeholder (update when tests are written):
```bash
# Run all tests
<command TBD>

# Run a single test
<command TBD>
```

---

## Build / Install

No build system exists yet. When added, document here:
- Prerequisites / system dependencies
- How to build from source
- How to install
- How to run in development mode

Placeholder (update when build system is set up):
```bash
# Install dependencies
<command TBD>

# Build
<command TBD>

# Install locally
<command TBD>
```

---

## Code Quality

Once source code exists, enforce:
- **Linting**: language-appropriate linter (e.g., `shellcheck` for shell,
  `pylint`/`ruff` for Python, `clang-tidy` for C/C++)
- **Formatting**: consistent auto-formatter (`shfmt`, `black`, `clang-format`)
- **No warnings policy**: treat linter warnings as errors in CI

---

## AI Assistant Notes

- This file (`CLAUDE.md`) is the source of truth for project conventions.
  Update it when conventions change — do not let it drift from reality.
- When adding the first source code, establish and document the language,
  build system, and test framework in this file before writing implementation.
- Do not create placeholder source files; only create files that contain real,
  working content.
- When working on a task, always read relevant existing files before editing.
- Keep changes minimal and focused — avoid refactoring unrelated code.
- After completing a feature or fix, update this file if any new conventions
  or workflows were established.

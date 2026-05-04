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

## Directory Structure

```
ZFS_AllIn/
├── CLAUDE.md                            # This file
├── LICENSE                              # GPL v3
├── ubuntu-zfs-root.sh                   # Main all-in-one ZFS installer
├── ZFS-root.conf.example                # Example/template config file
└── install-ubuntu-zfs-encrypted-ext4boot.sh  # Earlier single-purpose installer
```

### Main Script: `ubuntu-zfs-root.sh`

All-in-one Ubuntu-on-ZFS installer.  Subcommands:

| Command | When to run |
|---|---|
| `initial` | From Ubuntu Live USB — partitions disks and installs the OS |
| `postreboot` | After first login on the new system |
| `remoteaccess` | To enable Dropbear SSH for remote unlock at boot |
| `datapool` | To create an additional ZFS data pool |

**Key features implemented:**
- Ubuntu noble (24.04), resolute (26.04), jammy (22.04)
- Root pool topologies: single, mirror, raid0, raidz1, raidz2, raidz3
- Encryption: NOENC / ZFSENC (native AES-256-GCM) / LUKS (whole-disk)
- Remote unlock at boot via Dropbear SSH (port 2222)
- Sanoid automatic snapshot management with timer + APT pre-invoke hook
- zrepl periodic snapshots with configurable retention (optional)
- Google Authenticator TOTP for SSH (optional)
- UEFI (GRUB + efibootmgr) and BIOS boot
- `WIPE_FRESH=n` mode: add a new distro dataset to an existing pool
- Rescue clone dataset created from base install snapshot
- Additional data pool creation with independent encryption and topology
- Config pre-seeding via `ZFS-root.conf` (see `ZFS-root.conf.example`)
- DEBUG mode: `DEBUG=1 sudo bash ubuntu-zfs-root.sh initial`
- All operations logged to `/var/log/zfs-allin/`

### Dataset layout (example: pool=rpool, suite=noble)

```
rpool/ROOT                          # container (canmount=off)
rpool/ROOT/noble                    # root filesystem
rpool/ROOT/noble@base_install       # snapshot at install completion
rpool/ROOT/noble_rescue_base        # clone of base_install (if RESCUE=y)
rpool/ROOT/noble@apt_YYYY-MM-DD-…  # auto-snapshot before apt operations
rpool/home                          # home container
rpool/home/root                     # /root
rpool/home/<username>               # /home/<username>
rpool/usr                           # container
rpool/usr/local                     # /usr/local
rpool/var                           # container
rpool/var/lib                       # /var/lib
rpool/var/log                       # /var/log
rpool/var/mail                      # /var/mail
rpool/var/snap                      # /var/snap
rpool/var/spool                     # /var/spool
rpool/var/www                       # /var/www
rpool/docker                        # Docker data (auto-snapshot=false)
rpool/swap                          # ZFS zvol swap (NOENC/ZFSENC only)
```

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

The project is a set of bash scripts — no build step required.

```bash
# Prerequisites (installed automatically by the script if missing)
# debootstrap zfsutils-linux sgdisk cryptsetup whiptail efibootmgr

# Run the installer from an Ubuntu Live USB:
sudo bash ubuntu-zfs-root.sh initial

# Post-reboot (on the new system):
sudo bash ubuntu-zfs-root.sh postreboot

# Optional: static analysis with shellcheck
shellcheck ubuntu-zfs-root.sh
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

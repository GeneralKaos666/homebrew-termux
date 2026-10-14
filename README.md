# homebrew-termux

Native Homebrew port for Termux Android (ARM64). No proot, no chroot, no containers, no emulation, no root.

Upstream Homebrew is pinned to **7.0.9** (`cdc1ca5`). The compatibility patches are written against that exact revision, so the installer checks out the tag and keeps a local branch (`stable`) on top of it. `brew update`'s Termux guard rebases that branch instead of resetting the repository, so the patches (and the pinned revision) survive.

## What Works

Verified by `bash test.sh` (18/18) on Termux aarch64:

| Command | Status | Notes |
|---------|--------|-------|
| `brew --version` / `--help` / `config` | ✅ | |
| `brew search` / `brew info` | ✅ | formulae.brew.sh JSON API, no tap clone |
| `brew install --force-bottle` | ✅ | The pinned `arm64_linux` bottle pours and runs as-is |
| `brew reinstall --force-bottle` | ✅ | |
| `brew uninstall` | ✅ | |
| `brew link` / `brew unlink` | ✅ | |
| `brew list --versions` | ✅ | |
| `brew update` | ✅ | Local patch commit preserved |
| `brew upgrade` | ✅ | |
| `brew tap` | ✅ | |
| `brew update-reset` | ✅ | Destructive by design; re-applies the patches itself |

Installed bottles run directly. There is no post-install `patchelf` step: Homebrew's own `symlink_ld_so` points `$HOMEBREW_PREFIX/lib/ld.so` at Termux's glibc loader, so poured binaries already have the right interpreter and RPATH (see *How It Works*).

## How It Works

1. **glibc loader bridge.** Homebrew bottles are built against glibc; Termux is Bionic. `patches/termux-structural.patch` prepends `$PREFIX/glibc/lib/ld-linux-*.so.*` to `OS::Linux::LD::DYNAMIC_LINKERS` (arm, arm64, i386, x86_64), ahead of `/system/bin/linker*`. Homebrew then creates `$HOMEBREW_PREFIX/lib/ld.so` → glibc loader, and every poured binary is left with that interpreter plus an RPATH into the Cellar and `$HOMEBREW_PREFIX/lib`.

2. **Sanitised entry point.** Termux exports `LD_PRELOAD`/`LD_LIBRARY_PATH` pointing at Bionic libraries; a glibc process started with those set resolves Bionic's `libc.so` (a linker script, not an ELF object) and aborts. `apply-patches.sh` writes `$BREW/bin/brew-glibc-bash`, which clears those variables, sets `TMPDIR`, `HOMEBREW_SPAWN_SYSTEM` and `HOMEBREW_NO_RELOCATE_BUILD_PREFIX`, then `exec`s the glibc loader with glibc bash. `bin/brew`'s shebang points at it.

3. **Fork avoidance.** Android's kernel blocks `pthread_rwlock_unlock` in forked children, which crashes Ruby's `fork`-based spawn paths. The patch replaces those with `Process.spawn`, and `utils/popen.rb` uses the spawn path (`Homebrew.termux?` or `HOMEBREW_SPAWN_SYSTEM=1`).

4. **Hard links.** Android's app-data (FUSE) filesystem cannot create hard links, but bottles contain them. `$PREFIX/bin/brew-tar` wraps `tar`, tolerates the hard-link error class, and still reports any other failure.

5. **Path redirection.** Hardcoded FHS paths are rewritten to Termux equivalents: `/usr/bin/env`, `/bin/bash`, `/usr/bin/ldd`, `/usr/bin/stat`, `/usr/bin/tput`, `/etc/os-release`. `HOMEBREW_DEFAULT_TEMP` becomes `$PREFIX/tmp` (Android has no writable `/tmp` or `/var/tmp`) and `LC_ALL=C.UTF-8` is forced, because Termux ships no `locale` binary and `LC_ALL=C` makes Ruby parse JSON as US-ASCII.

6. **Patch persistence.** Two mechanisms, because neither covers everything:
   - `brew update` — `patches/termux-update-guard.patch` makes `cmd/update.sh` rebase the local branch onto the pinned tag instead of force-resetting it. If the rebase conflicts it aborts and skips the self-update with a warning, leaving the repository exactly as it was.
   - `brew update-reset` — this command is destructive by design and runs git with `core.hooksPath=/dev/null`, so a git hook **cannot** cover it. The patch adds a step to its own function that calls `apply-patches.sh` back (its path is recorded in the checkout's local git config) once the reset is done.
   - Belt and braces: `post-merge`, `post-checkout` and `post-rewrite` hooks in `$BREW/.git/hooks` also re-run `apply-patches.sh`.

## Patches

The patches target the pinned revision exactly. Every upstream edit lives in a maintained patch so the result is byte-exact and reproducible:

| File | Contents |
|------|----------|
| `patches/termux-structural.patch` | All 16 upstream source edits: Termux detection, the glibc loader bridge, fork-free spawning, FHS path redirection, temp dir and locale, the `brew update-reset` re-apply step, and accepting longer-prefix bottles |
| `patches/termux-update-guard.patch` | `Library/Homebrew/cmd/update.sh` only: rebase instead of reset |

Two edits are **not** in the patches, because a static patch cannot carry them, and `apply-patches.sh` makes them with marker-guarded `sed` instead:

- `bin/brew` — its shebang embeds this checkout's absolute path (the `brew-glibc-bash` runner), plus a Termux-safe `PATH` and the `env`/`bash` exec paths.
- `$PREFIX/bin/brew-tar` — a new file that lives outside the repository.

`apply-patches.sh` is idempotent: it uses `git apply`'s own reverse-apply check to decide whether a patch is already in the tree, so re-running it applies nothing. If a patch neither applies nor reverse-applies (wrong revision, or an older patch version is installed), it stops with a clear message instead of committing a half-patched tree.

### Changing the patches

Bump the tag and revision in `config.sh` together, regenerate the patches against the new revision, and re-run `bash install.sh`. Because the patches are versioned as a whole, an existing install is not upgraded in place — `apply-patches.sh` will refuse rather than half-apply. Use `bash uninstall.sh && bash install.sh`.

## Known Limitations

- **`--force-bottle` is required.** The pinned bottles are built at `/home/linuxbrew/.linuxbrew` and their Cellar path is shorter than Termux's, so Homebrew does not consider them relocatable. Without the flag it falls back to a source build.
- **Build-prefix relocation is skipped.** Termux's prefix is longer than the Linux bottle prefix, and Homebrew relocates raw binary C strings in place only to an equal-or-shorter prefix. The runner sets `HOMEBREW_NO_RELOCATE_BUILD_PREFIX=1`, so those strings stay stale (cosmetic, e.g. an embedded `localedir`). Placeholdered text and RPATH/interpreter relocation are length-independent and still run, so binaries work.
- **Building from source is not supported.** These patches cover the bottle path only; the earlier `build-from-source-fixes.patch` has been removed.
- **Bubblewrap sandbox is disabled** (Android has no unprivileged user namespaces).
- **`brew update` does not move off the pinned tag.** That is intentional: the patches are revision-specific.

## Architecture

```
Termux (Android ARM64)
├── $PREFIX/glibc/            # GNU C Library (pkg: glibc-runner)
│   ├── lib/ld-linux-aarch64.so.1
│   └── bin/{bash,ldd,patchelf}
├── $PREFIX/bin/{ruby,git,curl,tar,stat,env,tput}
├── $PREFIX/bin/brew-tar      # hard-link-tolerant tar wrapper (generated)
└── ~/brew/                   # Homebrew checkout (HOMEBREW_REPOSITORY)
    ├── bin/brew              # shebang -> bin/brew-glibc-bash
    ├── bin/brew-glibc-bash   # sanitised glibc entry point (generated)
    ├── bin/brew-termux       # convenience wrapper
    ├── lib/ld.so -> $PREFIX/glibc/lib/ld-linux-aarch64.so.1
    ├── Cellar/               # installed packages
    └── Library/Homebrew/     # patched source (committed locally)
```

## Installation

```bash
# Prerequisites: glibc-runner brings glibc, glibc bash and patchelf-glibc
pkg install git ruby curl glibc-runner

# Install (clones Homebrew 7.0.9 into ~/brew, patches it, installs the hooks)
bash <(curl -fsSL https://raw.githubusercontent.com/rianprei/homebrew-termux/main/install.sh)

# Or clone and install
git clone https://github.com/rianprei/homebrew-termux.git
cd homebrew-termux
bash install.sh
```

The installer copies `apply-patches.sh`, `config.sh` and `patches/` to `~/.homebrew/homebrew-termux/` so the git hooks keep working even if this repository is removed, and adds `~/brew/bin` to `.bashrc`/`.zshrc`.

## Usage

```bash
# Using the wrapper (recommended)
brew-termux search wget
brew-termux install wget
brew-termux list

# Or add ~/brew/bin to PATH and use brew directly
export PATH="$HOME/brew/bin:$PATH"
brew install --force-bottle wget
```

## Uninstall

```bash
bash uninstall.sh
```

Removes `~/brew`, `~/.homebrew`, `~/.cache/Homebrew`, `$PREFIX/bin/brew-tar` and the `PATH` lines the installer added.

## Testing

```bash
bash test.sh
```

Runs 18 checks against `~/brew` end to end (basic commands, search/info, bottle install, ELF/interpreter/RPATH validation and execution of `hello`, link/unlink, reinstall, uninstall, update/upgrade, tap).

## ELF Binary Validation

After installing a package, validate the binary:

```bash
file ~/brew/Cellar/hello/2.12.3/bin/hello
# ELF 64-bit LSB pie executable, ARM aarch64

readelf -l ~/brew/Cellar/hello/2.12.3/bin/hello | grep interpreter
# [Requesting program interpreter: /data/data/com.termux/files/home/brew/lib/ld.so]

readelf -d ~/brew/Cellar/hello/2.12.3/bin/hello | grep NEEDED
# Shared library: [libc.so.6]      (glibc, not bionic)

hello
# Hello, world!
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `bash test.sh`
5. Submit a pull request

## License

MIT License. Same as Homebrew.

## Acknowledgments

- [Homebrew](https://brew.sh/) - The original package manager
- [Termux](https://termux.dev/) - Android terminal emulator
- [patchelf](https://github.com/NixOS/patchelf) - ELF binary patching tool

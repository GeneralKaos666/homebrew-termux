# homebrew-termux configuration
# Sourced by install.sh. Every value can be overridden from the environment.
# No hardcoded personal paths.

# ─── Pinned Homebrew revision ───────────────────────────────────────────────
# The maintained patches in ./patches target this revision exactly, so the tag
# and the revision are pinned together: bump both, re-run apply-patches.sh, and
# regenerate the patches against the new revision in the same commit.
HOMEBREW_BREW_GIT_URL="${HOMEBREW_BREW_GIT_URL:-https://github.com/Homebrew/brew.git}"
HOMEBREW_BREW_GIT_TAG="${HOMEBREW_BREW_GIT_TAG:-7.0.9}"
HOMEBREW_BREW_GIT_REVISION="${HOMEBREW_BREW_GIT_REVISION:-cdc1ca503231b9a96da64526774915d913c3ec9f}"
# Local branch the pinned revision is installed on. `brew update`'s Termux guard
# rebases this branch onto the pinned tag instead of resetting the repository.
HOMEBREW_BREW_GIT_BRANCH="${HOMEBREW_BREW_GIT_BRANCH:-stable}"

# ─── Termux paths ───────────────────────────────────────────────────────────
TERMUX_PREFIX="${TERMUX_PREFIX:-/data/data/com.termux/files/usr}"
TERMUX_GLIBC_PREFIX="${TERMUX_GLIBC_PREFIX:-${TERMUX_PREFIX}/glibc}"
TERMUX_GLIBC_BASH="${TERMUX_GLIBC_PREFIX}/bin/bash"
TERMUX_GLIBC_LD="${TERMUX_GLIBC_PREFIX}/lib/ld-linux-aarch64.so.1"
TERMUX_ENV="${TERMUX_PREFIX}/bin/env"
TERMUX_GLIBC_LDD="${TERMUX_GLIBC_PREFIX}/bin/ldd"
TERMUX_RUBY_BIN="${TERMUX_PREFIX}/bin/ruby"

# ─── Install locations ──────────────────────────────────────────────────────
BREW_DIR="${BREW_DIR:-${HOME}/brew}"
# apply-patches.sh is installed here too so the git hooks keep working after
# Homebrew is reset, or when install.sh was piped straight from curl.
TERMUX_REPO_DIR="${TERMUX_REPO_DIR:-${HOME}/.homebrew/homebrew-termux}"

# ─── Architecture ───────────────────────────────────────────────────────────
HOMEBREW_ARCH="${HOMEBREW_ARCH:-$(uname -m)}"
case "${HOMEBREW_ARCH}" in
aarch64 | arm64) HOMEBREW_ARCH="aarch64" ;;
x86_64) HOMEBREW_ARCH="x86_64" ;;
*) HOMEBREW_ARCH="unknown" ;;
esac

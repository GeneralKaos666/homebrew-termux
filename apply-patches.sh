#!/data/data/com.termux/files/usr/bin/bash
# homebrew-termux: apply the Termux compatibility patches to a Homebrew checkout.
#
# Idempotent; safe to run repeatedly. install.sh calls it, and the git hooks in
# $BREW/.git/hooks re-run it after `brew update` / `brew update-reset`.
#
# Two mechanisms, deliberately:
#   1. `git apply` of the maintained patches under ./patches/. Every edit that
#      restructures upstream code lives there, so the result is byte-exact and
#      reproducible against the pinned Homebrew revision (see config.sh).
#   2. marker-guarded `sed` for the two edits that a static patch cannot carry:
#      bin/brew's shebang embeds this checkout's path, and the brew-tar wrapper
#      is a new file outside the repository.
#
# Usage: apply-patches.sh [BREW_DIR] [--commit]
#   BREW_DIR   Homebrew checkout to patch (default: $HOME/brew)
#   --commit   Commit the result locally, so cmd/update.sh's guard recognises
#              the patches as intentional and rebases instead of resetting.
set -euo pipefail

BREW="${1:-$HOME/brew}"
COMMIT=0
[[ "${2:-}" == "--commit" ]] && COMMIT=1

H="${BREW}/Library/Homebrew"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/patches"
TERMUX_PREFIX="/data/data/com.termux/files/usr"
GLIBC_PREFIX="${TERMUX_PREFIX}/glibc"
APPLIED=0

red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info() { green "[homebrew-termux] $*"; }

[[ -d "$H" ]] || {
	red "Homebrew not found at $BREW"
	exit 1
}
[[ -d "${BREW}/.git" ]] || {
	red "$BREW is not a git checkout"
	exit 1
}

TERMUX_DETECTED=0
[[ -n "${TERMUX_VERSION:-}" ]] && TERMUX_DETECTED=1
[[ "${PREFIX:-}" == "$TERMUX_PREFIX" ]] && TERMUX_DETECTED=1
[[ -d "$GLIBC_PREFIX" ]] && TERMUX_DETECTED=1
[[ $TERMUX_DETECTED -eq 0 ]] && {
	red "Not Termux"
	exit 1
}

# Record where this script lives, so `brew update-reset` can call it back after
# it force-checks-out upstream over the patches. That command runs git with
# hooks disabled, so a hook cannot cover it; see the hunk it carries.
git -C "$BREW" config --local homebrew-termux.applypatches \
	"${SCRIPT_DIR}/apply-patches.sh" 2>/dev/null || true

# --- helper: true when a marker is absent, i.e. the change still needs doing ---
need() { ! grep -q "$1" "$2" 2>/dev/null; }

# --- helper: apply a maintained patch, idempotently ---
# $1 patch basename.
# Git's own reverse-apply check answers "is this patch already in the tree?",
# which a grep marker cannot: a regenerated patch whose hunks changed would slip
# past the marker and silently leave the new hunks unapplied. If neither the
# reverse nor the forward check holds, the patch and the checkout disagree
# (wrong revision, or an older patch version is installed) and we stop rather
# than commit a half-patched tree.
git_patch() {
	local patch="${PATCH_DIR}/${1}"
	[[ -f "$patch" ]] || {
		red "missing patch: $patch"
		exit 1
	}
	git -C "$BREW" apply --check --reverse "$patch" 2>/dev/null && return 0
	if git -C "$BREW" apply "$patch"; then
		info "${1}"
		APPLIED=$((APPLIED + 1))
	else
		red "${1} does not apply to $BREW."
		red "The patches target one pinned Homebrew revision."
		red "Reinstall to pick up a new patch version:"
		red "  bash uninstall.sh && bash install.sh"
		exit 1
	fi
}

# ─── 1. glibc bash runner ────────────────────────────────────────────────────
# Termux exports LD_PRELOAD/LD_LIBRARY_PATH pointing at Bionic libraries. The
# glibc dynamic loader then resolves Bionic's libc.so -- a GNU ld script, not an
# ELF object -- and aborts with "glibc/lib/libc.so: invalid ELF header". Every
# glibc process must therefore start with those two variables cleared, and the
# user's /tmp replaced (Android has none), which is why bin/brew's shebang
# points at this runner below.
RUNNER="${BREW}/bin/brew-glibc-bash"
runner_body="$(
	cat <<'RUNNER'
#!/data/data/com.termux/files/usr/bin/bash
# homebrew-termux: start glibc bash with a Bionic-free environment.
unset LD_PRELOAD LD_LIBRARY_PATH
G=/data/data/com.termux/files/usr/glibc
export TERMUX_NO_TERMUX_EXEC=1
# Linux bottles are built at /home/linuxbrew/.linuxbrew (26 bytes) and Homebrew
# relocates raw binary C strings in place only to an equal-or-shorter prefix.
# Termux's prefix is longer, so skip that step: placeholdered text and
# RPATH/interpreter relocation is length independent and still runs.
export HOMEBREW_NO_RELOCATE_BUILD_PREFIX=1
# Android has no writable /tmp or /var/tmp; Termux keeps its scratch space here.
if [[ -z "${TMPDIR:-}" || ! -w "${TMPDIR}" ]]
then
  TMPDIR=/data/data/com.termux/files/usr/tmp
fi
export TMPDIR
# Makes IO.popen use Process.spawn instead of fork (Android blocks
# pthread_rwlock_unlock in forked children).
export HOMEBREW_SPAWN_SYSTEM=1
exec "$G/lib/ld-linux-aarch64.so.1" --library-path "$G/lib" "$G/bin/bash" "$@"
RUNNER
)"
if [[ ! -f "$RUNNER" ]] || [[ "$(cat "$RUNNER")" != "$runner_body" ]]; then
	printf '%s\n' "$runner_body" >"$RUNNER"
	chmod +x "$RUNNER"
	info "brew-glibc-bash runner"
	APPLIED=$((APPLIED + 1))
fi

# ─── 2. maintained patches ───────────────────────────────────────────────────
# termux-structural.patch carries every upstream edit: Termux detection, the
# glibc loader bridge, fork-free spawning, FHS paths, the locale and temp dirs,
# pouring a longer-prefix bottle without build-prefix relocation, and
# re-applying these patches after `brew update-reset`.
git_patch termux-structural.patch
# termux-update-guard.patch keeps local commits (i.e. these patches) alive
# across `brew update` by rebasing instead of the stock reset.
git_patch termux-update-guard.patch

# ─── 3. bin/brew — shebang, PATH and exec paths ──────────────────────────────
f="${BREW}/bin/brew"
if [[ -f "$f" ]]; then
	if ! head -1 "$f" | grep -qF "$RUNNER"; then
		sed -i "1s|.*|#!${RUNNER} -pu|" "$f"
		info "bin/brew shebang"
		APPLIED=$((APPLIED + 1))
	fi
	if need 'homebrew-termux: PATH' "$f"; then
		# Homebrew filters the user environment down to /usr/bin:/bin,... which
		# does not exist on Termux, so Ruby/Git/curl would never be found.
		sed -i 's|^PATH="/usr/bin:/bin:/usr/sbin:/sbin"$|# homebrew-termux: PATH on Android lives under $PREFIX\nPATH="'"$TERMUX_PREFIX"'/bin:${HOMEBREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin"|' "$f"
		info "bin/brew PATH"
		APPLIED=$((APPLIED + 1))
	fi
	if need "${GLIBC_PREFIX}/bin/bash" "$f"; then
		sed -i "s|exec /usr/bin/env -i|exec ${TERMUX_PREFIX}/bin/env -i|g" "$f"
		sed -i "s|/bin/bash -p \"|${GLIBC_PREFIX}/bin/bash -p \"|g" "$f"
		info "bin/brew exec paths"
		APPLIED=$((APPLIED + 1))
	fi
fi

# ─── 4. brew-tar wrapper ────────────────────────────────────────────────────
# Android's app-data filesystem refuses hard links, but bottles contain them;
# GNOME tar reports that one error class and still extracts everything else, so
# the wrapper tolerates it and passes anything else through. It lives outside
# $BREW, so it cannot be part of the maintained patches.
TAR_WRAPPER="${TERMUX_PREFIX}/bin/brew-tar"
tar_body="$(
	cat <<'TARWRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
# homebrew-termux: tolerate Android's inability to create hard links.
real_tar="/data/data/com.termux/files/usr/bin/tar"
tmpdir="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
[[ -w "$tmpdir" ]] || tmpdir="/data/data/com.termux/files/usr/tmp"
mkdir -p "$tmpdir" 2>/dev/null
tmperr="$(mktemp "$tmpdir/brew-tar.XXXXXX" 2>/dev/null)" || tmperr="$tmpdir/brew-tar.$$"
"$real_tar" "$@" 2>"$tmperr"
rc=$?
if [[ $rc -ne 0 ]] && grep -qvE "Cannot hard link|can't link|hard link|Exiting with failure status|had errors" "$tmperr"; then
  cat "$tmperr" >&2
  rm -f "$tmperr"
  exit $rc
fi
rm -f "$tmperr"
exit 0
TARWRAPPER
)"
if [[ ! -x "$TAR_WRAPPER" ]] || [[ "$(cat "$TAR_WRAPPER")" != "$tar_body" ]]; then
	printf '%s\n' "$tar_body" >"$TAR_WRAPPER"
	chmod +x "$TAR_WRAPPER"
	info "brew-tar wrapper"
	APPLIED=$((APPLIED + 1))
fi

# ─── 5. commit the patched state ────────────────────────────────────────────
# cmd/update.sh's Termux guard rebases local commits; loose working-tree
# changes would instead be stashed and reset away by the stock update path.
if [[ $COMMIT -eq 1 ]]; then
	git -C "$BREW" add -A
	if ! git -C "$BREW" diff --cached --quiet; then
		git -C "$BREW" \
			-c user.email="homebrew-termux@localhost" \
			-c user.name="homebrew-termux" \
			commit --quiet -m "homebrew-termux: Termux compatibility patches"
		info "committed patched state"
		APPLIED=$((APPLIED + 1))
	fi
fi

# ─── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== homebrew-termux: $APPLIED patch(es) applied ==="

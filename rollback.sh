#!/data/data/com.termux/files/usr/bin/bash
# homebrew-termux: reset the Homebrew checkout to a clean, patched state.
#
# The patches are committed locally, so `git checkout -- .` would restore the
# patched state, not upstream. To get back to a known-good tree this resets the
# checkout to the pinned upstream revision and then re-applies the patches.
#
# Usage: rollback.sh [BREW_DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
[[ -f "${SCRIPT_DIR}/config.sh" ]] && source "${SCRIPT_DIR}/config.sh"

BREW="${1:-${BREW_DIR:-$HOME/brew}}"
TAG="${HOMEBREW_BREW_GIT_TAG:-7.0.9}"
GIT="${TERMUX_PREFIX:-/data/data/com.termux/files/usr}/bin/git"

[[ -d "${BREW}/.git" ]] || {
	echo "not a Homebrew git checkout: ${BREW}" >&2
	exit 1
}

echo "=== Resetting ${BREW} to ${TAG} ==="
"$GIT" -C "$BREW" fetch --force --tags origin >/dev/null 2>&1 || true
"$GIT" -C "$BREW" reset --hard "refs/tags/${TAG}"

echo "=== Re-applying the Termux patches ==="
bash "${SCRIPT_DIR}/apply-patches.sh" "$BREW" --commit

echo "=== Rollback complete: ${BREW} is patched at the pinned revision ==="

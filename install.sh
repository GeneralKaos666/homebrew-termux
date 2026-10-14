#!/data/data/com.termux/files/usr/bin/bash
# homebrew-termux: installer for Homebrew on Termux Android
# Usage: bash install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Configuration ──────────────────────────────────────────────────────────
# shellcheck source=config.sh
[[ -f "${SCRIPT_DIR}/config.sh" ]] && source "${SCRIPT_DIR}/config.sh"

PREFIX="${TERMUX_PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${TERMUX_GLIBC_PREFIX:-${PREFIX}/glibc}"
GLIBC_BASH="${TERMUX_GLIBC_BASH}"
GLIBC_LD="${TERMUX_GLIBC_LD}"
GIT="${PREFIX}/bin/git"
RUBY="${TERMUX_RUBY_BIN:-${PREFIX}/bin/ruby}"
CURL="${PREFIX}/bin/curl"
BREW_DIR="${BREW_DIR:-${HOME}/brew}"
REPO_DIR="${TERMUX_REPO_DIR:-${HOME}/.homebrew/homebrew-termux}"
TMP_DIR="${PREFIX}/tmp"
BREW_TAG="${HOMEBREW_BREW_GIT_TAG:-7.0.9}"
BREW_REVISION="${HOMEBREW_BREW_GIT_REVISION:-}"
BREW_BRANCH="${HOMEBREW_BREW_GIT_BRANCH:-stable}"
BREW_URL="${HOMEBREW_BREW_GIT_URL:-https://github.com/Homebrew/brew.git}"

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[homebrew-termux]${NC} $*"; }
warn() { echo -e "${YELLOW}[homebrew-termux]${NC} $*"; }
error() { echo -e "${RED}[homebrew-termux]${NC} $*" >&2; }
die() {
	error "$*"
	exit 1
}

# ─── Pre-flight checks ─────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║           homebrew-termux installer v1.0.0                  ║"
echo "  ║     Native Homebrew for Termux Android (ARM64)              ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""

TERMUX_DETECTED=0
[[ -n "${TERMUX_VERSION:-}" ]] && TERMUX_DETECTED=1
[[ "${PREFIX}" == "/data/data/com.termux/files/usr" ]] && TERMUX_DETECTED=1
[[ -d "${GLIBC_PREFIX}" ]] && TERMUX_DETECTED=1
[[ $TERMUX_DETECTED -eq 0 ]] && die "Not running in Termux"

for tool in "$GIT" "$RUBY" "$CURL"; do
	[[ -x "$tool" ]] || die "Required tool not found: $tool (pkg install git ruby curl)"
done

[[ -x "$GLIBC_BASH" ]] || die "glibc not found at $GLIBC_PREFIX (pkg install glibc)"
[[ -x "$GLIBC_LD" ]] || die "glibc ld-linux not found at $GLIBC_LD"

info "Prerequisites OK"

# ─── Create directories ─────────────────────────────────────────────────────
mkdir -p "$BREW_DIR" "${HOME}/.cache/Homebrew" "$TMP_DIR"
info "Created directories"

# ─── Clone the pinned Homebrew revision ────────────────────────────────────
# The patches under ./patches are written against one revision, so the checkout
# is pinned to a tag and never left tracking a moving branch. Cellar and
# Caskroom must exist before anything lists installed formulae.
if [[ -d "${BREW_DIR}/.git" ]]; then
	info "Homebrew already cloned at $BREW_DIR"
else
	info "Cloning Homebrew ${BREW_TAG}..."
	$GIT clone --depth=1 --branch "$BREW_TAG" "$BREW_URL" "$BREW_DIR"
	$GIT -C "$BREW_DIR" checkout -q -b "$BREW_BRANCH"
	$GIT -C "$BREW_DIR" branch --set-upstream-to="refs/tags/${BREW_TAG}" "$BREW_BRANCH"
fi
mkdir -p "${BREW_DIR}/Cellar" "${BREW_DIR}/Caskroom"

if [[ -n "$BREW_REVISION" ]]; then
	actual="$($GIT -C "$BREW_DIR" rev-parse HEAD)"
	if [[ "$actual" != "$BREW_REVISION" ]]; then
		warn "Existing checkout is at ${actual:0:12}, expected ${BREW_REVISION:0:12} (${BREW_TAG})."
		warn "Re-run with a clean checkout (bash uninstall.sh) to pin it."
	fi
fi

# ─── Copy the patch tooling next to the install ────────────────────────────
# The git hooks below must keep re-applying the patches even if this repository
# is gone, so the parts they need are copied out of it once.
mkdir -p "$REPO_DIR"
cp -f "${SCRIPT_DIR}/apply-patches.sh" "${SCRIPT_DIR}/config.sh" "$REPO_DIR/"
rm -rf "${REPO_DIR}/patches"
cp -R "${SCRIPT_DIR}/patches" "${REPO_DIR}/patches"
chmod +x "${REPO_DIR}/apply-patches.sh"
info "Patch tooling installed to $REPO_DIR"

# ─── brew-termux wrapper ───────────────────────────────────────────────────
# A thin alias for people who do not want ~/brew/bin on PATH. bin/brew already
# sanitises the environment through its brew-glibc-bash shebang.
cat >"${BREW_DIR}/bin/brew-termux" <<WRAPPER
#!/data/data/com.termux/files/usr/bin/bash
# homebrew-termux: run Homebrew without adding it to PATH.
exec "${BREW_DIR}/bin/brew" "\$@"
WRAPPER
chmod +x "${BREW_DIR}/bin/brew-termux"

# ─── Apply the Termux patches ──────────────────────────────────────────────
info "Applying Termux patches..."
bash "${REPO_DIR}/apply-patches.sh" "$BREW_DIR" --commit

# ─── Install git hooks ─────────────────────────────────────────────────────
# These re-apply the patches after the operations that rewrite Homebrew's
# working tree. post-checkout is the one that saves `brew update-reset`, which
# force-checks-out the repository by design.
info "Installing git hooks..."
HOOKS_DIR="${BREW_DIR}/.git/hooks"
mkdir -p "$HOOKS_DIR"
for hook in post-merge post-checkout post-rewrite; do
	cat >"${HOOKS_DIR}/${hook}" <<HOOK
#!/data/data/com.termux/files/usr/bin/bash
exec "${REPO_DIR}/apply-patches.sh" "${BREW_DIR}" --commit
HOOK
	chmod +x "${HOOKS_DIR}/${hook}"
done
info "Git hooks installed"

# ─── Verify installation ───────────────────────────────────────────────────
info "Verifying installation..."

if "${BREW_DIR}/bin/brew" --version >/dev/null 2>&1; then
	info "Homebrew version: $("${BREW_DIR}/bin/brew" --version)"
else
	die "Homebrew installation failed"
fi

if "${BREW_DIR}/bin/brew" config >/dev/null 2>&1; then
	info "Homebrew config OK"
else
	warn "Homebrew config has warnings (this is normal for Termux)"
fi

# ─── Add to PATH ────────────────────────────────────────────────────────────
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
	[[ -f "$rc" ]] || continue
	if ! grep -q "homebrew-termux" "$rc" 2>/dev/null; then
		{
			echo ""
			echo "# homebrew-termux"
			echo "export PATH=\"${BREW_DIR}/bin:\$PATH\""
		} >>"$rc"
		info "Added ${BREW_DIR}/bin to PATH in $rc"
	fi
done

# ─── Done ───────────────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║           Installation complete!                             ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║                                                              ║"
echo "  ║  Usage:                                                      ║"
echo "  ║    brew-termux search <formula>                              ║"
echo "  ║    brew-termux install <formula>                             ║"
echo "  ║    brew-termux list                                          ║"
echo "  ║                                                              ║"
echo "  ║  Or add to PATH and use 'brew' directly:                     ║"
echo "  ║    export PATH=\"${BREW_DIR}/bin:\$PATH\"                     ║"
echo "  ║                                                              ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""

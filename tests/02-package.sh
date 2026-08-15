#!/usr/bin/env bash
# Packaging checks, run against the staged release tree rather than the repo.
#
# PKGBUILD here is a template -- pkgver, pkgrel and sha256sums are placeholders
# and .SRCINFO is untracked -- so there is no metadata drift left to check for.
# What matters instead is that scripts/aur-stage.sh produces a complete, correct
# package definition, since that tree is exactly what gets published.
#
# makepkg refuses to run as root, and that guard covers --printsrcinfo and the
# `makepkg -g` that updpkgsums shells out to, so this whole script must run
# unprivileged.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

[[ $(id -u) != 0 ]] || die 'makepkg refuses to run as root; run this script as an unprivileged user'
need_cmd makepkg updpkgsums namcap bsdtar

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
TEST_TAG=v9.9.9-3

group 'staging produces a complete package definition'
# A version that could not appear by accident, so the assertions below prove the
# tag really drove the result.
if "$REPO_ROOT/scripts/aur-stage.sh" "$STAGE" --tag "$TEST_TAG" >"$WORK/stage.log" 2>&1; then
	pass 'aur-stage.sh stages the release tree'
else
	fail 'aur-stage.sh stages the release tree' "$(cat "$WORK/stage.log")"
	summary
	exit 1
fi

check 'staged PKGBUILD takes pkgver from the tag' \
	grep -qx 'pkgver=9.9.9' "$STAGE/PKGBUILD"
check 'staged PKGBUILD takes pkgrel from the tag' \
	grep -qx 'pkgrel=3' "$STAGE/PKGBUILD"
check_fails 'staged PKGBUILD has no placeholder checksums' \
	grep -q "'SKIP'" "$STAGE/PKGBUILD"
check 'staged PKGBUILD has real sha256sums' \
	grep -Eq "sha256sums=\('[0-9a-f]{64}'" "$STAGE/PKGBUILD"
check 'staged .SRCINFO exists' test -s "$STAGE/.SRCINFO"
check '.SRCINFO agrees with the staged pkgver' \
	grep -Eq '^[[:space:]]*pkgver = 9\.9\.9$' "$STAGE/.SRCINFO"
check '.SRCINFO agrees with the staged pkgrel' \
	grep -Eq '^[[:space:]]*pkgrel = 3$' "$STAGE/.SRCINFO"
# The AUR rejects a push without .SRCINFO, so the published .gitignore must not
# carry this repo's rule for it.
check_fails 'staged .gitignore does not ignore .SRCINFO' \
	grep -qx '\.SRCINFO' "$STAGE/.gitignore"

# The template preamble describes this repo, not the published package. Left in,
# it tells AUR users the finished PKGBUILD is a template and points them at
# `make build` and scripts/, neither of which exists in what they cloned.
check_fails 'staged PKGBUILD has no strip markers' \
	grep -q 'aur-stage:strip' "$STAGE/PKGBUILD"
check_fails 'staged PKGBUILD does not call itself a template' \
	grep -qi 'template' "$STAGE/PKGBUILD"
check 'staged PKGBUILD keeps the maintainer line' \
	grep -q '^# Maintainer:' "$STAGE/PKGBUILD"

# Nothing outside the release set may leak into what users clone.
# LC_ALL=C so the ordering matches this list regardless of the caller's locale --
# en_US.UTF-8 sorts dotfiles and case differently from the C collation CI uses.
find "$STAGE" -mindepth 1 -printf '%P\n' | LC_ALL=C sort >"$WORK/staged.files"
if diff -u - "$WORK/staged.files" >"$WORK/staged.diff" <<-'EOF'; then
	.SRCINFO
	.gitignore
	PKGBUILD
	README.md
	initcpio-hooks-tailscale
	initcpio-install-tailscale
	libalpm-hook-tailscale
	libalpm-script-tailscale
	setup-initcpio-tailscale
EOF
	pass 'staged tree contains exactly the release file set'
else
	fail 'staged tree contains exactly the release file set' "$(cat "$WORK/staged.diff")"
fi
endgroup

group 'namcap PKGBUILD'
# namcap exits 0 even when it reports errors, so grade its output instead.
namcap "$STAGE/PKGBUILD" 2>&1 | tee "$WORK/namcap-pkgbuild.log"
check_fails 'namcap reports no errors for PKGBUILD' grep -q ' E: ' "$WORK/namcap-pkgbuild.log"
endgroup

group 'makepkg build'
# --nodeps: the dependencies (mkinitcpio, tailscale, iptables) matter at image
# build time, not for packaging, so skipping them keeps this stage free of
# sudo/pacman.
if (cd "$STAGE" && makepkg --noconfirm --nodeps --force >"$WORK/makepkg.log" 2>&1); then
	pass 'makepkg builds the staged package'
else
	fail 'makepkg builds the staged package' "$(tail -40 "$WORK/makepkg.log")"
	summary
	exit 1
fi
endgroup

PKG=$(echo "$STAGE"/mkinitcpio-tailscale-*.pkg.tar.zst)
[[ -f $PKG ]] || die 'makepkg reported success but produced no package'
info "built $(basename "$PKG")"
check 'the built package is named for the tag' \
	test "$(basename "$PKG")" = 'mkinitcpio-tailscale-9.9.9-3-any.pkg.tar.zst'

group 'namcap package'
namcap "$PKG" 2>&1 | tee "$WORK/namcap-pkg.log"
check_fails 'namcap reports no errors for the package' grep -q ' E: ' "$WORK/namcap-pkg.log"
endgroup

group 'package payload'
bsdtar -tvf "$PKG" | awk '{print $1, $NF}' >"$WORK/payload.modes"
bsdtar -tf "$PKG" | grep -v '^\.' | grep -v '/$' | LC_ALL=C sort >"$WORK/payload.files"

# Modes matter: setup-initcpio-tailscale is run directly by the user, while the
# two initcpio files are sourced by mkinitcpio and must not be executable.
while read -r mode path; do
	if grep -qxF -- "$mode $path" "$WORK/payload.modes"; then
		pass "package ships $path as $mode"
	else
		fail "package ships $path as $mode" \
			"$(printf 'actual entries:\n%s' "$(grep -F -- "$path" "$WORK/payload.modes" || echo '  (path absent)')")"
	fi
done <<-'EOF'
	-rw-r--r-- usr/lib/initcpio/hooks/tailscale
	-rw-r--r-- usr/lib/initcpio/install/tailscale
	-rwxr-xr-x usr/bin/setup-initcpio-tailscale
	-rw-r--r-- usr/share/libalpm/hooks/mkinitcpio-tailscale.hook
	-rwxr-xr-x usr/share/libalpm/scripts/mkinitcpio-tailscale
EOF

# Guards against a stray file sneaking into the package.
if diff -u - "$WORK/payload.files" >"$WORK/payload.diff" <<-'EOF'; then
	usr/bin/setup-initcpio-tailscale
	usr/lib/initcpio/hooks/tailscale
	usr/lib/initcpio/install/tailscale
	usr/share/libalpm/hooks/mkinitcpio-tailscale.hook
	usr/share/libalpm/scripts/mkinitcpio-tailscale
EOF
	pass 'package contains exactly the expected files'
else
	fail 'package contains exactly the expected files' "$(cat "$WORK/payload.diff")"
fi

# The packaged files must be the working-tree files, not a stale copy.
bsdtar -xOf "$PKG" usr/lib/initcpio/install/tailscale >"$WORK/installed-hook"
check 'packaged install hook matches the source file' \
	cmp -s "$WORK/installed-hook" "$REPO_ROOT/initcpio-install-tailscale"
endgroup

# Hand the package to the caller (CI uploads it as an artifact).
if [[ -n ${ARTIFACT_DIR:-} ]]; then
	install -d "$ARTIFACT_DIR"
	cp "$PKG" "$ARTIFACT_DIR/"
	info "copied $(basename "$PKG") to $ARTIFACT_DIR"
fi

summary

#!/usr/bin/env bash
# Packaging checks: metadata drift, a real makepkg build, namcap, and payload
# assertions on the resulting package.
#
# Everything happens in a temporary copy of the sources, so this never dirties
# the working tree -- which also means the drift checks work without git.
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

# Only the files makepkg needs. Copying rather than working in place keeps
# updpkgsums from rewriting the developer's PKGBUILD.
cp -t "$WORK" \
	"$REPO_ROOT/PKGBUILD" \
	"$REPO_ROOT/initcpio-hooks-tailscale" \
	"$REPO_ROOT/initcpio-install-tailscale" \
	"$REPO_ROOT/setup-initcpio-tailscale" || die 'failed to stage sources'
cd "$WORK" || die "cannot cd to $WORK"

group 'metadata is in sync with the sources'

# The failure people actually hit: edit a source script, forget `make update`,
# push a PKGBUILD whose sha256sums no longer match. makepkg would reject it at
# build time anyway, but this check names the fix.
if updpkgsums >"$WORK/updpkgsums.log" 2>&1; then
	if diff -u "$REPO_ROOT/PKGBUILD" "$WORK/PKGBUILD" >"$WORK/pkgbuild.diff"; then
		pass 'PKGBUILD sha256sums match the sources'
	else
		fail 'PKGBUILD sha256sums match the sources' \
			"$(printf 'run "make checksums" (or "make update") and commit the result\n\n%s' "$(cat "$WORK/pkgbuild.diff")")"
	fi
else
	fail 'updpkgsums runs' "$(cat "$WORK/updpkgsums.log")"
fi

if makepkg --printsrcinfo >"$WORK/SRCINFO.new" 2>"$WORK/srcinfo.err"; then
	if diff -u "$REPO_ROOT/.SRCINFO" "$WORK/SRCINFO.new" >"$WORK/srcinfo.diff"; then
		pass '.SRCINFO matches the PKGBUILD'
	else
		fail '.SRCINFO matches the PKGBUILD' \
			"$(printf 'run "make srcinfo" (or "make update") and commit the result\n\n%s' "$(cat "$WORK/srcinfo.diff")")"
	fi
else
	fail 'makepkg --printsrcinfo runs' "$(cat "$WORK/srcinfo.err")"
fi
endgroup

group 'namcap PKGBUILD'
# namcap exits 0 even when it reports errors, so grade its output instead.
namcap PKGBUILD 2>&1 | tee "$WORK/namcap-pkgbuild.log"
check_fails 'namcap reports no errors for PKGBUILD' grep -q ' E: ' "$WORK/namcap-pkgbuild.log"
endgroup

group 'makepkg build'
# --nodeps: the sole dependency is mkinitcpio and building this package does not
# need it installed, which keeps this job free of sudo/pacman.
if makepkg --noconfirm --nodeps --force --cleanbuild >"$WORK/makepkg.log" 2>&1; then
	pass 'makepkg builds the package'
else
	fail 'makepkg builds the package' "$(tail -40 "$WORK/makepkg.log")"
	summary
	exit 1
fi
endgroup

PKG=$(echo "$WORK"/mkinitcpio-tailscale-*.pkg.tar.zst)
[[ -f $PKG ]] || die 'makepkg reported success but produced no package'
info "built $(basename "$PKG")"

group 'namcap package'
namcap "$PKG" 2>&1 | tee "$WORK/namcap-pkg.log"
check_fails 'namcap reports no errors for the package' grep -q ' E: ' "$WORK/namcap-pkg.log"
endgroup

group 'package payload'
bsdtar -tvf "$PKG" | awk '{print $1, $NF}' >"$WORK/payload.modes"
bsdtar -tf "$PKG" | grep -v '^\.' | grep -v '/$' | sort >"$WORK/payload.files"

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
EOF

# Guards against a stray file sneaking into the package.
if diff -u - "$WORK/payload.files" >"$WORK/payload.diff" <<-'EOF'; then
	usr/bin/setup-initcpio-tailscale
	usr/lib/initcpio/hooks/tailscale
	usr/lib/initcpio/install/tailscale
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

# Hand the package to the caller (CI uploads it as an artifact and the boot test
# installs it).
if [[ -n ${ARTIFACT_DIR:-} ]]; then
	install -d "$ARTIFACT_DIR"
	cp "$PKG" "$ARTIFACT_DIR/"
	info "copied $(basename "$PKG") to $ARTIFACT_DIR"
fi

summary

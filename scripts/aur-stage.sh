#!/usr/bin/env bash
# Produce a complete, ready-to-publish package tree in a directory.
#
#   scripts/aur-stage.sh <outdir> [--tag vX.Y.Z[-R]]
#
# The repo's PKGBUILD is a template: pkgver, pkgrel and sha256sums are all
# placeholders, and .SRCINFO is not tracked at all. This script fills them in.
# Everything that needs a real package definition goes through here -- the
# release workflow, `make build`, and tests/02-package.sh -- so none of them can
# drift from what actually gets published.
#
# Without --tag the version placeholders are left alone, which keeps local
# builds and tests deterministic and independent of whether a tag exists.
set -euo pipefail

CMD0="${0##*/}"
die() {
	printf >&2 '%s: %s\n' "$CMD0" "$*"
	exit 1
}

# The complete set of files that belong in a release. .SRCINFO is generated
# below rather than listed here.
#
# No Makefile: every target references scripts/ or tests/, neither of which is
# published, so it would be dead weight in an AUR checkout. Users there build
# the already-generated PKGBUILD with makepkg directly.
AUR_FILES=(
	PKGBUILD
	.gitignore
	LICENSE
	README.md
	initcpio-hooks-tailscale
	initcpio-install-tailscale
	setup-initcpio-tailscale
	libalpm-hook-tailscale
	libalpm-script-tailscale
)

usage() {
	cat <<-EOF
		usage: $CMD0 <outdir> [--tag vX.Y.Z[-R]] [--clean]

		Copies the release file set into <outdir>, applies the version from the
		tag, generates sha256sums and writes .SRCINFO.

		  vX.Y.Z      pkgver=X.Y.Z, pkgrel=1
		  vX.Y.Z-R    pkgver=X.Y.Z, pkgrel=R

		<outdir> must be empty or nonexistent unless --clean is given.
	EOF
}

# parse_tag <tag> -- sets PKGVER and PKGREL
#
# Split on the LAST hyphen: Arch forbids hyphens in pkgver, so whatever follows
# the final one can only be pkgrel. A leading "v" is optional.
parse_tag() {
	local tag=${1#v} ver rel
	if [[ $tag == *-* ]]; then
		ver=${tag%-*}
		rel=${tag##*-}
	else
		ver=$tag
		rel=1
	fi
	[[ $ver =~ ^[A-Za-z0-9._+]+$ ]] ||
		die "invalid pkgver '$ver' from tag '$1' (allowed: alphanumerics . _ +)"
	[[ $rel =~ ^[1-9][0-9]*$ ]] ||
		die "invalid pkgrel '$rel' from tag '$1' (must be a positive integer)"
	PKGVER=$ver
	PKGREL=$rel
}

OUTDIR=''
TAG=''
CLEAN=0
while (($#)); do
	case $1 in
		-h | --help)
			usage
			exit 0
			;;
		--clean)
			CLEAN=1
			shift
			;;
		--tag)
			[[ -n ${2:-} ]] || die '--tag requires a value'
			TAG=$2
			shift 2
			;;
		--tag=*)
			TAG=${1#*=}
			shift
			;;
		-*) die "unknown option: $1" ;;
		*)
			[[ -z $OUTDIR ]] || die 'only one output directory may be given'
			OUTDIR=$1
			shift
			;;
	esac
done
[[ -n $OUTDIR ]] || {
	usage >&2
	exit 2
}

# updpkgsums shells out to `makepkg -g`, and makepkg refuses to run as root.
[[ $(id -u) != 0 ]] || die 'must not run as root (makepkg refuses)'
command -v updpkgsums >/dev/null || die 'updpkgsums not found (pacman-contrib)'
command -v makepkg >/dev/null || die 'makepkg not found'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Refuse to stage on top of existing content: leftovers would sit alongside the
# release set and could be published or tested as if they belonged. Clearing is
# opt-in rather than automatic so a mistyped path cannot wipe a real directory.
if [[ -d $OUTDIR ]] && [[ -n $(ls -A "$OUTDIR" 2>/dev/null) ]]; then
	((CLEAN)) ||
		die "$OUTDIR is not empty; pass --clean to replace its contents"
	find "$OUTDIR" -mindepth 1 -delete
fi

mkdir -p "$OUTDIR"
OUTDIR="$(cd -- "$OUTDIR" && pwd)"

for f in "${AUR_FILES[@]}"; do
	[[ -f $REPO_ROOT/$f ]] || die "missing release file: $f"
	install -m644 "$REPO_ROOT/$f" "$OUTDIR/$f"
done
# setup-initcpio-tailscale is installed 755 by package(); keep the staged copy
# executable so the tree matches the repo.
chmod 755 "$OUTDIR/setup-initcpio-tailscale"

# .SRCINFO is ignored in this repo but is mandatory in the published tree -- the
# AUR rejects pushes without one. Carrying that ignore rule through would make
# `git add` silently skip it.
sed -i '/^\.SRCINFO$/d' "$OUTDIR/.gitignore"

# Drop the template-only preamble. On the AUR the published PKGBUILD is a
# finished definition, so a comment calling it a template and pointing at
# `make build` and scripts/ -- none of which exist there -- is actively
# misleading to anyone reading it before installing.
sed -i '/^# aur-stage:strip-start$/,/^# aur-stage:strip-end$/d' "$OUTDIR/PKGBUILD"
grep -q 'aur-stage:strip' "$OUTDIR/PKGBUILD" &&
	die 'strip markers left in the staged PKGBUILD'

# Order matters: the version has to be final before checksums are generated, and
# both before .SRCINFO is written from the result.
if [[ -n $TAG ]]; then
	parse_tag "$TAG"
	sed -i -e "s/^pkgver=.*/pkgver=$PKGVER/" -e "s/^pkgrel=.*/pkgrel=$PKGREL/" \
		"$OUTDIR/PKGBUILD"
fi

(cd "$OUTDIR" && updpkgsums >/dev/null 2>&1) ||
	die 'updpkgsums failed'
(cd "$OUTDIR" && makepkg --printsrcinfo >.SRCINFO) ||
	die 'makepkg --printsrcinfo failed'

grep -q "^sha256sums=('SKIP'" "$OUTDIR/PKGBUILD" &&
	die 'checksums were not generated (PKGBUILD still has SKIP)'

printf '%s: staged %s-%s in %s\n' "$CMD0" \
	"$(sed -n 's/^pkgver=//p' "$OUTDIR/PKGBUILD")" \
	"$(sed -n 's/^pkgrel=//p' "$OUTDIR/PKGBUILD")" \
	"$OUTDIR"

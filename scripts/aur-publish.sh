#!/usr/bin/env bash
# Publish a release to the AUR.
#
#   scripts/aur-publish.sh [--tag vX.Y.Z[-R]] [--dry-run] [--allow-downgrade]
#
# Stages the release tree with aur-stage.sh, clones the AUR repo, replaces its
# contents with that tree and pushes. Only packaging files are published -- the
# AUR repo is what yay/paru clone, so tests/ and .github/ have no business there.
#
# The version comes from the git tag, defaulting to the one pointing at HEAD, so
# publishing requires a tagged commit.
#
# Set AUR_REMOTE to a scratch repo to rehearse the whole path without touching
# the AUR.
set -euo pipefail

CMD0="${0##*/}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AUR_REMOTE=${AUR_REMOTE:-ssh://aur@aur.archlinux.org/mkinitcpio-tailscale.git}

info() { printf '%s: %s\n' "$CMD0" "$*"; }
die() {
	printf >&2 '%s: %s\n' "$CMD0" "$*"
	exit 1
}

usage() {
	cat <<-EOF
		usage: $CMD0 [--tag vX.Y.Z[-R]] [--dry-run] [--allow-downgrade]

		  --tag              version to publish; defaults to the tag on HEAD
		  --dry-run          show what would be pushed, then stop
		  --allow-downgrade  publish even if it moves the AUR version backwards

		AUR_REMOTE overrides the push target (default: the AUR).
	EOF
}

TAG=''
DRY_RUN=0
ALLOW_DOWNGRADE=0
while (($#)); do
	case $1 in
		-h | --help)
			usage
			exit 0
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
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--allow-downgrade)
			ALLOW_DOWNGRADE=1
			shift
			;;
		*) die "unknown option: $1" ;;
	esac
done

[[ $(id -u) != 0 ]] || die 'must not run as root (makepkg refuses)'
command -v vercmp >/dev/null || die 'vercmp not found (pacman)'

# Publishing always needs an explicit version. Falling back to the tag on HEAD
# means a local `make publish` only works from a tagged commit.
if [[ -z $TAG ]]; then
	TAG=$(git -C "$REPO_ROOT" describe --tags --exact-match 2>/dev/null) ||
		die 'HEAD is not tagged; pass --tag vX.Y.Z or tag the commit first'
	info "using tag $TAG from HEAD"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
"$REPO_ROOT/scripts/aur-stage.sh" "$STAGE" --tag "$TAG"

NEW_VER=$(sed -n 's/^pkgver=//p' "$STAGE/PKGBUILD")
NEW_REL=$(sed -n 's/^pkgrel=//p' "$STAGE/PKGBUILD")

CLONE="$WORK/aur"
info "cloning $AUR_REMOTE"
# Keep git's stderr: host key verification, auth and network failures all report
# here, and they are the first thing to go wrong when setting this up.
git clone --quiet "$AUR_REMOTE" "$CLONE" >"$WORK/clone.log" 2>&1 ||
	die "could not clone $AUR_REMOTE
$(sed 's/^/       /' "$WORK/clone.log")"

# A freshly initialised remote has no commits yet; treat that as a first publish.
if git -C "$CLONE" rev-parse --verify --quiet HEAD >/dev/null; then
	OLD_VER=$(sed -n 's/^pkgver=//p' "$CLONE/PKGBUILD" 2>/dev/null || true)
	OLD_REL=$(sed -n 's/^pkgrel=//p' "$CLONE/PKGBUILD" 2>/dev/null || true)
	if [[ -n $OLD_VER ]]; then
		info "currently published: ${OLD_VER}-${OLD_REL:-1}"
		# vercmp understands pkgrel, so compare the full version strings.
		if [[ $(vercmp "${NEW_VER}-${NEW_REL}" "${OLD_VER}-${OLD_REL:-1}") -lt 0 ]]; then
			((ALLOW_DOWNGRADE)) ||
				die "refusing to publish ${NEW_VER}-${NEW_REL} over ${OLD_VER}-${OLD_REL:-1} (pass --allow-downgrade to override)"
			info 'downgrade allowed by request'
		fi
	fi
else
	info 'remote has no commits yet; this will be the first'
fi

# Replace the tree wholesale so files dropped from the release set disappear
# from the AUR too, then let git work out what actually changed.
find "$CLONE" -mindepth 1 -maxdepth 1 -name .git -prune -o -exec rm -rf {} +
cp -a "$STAGE/." "$CLONE/"

git -C "$CLONE" add -A
if git -C "$CLONE" diff --cached --quiet; then
	info "nothing to publish; the AUR already matches ${NEW_VER}-${NEW_REL}"
	exit 0
fi

info "publishing ${NEW_VER}-${NEW_REL}"
git -C "$CLONE" --no-pager diff --cached --stat

if ((DRY_RUN)); then
	info 'dry run; not committing or pushing'
	exit 0
fi

# Resolve the commit identity up front. Left to git, an unset user.name in a
# fresh environment surfaces as a confusing "empty ident name" from deep inside
# the commit; say plainly what is missing instead.
AUTHOR_NAME=${GIT_AUTHOR_NAME:-$(git -C "$REPO_ROOT" config user.name || true)}
AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-$(git -C "$REPO_ROOT" config user.email || true)}
[[ -n $AUTHOR_NAME && -n $AUTHOR_EMAIL ]] ||
	die 'no commit identity: set git user.name and user.email, or GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL'

git -C "$CLONE" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
	commit --quiet -m "Update to ${NEW_VER}-${NEW_REL}"

# Never force: if the AUR has moved underneath us, fail rather than overwrite.
git -C "$CLONE" push --quiet origin HEAD:master
info "pushed ${NEW_VER}-${NEW_REL} to $AUR_REMOTE"

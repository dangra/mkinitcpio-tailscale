#!/usr/bin/env bash
# Shared helpers for the mkinitcpio-tailscale test suite.
#
# Source this from a test script:
#
#   . "$(dirname "$0")/lib.sh"
#
# It provides logging, a pass/fail tally, and assertions for poking at an
# extracted initramfs image. Call `summary` at the end and exit with its status.
#
# shellcheck shell=bash

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
	C_RED='' C_GREEN='' C_YELLOW='' C_BOLD='' C_OFF=''
fi

TESTS_RUN=0
TESTS_FAILED=0
FAILED_NAMES=()

info() { printf '%s==> %s%s\n' "$C_BOLD" "$*" "$C_OFF"; }
warn() { printf '%s==> WARNING: %s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die() {
	printf '%s==> ERROR: %s%s\n' "$C_RED" "$*" "$C_OFF" >&2
	exit 1
}

# Collapsible sections in the GitHub Actions log, plain headings elsewhere.
group() {
	if [[ -n ${GITHUB_ACTIONS:-} ]]; then
		printf '::group::%s\n' "$*"
	else
		info "$*"
	fi
}
endgroup() {
	if [[ -n ${GITHUB_ACTIONS:-} ]]; then
		printf '::endgroup::\n'
	fi
}

# Indent captured command output so it reads as a detail of the failure above it.
_detail() {
	[[ -n ${1:-} ]] || return 0
	printf '       %s\n' "${1//$'\n'/$'\n'       }"
}

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sok%s   %s\n' "$C_GREEN" "$C_OFF" "$1"
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	FAILED_NAMES+=("$1")
	printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$1"
	_detail "${2:-}"
	if [[ -n ${GITHUB_ACTIONS:-} ]]; then
		printf '::error::%s\n' "$1"
	fi
	return 0
}

summary() {
	printf '\n'
	if ((TESTS_FAILED)); then
		printf '%s%d of %d checks failed%s\n' "$C_RED" "$TESTS_FAILED" "$TESTS_RUN" "$C_OFF"
		printf '  - %s\n' "${FAILED_NAMES[@]}"
		return 1
	fi
	printf '%s%d checks passed%s\n' "$C_GREEN" "$TESTS_RUN" "$C_OFF"
	return 0
}

# --- generic assertions ----------------------------------------------------

# check <description> <command...> — the command must exit 0
check() {
	local desc=$1 out rc
	shift
	out=$("$@" 2>&1)
	rc=$?
	if ((rc == 0)); then
		pass "$desc"
	else
		fail "$desc" "\$ $* (exit $rc)"
		_detail "$out"
	fi
}

# check_fails <description> <command...> — the command must exit non-zero
check_fails() {
	local desc=$1 out rc
	shift
	out=$("$@" 2>&1)
	rc=$?
	if ((rc != 0)); then
		pass "$desc"
	else
		fail "$desc" "command unexpectedly succeeded: $*"
		_detail "$out"
	fi
}

# --- assertions against an extracted image root ----------------------------
#
# All of these take the extraction root as $1 and a path relative to it as $2,
# so failures report the in-image path the reader actually cares about.

# img_has <root> <relpath> — path exists (regular file, dir or symlink)
img_has() {
	local root=$1 rel=$2
	if [[ -e $root/$rel || -L $root/$rel ]]; then
		pass "image contains /$rel"
	else
		fail "image contains /$rel" 'no such path in the image'
	fi
}

# img_lacks <root> <relpath> — path must NOT exist
img_lacks() {
	local root=$1 rel=$2
	if [[ -e $root/$rel || -L $root/$rel ]]; then
		fail "image does not contain /$rel" 'path is present but should not be'
	else
		pass "image does not contain /$rel"
	fi
}

# img_has_glob <root> <glob> <description> — at least one match
img_has_glob() {
	local root=$1 glob=$2 desc=$3 matches
	# shellcheck disable=SC2086 # deliberate glob expansion
	matches=$(compgen -G "$root/$glob") || matches=''
	if [[ -n $matches ]]; then
		pass "$desc"
	else
		fail "$desc" "no match for /$glob"
	fi
}

# img_symlink <root> <relpath> <expected target>
img_symlink() {
	local root=$1 rel=$2 want=$3 got
	if [[ ! -L $root/$rel ]]; then
		fail "/$rel is a symlink to $want" 'not a symlink (or missing)'
		return 0
	fi
	got=$(readlink "$root/$rel")
	if [[ $got == "$want" ]]; then
		pass "/$rel is a symlink to $want"
	else
		fail "/$rel is a symlink to $want" "points at '$got' instead"
	fi
}

# img_grep <root> <relpath> <extended regex>
img_grep() {
	local root=$1 rel=$2 re=$3
	if [[ ! -f $root/$rel ]]; then
		fail "/$rel matches /$re/" 'file missing from the image'
		return 0
	fi
	if grep -Eq -- "$re" "$root/$rel"; then
		pass "/$rel matches /$re/"
	else
		fail "/$rel matches /$re/" "$(printf 'file contents:\n%s' "$(cat "$root/$rel")")"
	fi
}

# img_same <root> <relpath> <reference file> — byte-identical
img_same() {
	local root=$1 rel=$2 ref=$3
	if [[ ! -f $root/$rel ]]; then
		fail "/$rel matches $ref" 'file missing from the image'
		return 0
	fi
	if cmp -s "$root/$rel" "$ref"; then
		pass "/$rel matches $(basename "$ref")"
	else
		fail "/$rel matches $(basename "$ref")" "$(diff -u "$ref" "$root/$rel" || true)"
	fi
}

# --- environment guards ----------------------------------------------------

need_cmd() {
	local c
	for c; do
		command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
	done
}

need_root() {
	[[ $(id -u) == 0 ]] || die "$(basename "$0") must run as root (try tests/container.sh)"
}

need_pkg() {
	local p
	for p; do
		pacman -Qq "$p" >/dev/null 2>&1 || die "required package not installed: $p"
	done
}

# Path to the busybox mkinitcpio ships; its ash is what runs /init in a
# busybox-based initramfs, so it is the right interpreter to syntax-check
# the runtime hook against.
initcpio_busybox() {
	if [[ -x /usr/lib/initcpio/busybox ]]; then
		printf '/usr/lib/initcpio/busybox\n'
	elif command -v busybox >/dev/null 2>&1; then
		command -v busybox
	else
		return 1
	fi
}

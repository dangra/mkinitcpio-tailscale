#!/usr/bin/env bash
# Static checks.
#
# Everything here is blocking, shellcheck included. Where a finding is a false
# positive the suppression lives at the offending line with a comment saying
# why, rather than being filtered out globally.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"

# libalpm-hook-tailscale is not here: it is libalpm INI, not shell.
SCRIPTS=(initcpio-install-tailscale initcpio-hooks-tailscale setup-initcpio-tailscale
	libalpm-script-tailscale mkinitcpio-tailscale.install)
# The test-only mkinitcpio hooks end up in real images too, so they are held to
# the same standard as the shipped ones.
TEST_SCRIPTS=(tests/*.sh scripts/*.sh tests/initcpio/install/* tests/initcpio/hooks/*)

group 'shellcheck'
command -v shellcheck >/dev/null 2>&1 ||
	die 'shellcheck is required; install the shellcheck package'

# -x follows sourced files, which together with the source-path=SCRIPTDIR
# directive in each test script lets shellcheck see lib.sh and fixtures.sh.
sc_out=$(shellcheck -x "${SCRIPTS[@]}" "${TEST_SCRIPTS[@]}" 2>&1) && sc_rc=0 || sc_rc=$?

# SC2034/SC2154 are structural in a PKGBUILD: makepkg assigns and consumes
# these, so shellcheck cannot see either end of them.
pkg_out=$(shellcheck --shell=bash --exclude=SC2034,SC2154 PKGBUILD 2>&1) && pkg_rc=0 || pkg_rc=$?

if ((sc_rc == 0 && pkg_rc == 0)); then
	pass 'shellcheck reports no findings'
else
	printf '%s\n' "$sc_out" "$pkg_out"
	if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
		{
			printf '### shellcheck\n\n```\n'
			printf '%s\n' "$sc_out" "$pkg_out"
			printf '```\n'
		} >>"$GITHUB_STEP_SUMMARY"
	fi
	fail 'shellcheck reports no findings' 'see the findings above'
fi
endgroup

group 'bash syntax'
for f in "${SCRIPTS[@]}" PKGBUILD "${TEST_SCRIPTS[@]}"; do
	check "$f parses as bash" bash -n "$f"
done
endgroup

group 'busybox ash syntax'
# /usr/lib/initcpio/init runs under busybox ash, so the runtime hook it sources
# has to parse there. Arch builds busybox with bash compatibility, which is why
# the [[ ]] in run_cleanuphook is fine today -- this check is what keeps that
# assumption honest if the busybox build options ever change.
if bb=$(initcpio_busybox); then
	for f in initcpio-hooks-tailscale tests/initcpio/hooks/*; do
		check "$f parses as busybox ash" "$bb" ash -n "$f"
	done
else
	warn 'busybox not found; skipping ash syntax check'
fi
endgroup

group 'hook contracts'
# mkinitcpio sources these files and calls the functions by name; a rename would
# leave a hook that builds cleanly and then does nothing at boot.
check 'install hook defines build()' grep -Eq '^build\(\)' initcpio-install-tailscale
check 'install hook defines help()' grep -Eq '^help\(\)' initcpio-install-tailscale
check 'runtime hook defines run_hook()' grep -Eq '^run_hook\(\)' initcpio-hooks-tailscale
check 'runtime hook defines run_cleanuphook()' grep -Eq '^run_cleanuphook\(\)' initcpio-hooks-tailscale
endgroup

summary

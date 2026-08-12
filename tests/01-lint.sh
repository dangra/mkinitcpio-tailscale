#!/usr/bin/env bash
# Static checks.
#
# Findings from shellcheck are advisory: they are printed (and surfaced in the
# job summary on CI) but never fail the run. Syntax errors are different --
# a script that does not parse is unambiguously broken, so `bash -n` and the
# busybox `ash -n` check are blocking.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"

SCRIPTS=(initcpio-install-tailscale initcpio-hooks-tailscale setup-initcpio-tailscale)
TEST_SCRIPTS=(tests/*.sh)

group 'shellcheck (advisory)'
if command -v shellcheck >/dev/null 2>&1; then
	sc_out=$(shellcheck "${SCRIPTS[@]}" "${TEST_SCRIPTS[@]}" 2>&1) || true
	# SC2034/SC2154 are structural in a PKGBUILD (makepkg assigns and consumes
	# these), so they are excluded rather than reported as noise every run.
	pkgbuild_out=$(shellcheck --shell=bash --exclude=SC2034,SC2154 PKGBUILD 2>&1) || true

	if [[ -n $sc_out || -n $pkgbuild_out ]]; then
		printf '%s\n' "$sc_out" "$pkgbuild_out"
		if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
			{
				printf '### shellcheck (advisory)\n\n```\n'
				printf '%s\n' "$sc_out" "$pkgbuild_out"
				printf '```\n'
			} >>"$GITHUB_STEP_SUMMARY"
		fi
		warn 'shellcheck reported findings (not failing the build)'
	else
		info 'shellcheck is clean'
	fi
else
	warn 'shellcheck not installed; skipping'
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
	check 'initcpio-hooks-tailscale parses as busybox ash' \
		"$bb" ash -n initcpio-hooks-tailscale
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

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

# --- the setup helper's argument scan ---------------------------------------
# The scan decides what reaches `tailscale up`, what default.env records and
# which node --check looks at, and until now only the QEMU stage exercised it
# -- minutes per run, and only along the paths a boot happens to take. The
# helper prints its decisions and stops when asked, so this is a fast unit
# test of the real script rather than a copy of its parser.
group 'setup argument scan'

# scan_is <expectation> -- <args...>
scan_is() {
	local want=$1 got
	shift 2 # drop the -- separator
	got=$(HOSTNAME=testbox "$REPO_ROOT/setup-initcpio-tailscale" \
		--internal-print-args "$@" 2>&1 | tr '\n' ' ')
	got=${got% }
	if [[ $got == "$want" ]]; then
		pass "scan: ${*:-<no arguments>}"
	else
		fail "scan: ${*:-<no arguments>}" "$(printf 'want: %s\ngot:  %s' "$want" "$got")"
	fi
}

# The defaults the helper fills in when told nothing.
scan_is 'hostname=testbox-initrd ssh=yes tun= check=no argv=--hostname=testbox-initrd --ssh --netfilter-mode=off' --
# Tailscale SSH: off by request, and the flag never reaches tailscale up twice.
scan_is 'hostname=testbox-initrd ssh=no tun= check=no argv=--hostname=testbox-initrd --netfilter-mode=off' -- --no-ssh
scan_is 'hostname=testbox-initrd ssh=yes tun= check=no argv=--hostname=testbox-initrd --netfilter-mode=off --ssh' -- --ssh
# The spellings Go's flag parser accepts, which the scan has to read the same way.
scan_is 'hostname=testbox-initrd ssh=no tun= check=no argv=--hostname=testbox-initrd --netfilter-mode=off -ssh=false' -- -ssh=false
scan_is 'hostname=testbox-initrd ssh=yes tun= check=no argv=--hostname=testbox-initrd --netfilter-mode=off --ssh=true' -- --ssh=true
# Hostname in both forms, and the value the rest of the script will use.
scan_is 'hostname=other-initrd ssh=yes tun= check=no argv=--ssh --netfilter-mode=off --hostname=other-initrd' -- --hostname=other-initrd
scan_is 'hostname=other-initrd ssh=yes tun= check=no argv=--ssh --netfilter-mode=off --hostname other-initrd' -- --hostname other-initrd
# The kernel TUN opt-in, defaulted and named.
scan_is 'hostname=testbox-initrd ssh=yes tun=tailscale0 check=no argv=--hostname=testbox-initrd --ssh --netfilter-mode=off' -- --tun
scan_is 'hostname=testbox-initrd ssh=yes tun=ts9 check=no argv=--hostname=testbox-initrd --ssh --netfilter-mode=off' -- --tun=ts9
# --check is deferred to the end of the scan, so a later --hostname reaches it.
scan_is 'hostname=zzz-initrd ssh=yes tun= check=yes argv=--ssh --netfilter-mode=off --hostname=zzz-initrd' -- --check --hostname=zzz-initrd
# An explicit netfilter mode wins over the injected default, and unknown flags
# pass through untouched.
scan_is 'hostname=testbox-initrd ssh=yes tun= check=no argv=--hostname=testbox-initrd --ssh --netfilter-mode=on' -- --netfilter-mode=on
scan_is 'hostname=testbox-initrd ssh=yes tun= check=no argv=--hostname=testbox-initrd --ssh --netfilter-mode=off --advertise-tags=tag:initrd' -- --advertise-tags=tag:initrd

# A bare word that happens to spell one of this script's flags must survive
# as the value of a pass-through flag, not be eaten as ours.
scan_is 'hostname=testbox-initrd ssh=yes tun= check=no argv=--hostname=testbox-initrd --ssh --netfilter-mode=off --exit-node tun' -- --exit-node tun
scan_is 'hostname=testbox-initrd ssh=yes tun= check=no argv=--hostname=testbox-initrd --ssh --netfilter-mode=off --advertise-tags check' -- --advertise-tags check

# Rejections, each of which would otherwise surface much later.
check_fails 'scan: --hostname without a value is refused' \
	env HOSTNAME=testbox "$REPO_ROOT/setup-initcpio-tailscale" --internal-print-args --hostname
check_fails 'scan: --tun= without a name is refused' \
	env HOSTNAME=testbox "$REPO_ROOT/setup-initcpio-tailscale" --internal-print-args --tun=
check_fails 'scan: --internal-install is refused unprivileged' \
	env HOSTNAME=testbox "$REPO_ROOT/setup-initcpio-tailscale" --internal-install /tmp yes ''
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

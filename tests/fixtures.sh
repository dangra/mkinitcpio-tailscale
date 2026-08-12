#!/usr/bin/env bash
# Fixture management for tests that exercise the install hook.
#
# The install hook hardcodes /etc/initcpio/tailscale with no override, so tests
# have to write there for real. On a developer machine that directory holds a
# live Tailscale node key, so `fixtures_init` refuses to run outside a container
# unless ALLOW_UNSAFE=1, and always moves any pre-existing directory aside and
# restores it on exit.
#
# shellcheck shell=bash

TS_SETUPDIR=/etc/initcpio/tailscale
FIXTURE_BACKUP=''
FIXTURE_SRC=''

in_container() {
	[[ -e /run/.containerenv || -e /.dockerenv ]] && return 0
	[[ -n ${GITHUB_ACTIONS:-} && -n ${container:-} ]] && return 0
	local virt
	virt=$(systemd-detect-virt -c 2>/dev/null) && [[ $virt != none ]]
}

fixtures_init() {
	if [[ ${ALLOW_UNSAFE:-0} != 1 ]] && ! in_container; then
		die "refusing to run outside a container: this would clobber $TS_SETUPDIR (your real node key).
       Use tests/container.sh, or set ALLOW_UNSAFE=1 if you really mean it."
	fi
	[[ $(id -u) == 0 ]] || die 'fixtures require root'

	# Stash any real configuration and put it back however we exit.
	if [[ -e $TS_SETUPDIR ]]; then
		FIXTURE_BACKUP=$(mktemp -d)
		mv "$TS_SETUPDIR" "$FIXTURE_BACKUP/tailscale"
		warn "moved existing $TS_SETUPDIR aside; it will be restored on exit"
	fi
	FIXTURE_SRC=$(mktemp -d)
	trap fixtures_cleanup EXIT
}

fixtures_cleanup() {
	local rc=$?
	rm -rf "$TS_SETUPDIR"
	if [[ -n $FIXTURE_BACKUP ]]; then
		mv "$FIXTURE_BACKUP/tailscale" "$TS_SETUPDIR"
		rm -rf "$FIXTURE_BACKUP"
	fi
	[[ -n $FIXTURE_SRC ]] && rm -rf "$FIXTURE_SRC"
	return $rc
}

# fixtures_write [--ssh]
#
# Populates $TS_SETUPDIR the way setup-initcpio-tailscale would, and keeps a
# pristine copy under $FIXTURE_SRC so tests can byte-compare what ended up in
# the image against what went in.
fixtures_write() {
	local with_ssh=0
	[[ ${1:-} == --ssh ]] && with_ssh=1

	rm -rf "$TS_SETUPDIR" "${FIXTURE_SRC:?}"/*
	install -dm700 "$TS_SETUPDIR"

	# Shape mimics a real tailscaled state file; the hook only requires that it
	# be readable and non-empty, but using plausible content keeps failures legible.
	printf '{"_machinekey":"privkey:%064d","_profiles":"[]"}\n' 1 >"$FIXTURE_SRC/tailscaled.state"
	printf 'PORT="41641"\nFLAGS=""\n' >"$FIXTURE_SRC/default.env"
	install -m644 -t "$TS_SETUPDIR" "$FIXTURE_SRC/tailscaled.state" "$FIXTURE_SRC/default.env"

	if ((with_ssh)); then
		# ssh-keygen -A writes into <prefix>/etc/ssh and will not create it.
		install -dm700 "$FIXTURE_SRC/ssh" "$FIXTURE_SRC/etc/ssh"
		ssh-keygen -q -A -f "$FIXTURE_SRC" >/dev/null
		mv "$FIXTURE_SRC"/etc/ssh/ssh_host_* "$FIXTURE_SRC/ssh/"
		rm -rf "${FIXTURE_SRC:?}/etc"
		install -dm700 "$TS_SETUPDIR/ssh"
		install -m600 -t "$TS_SETUPDIR/ssh" "$FIXTURE_SRC/ssh/"ssh_host_*_key
		install -m644 -t "$TS_SETUPDIR/ssh" "$FIXTURE_SRC/ssh/"ssh_host_*_key.pub
	fi
}

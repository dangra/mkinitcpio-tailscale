#!/usr/bin/env bash
# Build real initramfs images with the hook and assert on their contents.
#
# By default the hook files are taken straight from the working tree via
# mkinitcpio's -D flag, so this needs nothing installed and is fast to iterate
# on. Pass --installed to test /usr/lib/initcpio/{install,hooks}/tailscale as
# laid down by the built package instead.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/fixtures.sh"

USE_INSTALLED=0
[[ ${1:-} == --installed ]] && USE_INSTALLED=1

need_root
need_cmd mkinitcpio lsinitcpio depmod ssh-keygen

# The install hook bails out unless the tailscale package is present, and
# add_binary/add_full_dir need the iptables userland -- which tailscale does not
# depend on, so it has to be installed in its own right.
need_pkg tailscale iptables

WORK=$(mktemp -d)
BUILD_N=0

# Simulating "tailscale is not installed" cannot be done with a PATH shim:
# mkinitcpio hard-resets PATH to /usr/bin:/bin at startup (mkinitcpio:39), so
# the hook's `pacman -Qi tailscale` always finds the real binary. Swapping
# /usr/bin/pacman itself is the only thing that works, which is safe here
# because fixtures_init already refuses to run outside a container.
PACMAN_SHIMMED=0

shim_pacman() {
	mv /usr/bin/pacman /usr/bin/pacman.real || die 'could not move pacman aside'
	cat >/usr/bin/pacman <<-'EOF'
		#!/usr/bin/env bash
		[[ $1 == -Qi && $2 == tailscale ]] && exit 1
		exec /usr/bin/pacman.real "$@"
	EOF
	chmod 755 /usr/bin/pacman
	PACMAN_SHIMMED=1
}

unshim_pacman() {
	((PACMAN_SHIMMED)) || return 0
	rm -f /usr/bin/pacman
	mv /usr/bin/pacman.real /usr/bin/pacman
	PACMAN_SHIMMED=0
}

# fixtures_init installs its own EXIT trap; chain ours so both run.
cleanup_all() {
	local rc=$?
	unshim_pacman
	rm -rf "$WORK"
	fixtures_cleanup
	return $rc
}

fixtures_init
trap cleanup_all EXIT

# --- kernel ---------------------------------------------------------------
# The container's `uname -r` is the runner's kernel, for which no module tree
# exists, so take the version from whichever tree a kernel package installed.
KVER=''
for d in /usr/lib/modules/*/; do
	[[ -f ${d}pkgbase ]] && KVER=$(basename "$d")
done
[[ -n $KVER ]] || die 'no kernel module tree found; install the linux package'
[[ -f /usr/lib/modules/$KVER/modules.dep ]] || depmod -a "$KVER" ||
	die "depmod failed for $KVER"
info "building against kernel $KVER"

# --- where mkinitcpio looks for the hook ----------------------------------
MKI_HOOKDIR_ARGS=()
if ((USE_INSTALLED)); then
	[[ -f /usr/lib/initcpio/install/tailscale ]] ||
		die '--installed given but /usr/lib/initcpio/install/tailscale is missing'
	info 'testing the installed hook'
else
	HOOKDIR="$WORK/hookdir"
	install -d "$HOOKDIR/install" "$HOOKDIR/hooks"
	install -m644 "$REPO_ROOT/initcpio-install-tailscale" "$HOOKDIR/install/tailscale"
	install -m644 "$REPO_ROOT/initcpio-hooks-tailscale" "$HOOKDIR/hooks/tailscale"
	# -D replaces the entire search path rather than prepending to it, so the
	# stock directory has to be named explicitly or `base`/`systemd` disappear.
	MKI_HOOKDIR_ARGS=(-D "$HOOKDIR" -D /usr/lib/initcpio)
	info 'testing the hook files from the working tree'
fi

# --- helpers --------------------------------------------------------------

# build_image <hooks> -> sets IMG, LOG, LIST, ROOT; returns mkinitcpio's status
build_image() {
	local hooks=$1 conf
	BUILD_N=$((BUILD_N + 1))
	conf="$WORK/mkinitcpio.$BUILD_N.conf"
	IMG="$WORK/image.$BUILD_N.img"
	LOG="$WORK/build.$BUILD_N.log"
	ROOT="$WORK/root.$BUILD_N"

	# COMPRESSION=cat keeps everything in a single cpio. Compressed images get
	# their *.zst kernel modules moved into a separate early cpio, which
	# duplicates directory entries and makes exact-match assertions ambiguous.
	cat >"$conf" <<-EOF
		MODULES=()
		BINARIES=()
		FILES=()
		HOOKS=($hooks)
		COMPRESSION="cat"
	EOF

	# -n disables colour so the negative tests can grep the log reliably.
	mkinitcpio -n "${MKI_HOOKDIR_ARGS[@]}" -c "$conf" -k "$KVER" -g "$IMG" \
		>"$LOG" 2>&1
}

# snapshot — list and extract the image just built
snapshot() {
	LIST="$WORK/list.$BUILD_N"
	lsinitcpio -l "$IMG" >"$LIST" || die 'lsinitcpio -l failed'
	install -d "$ROOT"
	(cd "$ROOT" && lsinitcpio -x "$IMG" >/dev/null) || die 'lsinitcpio -x failed'
}

in_list() { grep -qxF -- "$1" "$LIST"; }

# Shared expectations for every successful build.
assert_common() {
	local label=$1

	# A runtime hook whose shebang names an interpreter the image does not ship
	# makes mkinitcpio warn on every rebuild the user runs. Cheap to keep quiet,
	# and the warning is exactly the kind of noise that trains people to ignore
	# mkinitcpio's output.
	check_fails "$label: the build logs no missing-interpreter warning" \
		grep -q 'Possibly missing' "$LOG"
	check "$label: tailscaled binary" in_list usr/bin/tailscaled
	check "$label: tailscale binary" in_list usr/bin/tailscale
	check "$label: getent" in_list usr/bin/getent
	check "$label: iptables" in_list usr/bin/iptables
	check "$label: ip6tables" in_list usr/bin/ip6tables
	img_has_glob "$ROOT" 'usr/lib/xtables/lib*.so' "$label: xtables plugins present"
	img_has_glob "$ROOT" "usr/lib/modules/$KVER/kernel/drivers/net/tun.ko*" "$label: tun module present"

	local nf
	nf=$(grep -cE 'kernel/net/netfilter/.*\.ko' "$LIST")
	if ((nf > 20)); then
		pass "$label: netfilter modules present ($nf)"
	else
		fail "$label: netfilter modules present" "only $nf found, expected >20"
	fi

	# The configuration copied off the host must arrive intact at the paths the
	# runtime hook and tailscaled read.
	img_same "$ROOT" etc/default/tailscaled "$FIXTURE_SRC/default.env"
	img_same "$ROOT" var/lib/tailscale/tailscaled.state "$FIXTURE_SRC/tailscaled.state"

	# Both the runtime hook and Arch's tailscaled.service invoke
	# /usr/sbin/tailscaled. mkinitcpio creates usr/sbin as a *relative* symlink
	# to bin, so this resolves inside the extracted image rather than leaking
	# out to the host.
	img_symlink "$ROOT" usr/sbin bin
	check "$label: /usr/sbin/tailscaled resolves in-image" test -x "$ROOT/usr/sbin/tailscaled"
}

# --- variant A: systemd ---------------------------------------------------
group 'variant A: systemd initramfs'
fixtures_write
if build_image 'base systemd tailscale'; then
	pass 'A: mkinitcpio builds'
	snapshot
	assert_common A

	img_has "$ROOT" usr/lib/systemd/system/tailscaled.service
	img_has "$ROOT" etc/systemd/system/tailscaled.service.d/override.conf
	img_grep "$ROOT" etc/systemd/system/tailscaled.service.d/override.conf '^DefaultDependencies=no$'
	img_grep "$ROOT" etc/systemd/system/tailscaled.service.d/override.conf '^After=network-online\.target$'
	img_grep "$ROOT" etc/systemd/system/tailscaled.service.d/override.conf '^Wants=network-online\.target$'
	# An absolute symlink target, so compare the link text -- following it would
	# resolve against the host and pass even with the unit missing.
	img_symlink "$ROOT" etc/systemd/system/sysinit.target.wants/tailscaled.service \
		/usr/lib/systemd/system/tailscaled.service

	img_lacks "$ROOT" hooks/tailscale
	img_lacks "$ROOT" var/lib/tailscale/ssh

	# The hook writes a user database only where nothing else has. mkinitcpio's
	# systemd hook writes a much richer /etc/group than the single root line the
	# busybox branch falls back to, so a surviving 'wheel' is what proves the
	# fallback kept its hands off.
	img_grep "$ROOT" etc/group '^wheel:'
else
	fail 'A: mkinitcpio builds' "$(tail -30 "$LOG")"
fi
endgroup

# --- variant B: busybox ---------------------------------------------------
group 'variant B: busybox initramfs'
fixtures_write
if build_image 'base udev tailscale'; then
	pass 'B: mkinitcpio builds'
	snapshot
	assert_common B

	img_has "$ROOT" hooks/tailscale
	check 'B: runscript is executable' test -x "$ROOT/hooks/tailscale"
	img_grep "$ROOT" hooks/tailscale '^run_hook\(\)'
	img_grep "$ROOT" hooks/tailscale '^run_cleanuphook\(\)'
	# mkinitcpio records which hooks /init should call; a runscript that is
	# present but unregistered would never run.
	img_grep "$ROOT" config '^HOOKS=.*\btailscale\b'
	img_grep "$ROOT" config '^CLEANUPHOOKS=.*\btailscale\b'
	if bb=$(initcpio_busybox); then
		check 'B: runscript parses under busybox ash' "$bb" ash -n "$ROOT/hooks/tailscale"
	fi

	img_lacks "$ROOT" usr/lib/systemd/system/tailscaled.service
	img_lacks "$ROOT" etc/systemd/system/tailscaled.service.d/override.conf

	# No stock busybox-side hook writes a user database, so the hook supplies
	# one: tailscaled resolves the SSH login through it, and so does any dropbear
	# or tinyssh running alongside. The shell has to be one the image actually
	# contains, which is what makes /bin/sh the only sane choice here.
	img_grep "$ROOT" etc/passwd '^root:x:0:0:root:/root:/bin/sh$'
	img_grep "$ROOT" etc/group '^root:x:0:$'
	img_has "$ROOT" etc/shadow
	img_grep "$ROOT" etc/nsswitch.conf '^passwd: files$'
	check 'B: the root shell exists in the image' test -x "$ROOT/bin/sh"
	check 'B: /etc/shadow is not world readable' \
		test "$(stat -c %a "$ROOT/etc/shadow" 2>/dev/null)" = 400
else
	fail 'B: mkinitcpio builds' "$(tail -30 "$LOG")"
fi
endgroup

# --- variant C: systemd with Tailscale SSH host keys ----------------------
group 'variant C: systemd initramfs with ssh host keys'
fixtures_write --ssh
if build_image 'base systemd tailscale'; then
	pass 'C: mkinitcpio builds'
	snapshot
	assert_common C

	img_has "$ROOT" var/lib/tailscale/ssh/ssh_host_ed25519_key
	img_has "$ROOT" var/lib/tailscale/ssh/ssh_host_ed25519_key.pub
	img_has "$ROOT" var/lib/tailscale/ssh/ssh_host_rsa_key
	img_same "$ROOT" var/lib/tailscale/ssh/ssh_host_ed25519_key \
		"$FIXTURE_SRC/ssh/ssh_host_ed25519_key"
	# add_file preserves mode, so a host key must not become world-readable on
	# its way into the image.
	if [[ -f $ROOT/var/lib/tailscale/ssh/ssh_host_ed25519_key ]]; then
		check 'C: private host key stays mode 600' \
			test "$(stat -c %a "$ROOT/var/lib/tailscale/ssh/ssh_host_ed25519_key")" = 600
	fi
else
	fail 'C: mkinitcpio builds' "$(tail -30 "$LOG")"
fi
endgroup

# --- variant D: busybox with Tailscale SSH host keys ----------------------
# The host keys are copied by the part of build() that runs before the init
# system is branched on, so they have to arrive in a busybox image too.
group 'variant D: busybox initramfs with ssh host keys'
fixtures_write --ssh
if build_image 'base udev tailscale'; then
	pass 'D: mkinitcpio builds'
	snapshot
	assert_common D

	img_has "$ROOT" hooks/tailscale
	img_has "$ROOT" var/lib/tailscale/ssh/ssh_host_ed25519_key
	img_has "$ROOT" var/lib/tailscale/ssh/ssh_host_ed25519_key.pub
	img_has "$ROOT" var/lib/tailscale/ssh/ssh_host_rsa_key
	img_same "$ROOT" var/lib/tailscale/ssh/ssh_host_ed25519_key \
		"$FIXTURE_SRC/ssh/ssh_host_ed25519_key"
	if [[ -f $ROOT/var/lib/tailscale/ssh/ssh_host_ed25519_key ]]; then
		check 'D: private host key stays mode 600' \
			test "$(stat -c %a "$ROOT/var/lib/tailscale/ssh/ssh_host_ed25519_key")" = 600
	fi

	# The keys are useless without someone to log in as, so the user database
	# from the busybox branch has to be here too. tests/04-boot.sh proves the
	# combination end to end by opening a session against a real control server.
	img_grep "$ROOT" etc/passwd '^root:x:0:0:root:/root:/bin/sh$'
else
	fail 'D: mkinitcpio builds' "$(tail -30 "$LOG")"
fi

# ... and none of that may depend on this test's minimal HOOKS line. Rechecked
# against the stock default list, minus autodetect and microcode -- both inspect
# the build host, which a container cannot stand in for.
if build_image 'base udev modconf kms keyboard keymap consolefont block filesystems fsck tailscale'; then
	pass 'D: mkinitcpio builds with the stock default hooks'
	snapshot
	img_has "$ROOT" hooks/tailscale
	img_grep "$ROOT" etc/passwd '^root:x:0:0:root:/root:/bin/sh$'
else
	fail 'D: mkinitcpio builds with the stock default hooks' "$(tail -30 "$LOG")"
fi
endgroup

# --- variants E-G: the guard clauses --------------------------------------
#
# mkinitcpio's run_build_hook deliberately discards build()'s return value
# ("Hooks can do their own error catching"), and only failures inside add_*
# functions bump the internal _builderrors counter. A guard clause that just
# calls error() and returns 1 therefore prints a message while mkinitcpio still
# exits 0 and writes an image -- which is why the hook bumps _builderrors
# itself. These tests are what hold that behaviour in place.
group 'variants E-G: guard clauses reject bad configuration'

# assert_guard <label> <error regex> — the build must be refused outright
assert_guard() {
	local label=$1 re=$2 rc=0
	build_image 'base systemd tailscale' || rc=$?

	check "$label: the hook reports the problem" grep -qE "$re" "$LOG"

	if ((rc != 0)); then
		pass "$label: mkinitcpio exits non-zero"
	else
		fail "$label: mkinitcpio exits non-zero" \
			'the hook reported the problem but the build was allowed to succeed'
	fi

	# Nothing half-configured should be left behind either way.
	if [[ -f $IMG ]]; then
		snapshot
		img_lacks "$ROOT" etc/default/tailscaled
		img_lacks "$ROOT" var/lib/tailscale/tailscaled.state
		img_lacks "$ROOT" usr/bin/tailscaled
	else
		pass "$label: no image was written"
	fi
}

fixtures_write
: >"$TS_SETUPDIR/tailscaled.state"
assert_guard 'E: empty tailscaled.state' 'setup-initcpio-tailscale'

fixtures_write
rm -f "$TS_SETUPDIR/default.env"
assert_guard 'F: missing default.env' 'default\.env'

fixtures_write
shim_pacman
assert_guard 'G: tailscale package absent' 'tailscale not installed'
unshim_pacman
endgroup

if ((TESTS_FAILED)) && [[ -n ${ARTIFACT_DIR:-} ]]; then
	install -d "$ARTIFACT_DIR"
	cp "$WORK"/build.*.log "$ARTIFACT_DIR/" 2>/dev/null || true
	info "copied build logs to $ARTIFACT_DIR"
fi

summary

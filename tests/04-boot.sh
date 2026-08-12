#!/usr/bin/env bash
# End-to-end boot test.
#
# Stands up a throwaway headscale control server, runs the real
# setup-initcpio-tailscale against it to produce a genuine node key, builds an
# initramfs with the hook, boots it under QEMU, and then asserts from
# headscale's side that the initrd node registered and came online.
#
# That chain is the only thing that proves what the package actually claims:
# state copied into the image -> tailscaled started inside the initramfs ->
# network up -> node reachable on the tailnet. It also gives
# setup-initcpio-tailscale its only coverage, via the non-interactive
# --authkey path.
#
# This is the most environment-sensitive script in the suite; every external
# moving part is parameterised below.
#
#   --installed   test /usr/lib/initcpio/... and /usr/bin/setup-initcpio-tailscale
#                 from the built package instead of the working tree
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/fixtures.sh"

# Pinned headscale release, with the sha256 of its linux_amd64 asset taken from
# the checksums.txt published alongside it. Bumping the version means updating
# the hash; overriding HEADSCALE_VERSION without also passing HEADSCALE_SHA256
# skips verification and warns.
HEADSCALE_PINNED_VERSION=0.26.1
HEADSCALE_PINNED_SHA256=5012577e6fc5d4234aab7b4be0d6e271ea1a4ec38521a8aa472f80ea1fe81cba
HEADSCALE_VERSION=${HEADSCALE_VERSION:-$HEADSCALE_PINNED_VERSION}
if [[ -z ${HEADSCALE_SHA256:-} && $HEADSCALE_VERSION == "$HEADSCALE_PINNED_VERSION" ]]; then
	HEADSCALE_SHA256=$HEADSCALE_PINNED_SHA256
fi

BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}
TS_NODE_NAME=${TS_NODE_NAME:-ci-initrd}

USE_INSTALLED=0
[[ ${1:-} == --installed ]] && USE_INSTALLED=1

need_root
need_cmd mkinitcpio qemu-system-x86_64 curl jq depmod ssh-keygen
need_pkg tailscale iptables

WORK=$(mktemp -d)
QEMU_PID=''
HEADSCALE_PID=''

cleanup_all() {
	local rc=$?
	[[ -n $QEMU_PID ]] && kill "$QEMU_PID" 2>/dev/null
	[[ -n $HEADSCALE_PID ]] && kill "$HEADSCALE_PID" 2>/dev/null
	if [[ -n ${ARTIFACT_DIR:-} ]]; then
		install -d "$ARTIFACT_DIR"
		cp "$WORK/console.log" "$WORK/console.txt" "$WORK/headscale.log" "$WORK/mkinitcpio.log" \
			"$WORK/setup.log" "$ARTIFACT_DIR/" 2>/dev/null || true
	fi
	rm -rf "$WORK"
	fixtures_cleanup
	return $rc
}

fixtures_init
trap cleanup_all EXIT

# --- what is under test ---------------------------------------------------
if ((USE_INSTALLED)); then
	[[ -f /usr/lib/initcpio/install/tailscale ]] ||
		die '--installed given but the package is not installed'
	SETUP_HELPER=/usr/bin/setup-initcpio-tailscale
	HOOKDIR="$REPO_ROOT/tests/initcpio"
	info 'testing the installed package'
else
	HOOKDIR="$WORK/hookdir"
	install -d "$HOOKDIR/install" "$HOOKDIR/hooks"
	install -m644 "$REPO_ROOT/initcpio-install-tailscale" "$HOOKDIR/install/tailscale"
	install -m644 "$REPO_ROOT/initcpio-hooks-tailscale" "$HOOKDIR/hooks/tailscale"
	install -m644 "$REPO_ROOT/tests/initcpio/install/testnet" "$HOOKDIR/install/testnet"
	SETUP_HELPER="$REPO_ROOT/setup-initcpio-tailscale"
	info 'testing the working tree'
fi
[[ -x $SETUP_HELPER ]] || die "setup helper not executable: $SETUP_HELPER"

# --- kernel ---------------------------------------------------------------
KVER=''
for d in /usr/lib/modules/*/; do
	[[ -f ${d}pkgbase ]] && KVER=$(basename "$d")
done
[[ -n $KVER ]] || die 'no kernel module tree found; install the linux package'
KERNEL="/usr/lib/modules/$KVER/vmlinuz"
[[ -f $KERNEL ]] || die "kernel image not found at $KERNEL"
[[ -f /usr/lib/modules/$KVER/modules.dep ]] || depmod -a "$KVER"

# --- control server -------------------------------------------------------
# The guest reaches the container through QEMU's user-mode NAT, so the control
# server has to be advertised on an address valid from both sides. The
# container's own routable address satisfies that; 127.0.0.1 would not.
HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
[[ -n $HOST_IP ]] || die 'could not determine the container IP address'
SERVER_URL="http://${HOST_IP}:8080"
info "control server will be advertised at $SERVER_URL"

group 'start headscale'
HEADSCALE=${HEADSCALE_BIN:-$WORK/headscale}
if [[ ! -x $HEADSCALE ]]; then
	url="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"
	info "downloading headscale $HEADSCALE_VERSION"
	curl -fsSL -o "$HEADSCALE" "$url" || die "failed to download $url"

	if [[ -n ${HEADSCALE_SHA256:-} ]]; then
		got=$(sha256sum "$HEADSCALE" | cut -d' ' -f1)
		[[ $got == "$HEADSCALE_SHA256" ]] ||
			die "headscale checksum mismatch
       expected $HEADSCALE_SHA256
       got      $got"
		pass 'the headscale download matches its pinned checksum'
	else
		warn "no checksum pinned for headscale $HEADSCALE_VERSION; skipping verification"
	fi

	chmod 755 "$HEADSCALE"
fi

CFG="$WORK/headscale.yaml"
cat >"$CFG" <<-EOF
	server_url: ${SERVER_URL}
	listen_addr: 0.0.0.0:8080
	metrics_listen_addr: 127.0.0.1:9090
	grpc_listen_addr: 127.0.0.1:50443
	grpc_allow_insecure: false
	noise:
	  private_key_path: ${WORK}/noise_private.key
	prefixes:
	  v4: 100.64.0.0/10
	  v6: fd7a:115c:a1e0::/48
	database:
	  type: sqlite
	  sqlite:
	    path: ${WORK}/db.sqlite
	# headscale refuses to start with an empty DERP map, so run its embedded
	# relay rather than pointing at Tailscale's public one -- that keeps the
	# test self-contained and off the internet.
	derp:
	  server:
	    enabled: true
	    region_id: 999
	    region_code: ci
	    region_name: CI
	    stun_listen_addr: 0.0.0.0:3478
	    private_key_path: ${WORK}/derp_server_private.key
	    automatically_add_embedded_derp_region: true
	  urls: []
	  auto_update_enabled: false
	  update_frequency: 24h
	dns:
	  magic_dns: false
	  override_local_dns: false
	  base_domain: ci.test
	  nameservers:
	    global: []
	log:
	  level: info
	policy:
	  mode: database
EOF

"$HEADSCALE" -c "$CFG" serve >"$WORK/headscale.log" 2>&1 &
HEADSCALE_PID=$!

for _ in $(seq 30); do
	curl -fsS -o /dev/null "${SERVER_URL}/health" 2>/dev/null && break
	kill -0 "$HEADSCALE_PID" 2>/dev/null || break
	sleep 1
done
if curl -fsS -o /dev/null "${SERVER_URL}/health" 2>/dev/null; then
	pass 'headscale is serving'
else
	fail 'headscale is serving' "$(tail -30 "$WORK/headscale.log")"
	summary
	exit 1
fi

hs() { "$HEADSCALE" -c "$CFG" "$@"; }

hs users create ci >"$WORK/user.log" 2>&1 ||
	die "headscale users create failed: $(cat "$WORK/user.log")"
USER_ID=$(hs users list -o json 2>/dev/null | jq -r '.[] | select(.name=="ci") | .id')
[[ -n $USER_ID ]] || die 'could not resolve the headscale user id'

# The --user flag switched from name to id across headscale releases; try the
# id first and fall back so a version bump does not silently break the test.
AUTHKEY=$(hs preauthkeys create --user "$USER_ID" --reusable --expiration 24h 2>/dev/null | tail -1)
if [[ -z $AUTHKEY || $AUTHKEY == *rror* ]]; then
	AUTHKEY=$(hs preauthkeys create --user ci --reusable --expiration 24h 2>/dev/null | tail -1)
fi
[[ -n $AUTHKEY ]] || die 'could not create a headscale pre-auth key'
pass 'headscale issued a pre-auth key'
endgroup

# --- the real setup helper ------------------------------------------------
group 'setup-initcpio-tailscale against headscale'
if "$SETUP_HELPER" \
	--hostname="$TS_NODE_NAME" \
	--login-server="$SERVER_URL" \
	--authkey="$AUTHKEY" >"$WORK/setup.log" 2>&1; then
	pass 'setup-initcpio-tailscale registers a node'
else
	fail 'setup-initcpio-tailscale registers a node' "$(cat "$WORK/setup.log")"
	summary
	exit 1
fi

check 'setup wrote tailscaled.state' test -s "$TS_SETUPDIR/tailscaled.state"
check 'setup wrote default.env' test -s "$TS_SETUPDIR/default.env"

node_known() {
	hs nodes list -o json 2>/dev/null |
		jq -e --arg n "$TS_NODE_NAME" '.[] | select(.given_name==$n)' >/dev/null
}
check 'the node is registered with headscale' node_known
endgroup

# --- build the image ------------------------------------------------------
group 'build the boot image'
# Kept in $WORK and handed to the hook via TESTNET_CONFIG rather than written
# to /etc/systemd/network: with ALLOW_UNSAFE=1 this script can be run on a real
# host, where leaving a DHCP .network file behind would persistently affect
# systemd-networkd.
TESTNET_CONFIG="$WORK/10-ci.network"
export TESTNET_CONFIG
cat >"$TESTNET_CONFIG" <<-'EOF'
	[Match]
	Name=en* eth*

	[Network]
	DHCP=yes
EOF

CONF="$WORK/mkinitcpio.conf"
cat >"$CONF" <<-'EOF'
	# tun is needed by tailscaled and the virtio drivers by the QEMU NIC.
	# Listing them in MODULES both includes and autoloads them.
	MODULES=(tun virtio_net virtio_pci)
	BINARIES=()
	FILES=()
	HOOKS=(base systemd testnet tailscale)
	COMPRESSION="cat"
EOF

IMG="$WORK/ci-initrd.img"
# -D replaces the whole search path, so the stock directory must be named too.
if mkinitcpio -n -D "$HOOKDIR" -D /usr/lib/initcpio \
	-c "$CONF" -k "$KVER" -g "$IMG" >"$WORK/mkinitcpio.log" 2>&1; then
	pass 'mkinitcpio builds the boot image'
else
	fail 'mkinitcpio builds the boot image' "$(tail -40 "$WORK/mkinitcpio.log")"
	summary
	exit 1
fi
endgroup

# --- boot -----------------------------------------------------------------
group 'boot under QEMU'

node_online() {
	hs nodes list -o json 2>/dev/null |
		jq -e --arg n "$TS_NODE_NAME" '.[] | select(.given_name==$n) | select(.online==true)' \
			>/dev/null
}

# setup-initcpio-tailscale ran a tailscaled of its own to register the node, and
# headscale takes a moment to notice that session ending. Waiting for the node
# to read as offline first is what makes the assertion below meaningful: once
# it has, coming back online can only be the VM.
info 'waiting for the setup-time session to drop'
for _ in $(seq 24); do
	node_online || break
	sleep 5
done
if node_online; then
	fail 'the node is offline before boot' \
		'it still reads online, so the boot assertion would be vacuous'
else
	pass 'the node is offline before boot'
fi

ACCEL=tcg
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
	ACCEL=kvm
else
	warn 'no usable /dev/kvm; falling back to TCG emulation (slower)'
fi
info "booting with accel=$ACCEL"

# No usable root device is provided on purpose. systemd still reaches
# sysinit.target -- which is what pulls in tailscaled.service and networkd --
# and then waits for a root filesystem that never appears, holding the VM up
# long enough to observe the node from the control server.
qemu-system-x86_64 \
	-accel "$ACCEL" \
	-m 1G -smp 2 \
	-display none -no-reboot \
	-kernel "$KERNEL" \
	-initrd "$IMG" \
	-append "console=ttyS0 root=/dev/disk/by-uuid/deadbeef-0000-0000-0000-000000000000 rw systemd.log_level=info" \
	-netdev user,id=n0 \
	-device virtio-net-pci,netdev=n0 \
	-serial "file:$WORK/console.log" \
	>"$WORK/qemu.log" 2>&1 &
QEMU_PID=$!

started=$SECONDS
deadline=$((SECONDS + BOOT_TIMEOUT))
online=0
while ((SECONDS < deadline)); do
	if node_online; then
		online=1
		break
	fi
	if ! kill -0 "$QEMU_PID" 2>/dev/null; then
		warn 'QEMU exited before the node came online'
		break
	fi
	sleep 5
done

if ((online)); then
	pass "the initrd node came online after $((SECONDS - started))s"
else
	fail 'the initrd node came online' \
		"$(printf 'last 40 lines of console:\n%s' "$(tail -40 "$WORK/console.log" 2>/dev/null)")"
fi

# Corroborating evidence from inside the guest, useful when the assertion above
# fails and the question is how far the boot actually got. systemd colours its
# console output, and the escape sequences land between "Started" and the unit
# description, so they have to come out before matching.
sed -r 's/\x1B\[[0-9;?]*[a-zA-Z]//g; s/\x1B\][^\x07]*(\x07|\x1B\\)//g' \
	"$WORK/console.log" >"$WORK/console.txt" 2>/dev/null

if grep -qE 'Started Tailscale node agent|tailscaled' "$WORK/console.txt"; then
	pass 'the guest started the tailscaled unit'
else
	fail 'the guest started the tailscaled unit' \
		"$(printf 'console.log is %s bytes; last 40 lines (de-escaped):\n%s' \
			"$(stat -c %s "$WORK/console.log" 2>/dev/null || echo missing)" \
			"$(tail -40 "$WORK/console.txt" 2>/dev/null)")"
fi
endgroup

summary

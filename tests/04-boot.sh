#!/usr/bin/env bash
# End-to-end boot test.
#
# Stands up a throwaway headscale control server, runs the real
# setup-initcpio-tailscale against it to produce genuine node keys and Tailscale
# SSH host keys, builds an initramfs with the hook, boots it under QEMU, and
# then asserts from outside the guest that the initrd node registered, came
# online, and answers an SSH session whose host key is the one setup generated.
#
# That chain is the only thing that proves what the package actually claims:
# state copied into the image -> tailscaled started inside the initramfs ->
# network up -> node reachable on the tailnet -> reachable *as the same host*
# a client already knows. It also gives setup-initcpio-tailscale its only
# coverage, via the non-interactive --authkey path.
#
# One boot per branch of the install hook, since the two produce genuinely
# different images and the runtime hook only runs in the second -- plus one for
# the --no-ssh path:
#
#   systemd    HOOKS=(base systemd ... tailscale)   tailscaled.service
#   busybox    HOOKS=(base udev ... tailscale)      initcpio-hooks-tailscale
#   dropbear   busybox again, registered --no-ssh, with a dropbear standing in
#              for the user's own early ssh daemon
#   kerneltun  busybox again, registered --tun: the kernel TUN opt-in, which
#              must put the tun module back in the image and still serve a
#              Tailscale SSH session over the tailscale0 device
#
# The first two register with Tailscale SSH, which is what the setup helper
# does when left alone. The dropbear scenario is what proves the --no-ssh
# promise: tailscaled runs on userspace networking, so inbound tailnet TCP
# only reaches another daemon through its loopback proxy, and that path is
# worthless untested. The images also carry test-only hooks from
# tests/initcpio -- testnet for an address on QEMU's user-mode network,
# testuser for the login the ssh assertions use, testdropbear for the daemon.
#
# This is the most environment-sensitive script in the suite; every external
# moving part is parameterised below.
#
#   --installed         test /usr/lib/initcpio/... and /usr/bin/setup-initcpio-tailscale
#                       from the built package instead of the working tree
#   systemd | busybox | dropbear | kerneltun
#                       boot only the named scenarios (or set BOOT_SCENARIOS)
# shellcheck source-path=SCRIPTDIR
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
# tailscaled reads as online before its SSH listener is necessarily up, so the
# first ssh attempt is retried rather than asserted on the spot.
SSH_TIMEOUT=${SSH_TIMEOUT:-90}
TS_NODE_NAME=${TS_NODE_NAME:-ci-initrd}
# The login the session is opened as. Not root, and not a free choice: see
# tests/initcpio/install/testuser, which adds it to the image and explains why
# headscale cannot authorise a root session. Keep the two in step.
SSH_USER=${SSH_USER:-citest}

# --- scenarios ------------------------------------------------------------
# The bogus root UUID doubles as the marker that proves an ssh session landed
# in the guest this scenario booted, so it differs per scenario.
# testuser comes after tailscale: it appends to whatever user database the image
# already has, and on the busybox side that database is written by the tailscale
# hook itself.
declare -A SC_HOOKS=(
	[systemd]='base systemd testnet tailscale testuser'
	[busybox]='base udev testnet tailscale testuser'
	[dropbear]='base udev testnet tailscale testuser testdropbear'
	[kerneltun]='base udev testnet tailscale testuser'
)
declare -A SC_SUFFIX=([systemd]=sd [busybox]=bb [dropbear]=db [kerneltun]=kt)
declare -A SC_ROOT=(
	[systemd]=deadbeef-0000-0000-0000-000000000001
	[busybox]=deadbeef-0000-0000-0000-000000000002
	[dropbear]=deadbeef-0000-0000-0000-000000000003
	[kerneltun]=deadbeef-0000-0000-0000-000000000004
)
# Extra setup-helper arguments per scenario: the dropbear one registers the
# way a user bringing their own ssh daemon would.
declare -A SC_SETUP_ARGS=(
	[systemd]=''
	[busybox]=''
	[dropbear]='--no-ssh'
	[kerneltun]='--tun'
)
# Evidence from inside the guest that the hook ran, per branch: the unit on one
# side, the runtime hook's own first line on the other.
declare -A SC_CONSOLE=(
	[systemd]='Started Tailscale node agent|tailscaled'
	[busybox]='Starting Tailscale'
	[dropbear]='Starting Tailscale'
	[kerneltun]='Starting Tailscale'
)

# mkinitcpio's init drops into an interactive rescue shell once it gives up on
# the root device. With -serial file: that shell reads EOF, exits as PID 1 and
# panics the guest, so the busybox scenario parks in poll_device instead --
# rootdelay outlives the test, which is the busybox analogue of systemd waiting
# forever on a device that never appears.
declare -A SC_APPEND=(
	[systemd]=''
	[busybox]="rootdelay=$((BOOT_TIMEOUT + 120))"
	[dropbear]="rootdelay=$((BOOT_TIMEOUT + 120))"
	[kerneltun]="rootdelay=$((BOOT_TIMEOUT + 120))"
)

USE_INSTALLED=0
SCENARIOS=()
for arg in "$@"; do
	case $arg in
	--installed) USE_INSTALLED=1 ;;
	systemd | busybox | dropbear | kerneltun) SCENARIOS+=("$arg") ;;
	*) die "unknown argument: $arg (expected --installed, systemd, busybox, dropbear or kerneltun)" ;;
	esac
done
if ((${#SCENARIOS[@]} == 0)); then
	# shellcheck disable=SC2206 # a space separated override is the point
	SCENARIOS=(${BOOT_SCENARIOS:-systemd busybox dropbear kerneltun})
fi

has_scenario() {
	local s
	for s in "${SCENARIOS[@]}"; do [[ $s == "$1" ]] && return 0; done
	return 1
}

need_root
need_cmd mkinitcpio qemu-system-x86_64 curl jq depmod ssh ssh-keygen
has_scenario dropbear && need_cmd dropbearkey
need_pkg tailscale

WORK=$(mktemp -d)
QEMU_PID=''
HEADSCALE_PID=''
CLIENT_PID=''
CLIENT_SOCK="$WORK/client.sock"
CLIENT_NAME=${CLIENT_NAME:-ci-client}

cleanup_all() {
	local rc=$?
	[[ -n $QEMU_PID ]] && kill "$QEMU_PID" 2>/dev/null
	[[ -n $CLIENT_PID ]] && kill "$CLIENT_PID" 2>/dev/null
	[[ -n $HEADSCALE_PID ]] && kill "$HEADSCALE_PID" 2>/dev/null
	if [[ -n ${ARTIFACT_DIR:-} ]]; then
		install -d "$ARTIFACT_DIR"
		cp "$WORK"/*.log "$WORK"/*.txt "$ARTIFACT_DIR/" 2>/dev/null || true
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
	install -m644 "$REPO_ROOT/tests/initcpio/install/testuser" "$HOOKDIR/install/testuser"
	install -m644 "$REPO_ROOT/tests/initcpio/install/testdropbear" "$HOOKDIR/install/testdropbear"
	install -m644 "$REPO_ROOT/tests/initcpio/hooks/testnet" "$HOOKDIR/hooks/testnet"
	install -m644 "$REPO_ROOT/tests/initcpio/hooks/testdropbear" "$HOOKDIR/hooks/testdropbear"
	SETUP_HELPER="$REPO_ROOT/setup-initcpio-tailscale"
	info 'testing the working tree'
fi
[[ -x $SETUP_HELPER ]] || die "setup helper not executable: $SETUP_HELPER"
info "scenarios: ${SCENARIOS[*]}"

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
	# The one thing in this test that depends on somebody else's uptime, and a
	# single 503 from the release CDN has already failed a run on master.
	# --retry alone covers the 5xx and timeout cases; --retry-all-errors extends
	# it to a connection dropped mid-transfer, which is the other way a CDN
	# fails. The download is checksummed below either way.
	curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
		-o "$HEADSCALE" "$url" || die "failed to download $url"

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

# Tailscale SSH is authorised by policy, not by keys, so without an ssh rule the
# node would refuse every session no matter how healthy it is. Everything here
# belongs to the single user 'ci', hence the user@ form on both sides; the login
# the rule grants is the unprivileged one tests/initcpio/install/testuser adds,
# which is also where the reason it cannot be root is written down.
cat >"$WORK/policy.json" <<-EOF
	{
	  "acls": [
	    { "action": "accept", "src": ["ci@"], "dst": ["*:*"] }
	  ],
	  "ssh": [
	    {
	      "action": "accept",
	      "src": ["ci@"],
	      "dst": ["ci@"],
	      "users": ["${SSH_USER}"]
	    }
	  ]
	}
EOF
if hs policy set -f "$WORK/policy.json" >"$WORK/policy.log" 2>&1; then
	pass 'headscale accepted the ssh policy'
else
	fail 'headscale accepted the ssh policy' "$(cat "$WORK/policy.log")"
fi
endgroup

node_known() {
	hs nodes list -o json 2>/dev/null |
		jq -e --arg n "$1" '.[] | select(.given_name==$n)' >/dev/null
}

node_online() {
	hs nodes list -o json 2>/dev/null |
		jq -e --arg n "$1" '.[] | select(.given_name==$n) | select(.online==true)' >/dev/null
}

node_ip() {
	hs nodes list -o json 2>/dev/null |
		jq -r --arg n "$1" '.[] | select(.given_name==$n) | .ip_addresses[]' 2>/dev/null |
		grep -m1 -E '^100\.'
}

# --- the real setup helper ------------------------------------------------
# Every scenario is registered before any image is built, so the setup-time
# sessions of the later scenarios expire while the first one boots rather than
# stalling each boot in turn.
group 'setup-initcpio-tailscale against headscale'
for sc in "${SCENARIOS[@]}"; do
	node="${TS_NODE_NAME}-${SC_SUFFIX[$sc]}"

	# Tailscale SSH is the default and most scenarios rely on it, so the host
	# key assertions below are what prove the default took effect; the dropbear
	# scenario registers --no-ssh instead, via SC_SETUP_ARGS.
	rm -rf "$TS_SETUPDIR"
	# shellcheck disable=SC2086 # SC_SETUP_ARGS is meant to word-split
	if "$SETUP_HELPER" \
		--hostname="$node" \
		--login-server="$SERVER_URL" \
		--authkey="$AUTHKEY" ${SC_SETUP_ARGS[$sc]} >"$WORK/setup.$sc.log" 2>&1; then
		pass "$sc: setup-initcpio-tailscale registers $node"
	else
		fail "$sc: setup-initcpio-tailscale registers $node" "$(cat "$WORK/setup.$sc.log")"
		summary
		exit 1
	fi

	check "$sc: setup wrote tailscaled.state" test -s "$TS_SETUPDIR/tailscaled.state"
	check "$sc: setup wrote default.env" test -s "$TS_SETUPDIR/default.env"
	if [[ ${SC_SETUP_ARGS[$sc]} == *--no-ssh* ]]; then
		check_fails "$sc: --no-ssh left no host keys" test -e "$TS_SETUPDIR/ssh"
	else
		check "$sc: setup wrote an ed25519 host key" \
			test -s "$TS_SETUPDIR/ssh/ssh_host_ed25519_key"
		check "$sc: the private host key is mode 600" \
			test "$(stat -c %a "$TS_SETUPDIR/ssh/ssh_host_ed25519_key" 2>/dev/null)" = 600
		# What the ssh assertions later compare the offered host key against.
		cp "$TS_SETUPDIR/ssh/ssh_host_ed25519_key.pub" "$WORK/hostkey.$sc.pub"
	fi
	if [[ ${SC_SETUP_ARGS[$sc]} == *--tun* ]]; then
		check "$sc: default.env carries TUN=tailscale0" \
			grep -qx 'TUN="tailscale0"' "$TS_SETUPDIR/default.env"
	fi
	check "$sc: the node is registered with headscale" node_known "$node"

	# Keep this scenario's configuration; $TS_SETUPDIR is shared, so it is put
	# back immediately before the image that needs it is built.
	cp -a "$TS_SETUPDIR" "$WORK/state.$sc"
done
endgroup

# --- the opt-out ----------------------------------------------------------
# Deliberately run over a directory that holds host keys: --no-ssh has to
# clear them, or every image built afterwards would still carry keys for an
# ssh server this node no longer runs. The loop above cannot be relied on for
# that state -- its last scenario may itself be a --no-ssh one -- so restore a
# Tailscale SSH scenario's state, or fabricate a stale key if none was run.
group 'setup-initcpio-tailscale --no-ssh'
restored=''
for sc in "${SCENARIOS[@]}"; do
	if [[ -d $WORK/state.$sc/ssh ]]; then
		rm -rf "$TS_SETUPDIR"
		cp -a "$WORK/state.$sc" "$TS_SETUPDIR"
		restored=$sc
		break
	fi
done
if [[ -z $restored ]]; then
	install -dm700 "$TS_SETUPDIR/ssh"
	printf 'stale\n' >"$TS_SETUPDIR/ssh/ssh_host_ed25519_key"
fi
check 'host keys are in place before the re-run' test -d "$TS_SETUPDIR/ssh"
# A re-run must keep the user's default.env tuning; the marker proves the file
# survived rather than being rewritten with identical content.
echo '# user tuning marker' >>"$TS_SETUPDIR/default.env"
if "$SETUP_HELPER" \
	--hostname="${TS_NODE_NAME}-nossh" \
	--login-server="$SERVER_URL" \
	--authkey="$AUTHKEY" \
	--no-ssh >"$WORK/setup.nossh.log" 2>&1; then
	pass '--no-ssh registers the node'
else
	fail '--no-ssh registers the node' "$(cat "$WORK/setup.nossh.log")"
fi
check '--no-ssh still wrote tailscaled.state' test -s "$TS_SETUPDIR/tailscaled.state"
check 'a re-run keeps an edited default.env' \
	grep -q 'user tuning marker' "$TS_SETUPDIR/default.env"
check_fails '--no-ssh leaves no host keys behind' test -e "$TS_SETUPDIR/ssh"
# 'tailscale up' has no --no-ssh flag, so a pass-through would have failed the
# registration above with "flag provided but not defined".
check_fails '--no-ssh never reached tailscale up' \
	grep -q 'not defined' "$WORK/setup.nossh.log"

# An explicit --tun must update the default.env the run above kept, replacing
# its TUN= line while leaving the user's own edits alone.
if "$SETUP_HELPER" \
	--hostname="${TS_NODE_NAME}-nossh" \
	--login-server="$SERVER_URL" \
	--authkey="$AUTHKEY" \
	--no-ssh --tun >"$WORK/setup.tun.log" 2>&1; then
	pass '--tun re-registers the node'
else
	fail '--tun re-registers the node' "$(cat "$WORK/setup.tun.log")"
fi
check '--tun landed in the kept default.env' \
	grep -qx 'TUN="tailscale0"' "$TS_SETUPDIR/default.env"
check 'the user tuning survived alongside it' \
	grep -q 'user tuning marker' "$TS_SETUPDIR/default.env"
check_fails '--tun never reached tailscale up' \
	grep -q 'not defined' "$WORK/setup.tun.log"
endgroup

# --- a client on the tailnet ----------------------------------------------
# Userspace networking keeps this working in an unprivileged container: no
# /dev/net/tun, no NET_ADMIN, and reachability comes from `tailscale nc` used as
# an ssh ProxyCommand. Same shape setup-initcpio-tailscale itself uses.
group 'join a client to the tailnet'
tailscaled \
	-state="$WORK/client.state" \
	-socket="$CLIENT_SOCK" \
	-no-logs-no-support \
	-tun=userspace-networking \
	>"$WORK/client.log" 2>&1 &
CLIENT_PID=$!

for _ in $(seq 30); do
	[[ -S $CLIENT_SOCK ]] && break
	kill -0 "$CLIENT_PID" 2>/dev/null || break
	sleep 1
done

# --accept-risk=lose-ssh for the same reason the setup helper passes it: this is
# an isolated daemon with its own socket and state, so it cannot disturb the
# session the suite may be running under.
if tailscale --socket="$CLIENT_SOCK" up \
	--login-server="$SERVER_URL" \
	--authkey="$AUTHKEY" \
	--hostname="$CLIENT_NAME" \
	--accept-risk=lose-ssh >"$WORK/client-up.log" 2>&1; then
	pass 'the ssh client node joined the tailnet'
else
	fail 'the ssh client node joined the tailnet' \
		"$(printf '%s\n%s' "$(cat "$WORK/client-up.log")" "$(tail -20 "$WORK/client.log")")"
fi
endgroup

# --- assertions that need a booted guest ----------------------------------
#
# Set by run_scenario before the ssh assertions run, because `check` takes a
# command rather than a closure.
SSH_SC=''
SSH_IP=''
SSH_KNOWN=''
SSH_MARKER=''
SSH_LOGIN=''
SSH_OPTS=()

# The guest answers ssh, and it is the guest this scenario booted: /proc/cmdline
# carries the bogus root= UUID handed to this QEMU invocation and no other.
ssh_runs_a_command() {
	local deadline=$((SECONDS + SSH_TIMEOUT)) out rc
	while :; do
		out=$(ssh "${SSH_OPTS[@]}" "$SSH_LOGIN@$SSH_IP" cat /proc/cmdline 2>&1)
		rc=$?
		((rc == 0)) && break
		if ((SECONDS >= deadline)); then
			printf '%s\n' "$out"
			return "$rc"
		fi
		sleep 5
	done
	printf '%s\n' "$out"
	[[ $out == *"$SSH_MARKER"* ]]
}

# The whole point of controlling the host key that goes into the image: the
# initrd node is not a stranger to a client that already knows the machine.
# The expected key comes from $WORK/hostkey.<scenario>.pub -- written by the
# registration loop for Tailscale SSH scenarios, and by the dropbear key
# generation for the --no-ssh one. OpenSSH records the offered key during the
# handshake, before authentication, so this stays meaningful even when the
# session itself is refused.
hostkey_is_the_expected_one() {
	local want got
	want=$(ssh-keygen -lf "$WORK/hostkey.$SSH_SC.pub" 2>/dev/null |
		awk '{print $2}')
	got=$(ssh-keygen -lf "$SSH_KNOWN" 2>/dev/null |
		awk '$NF == "(ED25519)" {print $2; exit}')
	printf 'expected %s\nguest offered %s\n' "$want" "${got:-<nothing recorded>}"
	[[ -n $want && $got == "$want" ]]
}

run_scenario() {
	local sc=$1
	local node="${TS_NODE_NAME}-${SC_SUFFIX[$sc]}"
	local img="$WORK/initrd.$sc.img" conf="$WORK/mkinitcpio.$sc.conf"
	local console="$WORK/console.$sc.log" text="$WORK/console.$sc.txt"
	local root="/dev/disk/by-uuid/${SC_ROOT[$sc]}"

	group "build the $sc boot image"
	rm -rf "$TS_SETUPDIR"
	cp -a "$WORK/state.$sc" "$TS_SETUPDIR"

	cat >"$conf" <<-EOF
		# The virtio drivers are for the QEMU NIC; listing them in MODULES both
		# includes and autoloads them. No tun: tailscaled runs with userspace
		# networking, and its absence here is what proves that path needs no
		# kernel module.
		MODULES=(virtio_net virtio_pci)
		BINARIES=()
		FILES=()
		HOOKS=(${SC_HOOKS[$sc]})
		COMPRESSION="cat"
	EOF

	# -D replaces the whole search path, so the stock directory must be named too.
	if mkinitcpio -n -D "$HOOKDIR" -D /usr/lib/initcpio \
		-c "$conf" -k "$KVER" -g "$img" >"$WORK/mkinitcpio.$sc.log" 2>&1; then
		pass "$sc: mkinitcpio builds the boot image"
	else
		fail "$sc: mkinitcpio builds the boot image" "$(tail -40 "$WORK/mkinitcpio.$sc.log")"
		endgroup
		return 1
	fi
	endgroup

	group "boot $sc under QEMU"

	# setup-initcpio-tailscale ran a tailscaled of its own to register the node,
	# and headscale takes a moment to notice that session ending. Waiting for the
	# node to read as offline first is what makes the assertion below meaningful:
	# once it has, coming back online can only be the VM.
	info "waiting for the setup-time session of $node to drop"
	for _ in $(seq 24); do
		node_online "$node" || break
		sleep 5
	done
	if node_online "$node"; then
		fail "$sc: the node is offline before boot" \
			'it still reads online, so the boot assertion would be vacuous'
	else
		pass "$sc: the node is offline before boot"
	fi

	info "booting $sc with accel=$ACCEL"

	# No usable root device is provided on purpose. The guest reaches the point
	# where the hook has run and the network is up, and then waits for a root
	# filesystem that never appears -- long enough to observe the node from the
	# control server and log into it.
	qemu-system-x86_64 \
		-accel "$ACCEL" \
		-m 1G -smp 2 \
		-display none -no-reboot \
		-kernel "$KERNEL" \
		-initrd "$img" \
		-append "console=ttyS0 root=$root rw systemd.log_level=info ${SC_APPEND[$sc]}" \
		-netdev user,id=n0 \
		-device virtio-net-pci,netdev=n0 \
		-serial "file:$console" \
		>"$WORK/qemu.$sc.log" 2>&1 &
	QEMU_PID=$!

	local started=$SECONDS deadline=$((SECONDS + BOOT_TIMEOUT)) online=0
	while ((SECONDS < deadline)); do
		if node_online "$node"; then
			online=1
			break
		fi
		if ! kill -0 "$QEMU_PID" 2>/dev/null; then
			warn "QEMU exited before $node came online"
			break
		fi
		sleep 5
	done

	if ((online)); then
		pass "$sc: the initrd node came online after $((SECONDS - started))s"
	else
		fail "$sc: the initrd node came online" \
			"$(printf 'last 40 lines of console:\n%s' "$(tail -40 "$console" 2>/dev/null)")"
	fi

	# Corroborating evidence from inside the guest, useful when the assertion
	# above fails and the question is how far the boot actually got. systemd
	# colours its console output, and the escape sequences land between "Started"
	# and the unit description, so they have to come out before matching.
	sed -r 's/\x1B\[[0-9;?]*[a-zA-Z]//g; s/\x1B\][^\x07]*(\x07|\x1B\\)//g' \
		"$console" >"$text" 2>/dev/null

	if grep -qE "${SC_CONSOLE[$sc]}" "$text"; then
		pass "$sc: the guest started tailscaled"
	else
		fail "$sc: the guest started tailscaled" \
			"$(printf 'console is %s bytes; last 40 lines (de-escaped):\n%s' \
				"$(stat -c %s "$console" 2>/dev/null || echo missing)" \
				"$(tail -40 "$text" 2>/dev/null)")"
	fi

	if ((online)); then
		assert_ssh "$sc" "$node"
	else
		warn "$sc: skipping the ssh assertions; the node never came online"
	fi

	kill "$QEMU_PID" 2>/dev/null
	wait "$QEMU_PID" 2>/dev/null
	QEMU_PID=''
	endgroup
}

assert_ssh() {
	local sc=$1 node=$2 ip
	ip=$(node_ip "$node")
	if [[ -z $ip ]]; then
		fail "$sc: headscale reports a tailnet address for $node" \
			"$(hs nodes list 2>&1 | tail -10)"
		return 0
	fi

	SSH_SC=$sc
	SSH_IP=$ip
	SSH_KNOWN="$WORK/known_hosts.$sc"
	SSH_MARKER=${SC_ROOT[$sc]}
	# Nothing here may consult the caller's ssh configuration, agent or keys.
	# Tailscale SSH authorises by tailnet identity, so those scenarios shut
	# pubkey auth off entirely; the dropbear scenario is the opposite -- it
	# authorises by exactly one key, the throwaway one this run generated.
	SSH_OPTS=(
		-n
		-F /dev/null
		-o BatchMode=yes
		-o IdentityAgent=none
		-o StrictHostKeyChecking=accept-new
		-o UserKnownHostsFile="$SSH_KNOWN"
		-o GlobalKnownHostsFile=/dev/null
		-o ConnectTimeout=20
		-o "ProxyCommand=tailscale --socket=$CLIENT_SOCK nc %h %p"
	)
	if [[ $sc == dropbear ]]; then
		# Root, not $SSH_USER: dropbear requires the authorized_keys path to be
		# owned by the login user, and mkinitcpio squashes image files to uid 0.
		# See tests/initcpio/install/testdropbear.
		SSH_LOGIN=root
		SSH_OPTS+=(
			-o PubkeyAuthentication=yes
			-o IdentitiesOnly=yes
			-i "$WORK/dropbear_client_key"
		)
	else
		SSH_LOGIN=$SSH_USER
		SSH_OPTS+=(-o PubkeyAuthentication=no)
	fi
	info "$sc: reaching $node at $ip over the tailnet"

	check "$sc: ssh runs a command inside the initramfs" ssh_runs_a_command
	check "$sc: the ssh host key is the expected one" \
		hostkey_is_the_expected_one
}

# --- boot -----------------------------------------------------------------
ACCEL=tcg
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
	ACCEL=kvm
else
	warn 'no usable /dev/kvm; falling back to TCG emulation (slower)'
fi

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

# Throwaway key material for the dropbear scenario: a dropbear-format host key
# the testdropbear hook copies into the image, and an OpenSSH client keypair
# whose public half becomes the image's authorized_keys. Both exist only for
# this run; the host key's public half is what the ssh assertions compare the
# offered key against, same as the Tailscale SSH scenarios.
if has_scenario dropbear; then
	dropbearkey -t ed25519 -f "$WORK/dropbear_host_key" >/dev/null 2>&1
	dropbearkey -y -f "$WORK/dropbear_host_key" 2>/dev/null |
		grep '^ssh-ed25519' >"$WORK/hostkey.dropbear.pub"
	[[ -s $WORK/hostkey.dropbear.pub ]] || die 'could not derive the dropbear host public key'
	ssh-keygen -q -t ed25519 -N '' -f "$WORK/dropbear_client_key"
	export TESTDROPBEAR_HOSTKEY="$WORK/dropbear_host_key"
	export TESTDROPBEAR_AUTHKEYS="$WORK/dropbear_client_key.pub"
fi

for sc in "${SCENARIOS[@]}"; do
	run_scenario "$sc"
done

summary

#!/usr/bin/env bash
# Runs the test suite in a throwaway Arch container, so it never touches the
# host's /etc/initcpio/tailscale or installed packages.
#
#   tests/container.sh              # 01-lint, 02-package, 03-initramfs
#   tests/container.sh all          # plus the QEMU boot test
#   tests/container.sh 01 02        # a subset
#
# Uses podman if available, otherwise docker. CI's lint, package and initramfs
# jobs run tests/NN-*.sh directly in an Arch `container:` job, so the package set
# below is kept in step with the workflow. The boot job does call this script,
# so that --device /dev/kvm is only passed when the runner actually has KVM.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
IMAGE=${IMAGE:-docker.io/library/archlinux:base-devel}

ENGINE=${ENGINE:-}
if [[ -z $ENGINE ]]; then
	ENGINE=$(command -v podman || command -v docker) ||
		{ echo 'neither podman nor docker found' >&2; exit 1; }
fi

STAGES=("$@")
((${#STAGES[@]})) || STAGES=(01 02 03)
WANTS_ALL=0
[[ ${STAGES[0]} == all ]] && WANTS_ALL=1

# Only install what the requested stages need; pulling the kernel and QEMU for
# a lint run would be a waste.
PKGS=(git)
want() {
	((WANTS_ALL)) && return 0
	local s
	for s in "${STAGES[@]}"; do [[ $s == "$1"* ]] && return 0; done
	return 1
}
want 01 && PKGS+=(shellcheck mkinitcpio)
want 02 && PKGS+=(pacman-contrib namcap)
want 03 && PKGS+=(mkinitcpio linux tailscale openssh)
want 04 && PKGS+=(mkinitcpio linux tailscale openssh qemu-base jq curl dropbear)

RUN_OPTS=()
[[ -t 0 && -t 1 ]] && RUN_OPTS+=(-it)

# Knobs for the boot test that are worth reaching from outside the container:
# which scenarios to boot, and how long each one may take.
for var in BOOT_SCENARIOS BOOT_TIMEOUT; do
	[[ -n ${!var:-} ]] && RUN_OPTS+=(-e "$var=${!var}")
done

# Somewhere for the tests to leave console/build logs behind on failure.
if [[ -n ${ARTIFACT_DIR:-} ]]; then
	mkdir -p "$ARTIFACT_DIR"
	RUN_OPTS+=(-v "$(cd "$ARTIFACT_DIR" && pwd):/artifacts:rw" -e ARTIFACT_DIR=/artifacts)
fi

if ((WANTS_ALL)) || want 04; then
	# QEMU is dramatically faster with hardware acceleration; the boot test
	# falls back to TCG when this is not available.
	[[ -e /dev/kvm ]] && RUN_OPTS+=(--device /dev/kvm)
fi

# PKGS and STAGES are passed in as environment variables and expanded by the
# shell inside the container, so the script below is deliberately single-quoted.
# shellcheck disable=SC2016
exec "$ENGINE" run --rm "${RUN_OPTS[@]}" \
	-v "$REPO:/src:ro" -w /src \
	-e "STAGES=${STAGES[*]}" \
	-e "PKGS=${PKGS[*]}" \
	"$IMAGE" \
	bash -euo pipefail -c '
		# Installing a kernel triggers mkinitcpio -P against the stock preset,
		# which cannot work in a container (autodetect needs the real host).
		# Disabling just that hook keeps 60-depmod.hook, which the tests need.
		install -d /etc/pacman.d/hooks
		ln -sf /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook

		# mkinitcpio is named explicitly because the linux package depends on
		# the virtual "initramfs" provider and --noconfirm would otherwise be
		# free to pick dracut.
		pacman -Syu --noconfirm --needed $PKGS >/dev/null

		# makepkg refuses to run as root; tests/run.sh drops to this user.
		useradd -m builder 2>/dev/null || true

		exec /src/tests/run.sh $STAGES
	'

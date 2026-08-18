#!/usr/bin/env bash
# Runs the test suite in a throwaway container, so it never touches the
# host's /etc/initcpio/tailscale or installed packages.
#
#   tests/container.sh              # 01-lint, 02-package, 03-initramfs, on Arch
#   tests/container.sh all          # plus the QEMU boot test
#   tests/container.sh 01 02        # a subset
#   tests/container.sh void         # 01-lint, 03-initramfs, on Void Linux
#   tests/container.sh void 03      # a subset of that
#
# The void lane builds and inspects images with Void's mkinitcpio on a host
# with no systemd, which is what a Void machine running this hook looks like;
# see docs/void-port.md. It has no 02 or 04: those stages build an Arch
# package and boot an Arch userland.
#
# Uses podman if available, otherwise docker. CI's lint, package and initramfs
# jobs run tests/NN-*.sh directly in `container:` jobs, so the package sets
# below are kept in step with the workflow. The boot job does call this script,
# so that --device /dev/kvm is only passed when the runner actually has KVM.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)

DISTRO=arch
if [[ ${1:-} == void ]]; then
	DISTRO=void
	shift
fi
if [[ $DISTRO == void ]]; then
	IMAGE=${IMAGE:-ghcr.io/void-linux/void-glibc:latest}
else
	IMAGE=${IMAGE:-docker.io/library/archlinux:base-devel}
fi

ENGINE=${ENGINE:-}
if [[ -z $ENGINE ]]; then
	ENGINE=$(command -v podman || command -v docker) ||
		{ echo 'neither podman nor docker found' >&2; exit 1; }
fi

STAGES=("$@")
if [[ $DISTRO == void ]]; then
	((${#STAGES[@]})) || STAGES=(01 03)
	for s in "${STAGES[@]}"; do
		[[ $s == 01* || $s == 03* ]] ||
			{ echo "the void lane runs stages 01 and 03 only, not '$s'" >&2; exit 2; }
	done
else
	((${#STAGES[@]})) || STAGES=(01 02 03)
fi
WANTS_ALL=0
[[ ${STAGES[0]} == all ]] && WANTS_ALL=1

# Only install what the requested stages need; pulling the kernel and QEMU for
# a lint run would be a waste.
want() {
	((WANTS_ALL)) && return 0
	local s
	for s in "${STAGES[@]}"; do [[ $s == "$1"* ]] && return 0; done
	return 1
}
if [[ $DISTRO == void ]]; then
	# bash is named because the base container only guarantees sh, and the
	# whole suite runs under bash. The rest fills the distance between the
	# slim container and a real Void system: mkinitcpio builds images with
	# find, the keymap and consolefont hooks run loadkeys and setfont (kbd,
	# part of base-system), and the tests byte-compare with cmp and diff.
	# The kernel is kept out of PKGS: it goes in on its own after mkinitcpio's
	# kernel hook has been disarmed below.
	PKGS=(bash)
	KERNEL_PKGS=()
	want 01 && PKGS+=(shellcheck mkinitcpio)
	want 03 && { PKGS+=(findutils diffutils kbd mkinitcpio tailscale openssh); KERNEL_PKGS=(linux); }
else
	PKGS=(git)
	want 01 && PKGS+=(shellcheck mkinitcpio)
	want 02 && PKGS+=(pacman-contrib namcap)
	want 03 && PKGS+=(mkinitcpio linux tailscale openssh)
	want 04 && PKGS+=(mkinitcpio linux tailscale openssh qemu-base jq curl dropbear opendoas)
fi

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

# The package and stage lists are passed in as environment variables and
# expanded by the shell inside the container, so the scripts below are
# deliberately single-quoted.

if [[ $DISTRO == void ]]; then
	# sh rather than bash on the outside: the base container has no bash until
	# the install below brings it in.
	# shellcheck disable=SC2016
	exec "$ENGINE" run --rm "${RUN_OPTS[@]}" \
		-v "$REPO:/src:ro" -w /src \
		-e "STAGES=${STAGES[*]}" \
		-e "PKGS=${PKGS[*]}" \
		-e "KERNEL_PKGS=${KERNEL_PKGS[*]}" \
		"$IMAGE" \
		sh -euc '
			# The container image slims itself with noextract rules that also
			# strip files mkinitcpio needs at image build time, the udev
			# helpers among them. Drop the rules before anything installs, and
			# reinstall the two packages whose payloads the image was built
			# without, so the container looks like a real Void system where it
			# matters.
			rm -f /etc/xbps.d/noextract*.conf

			xbps-install -Syu xbps >/dev/null
			xbps-install -yu >/dev/null
			xbps-install -y $PKGS >/dev/null
			xbps-install -yf eudev libkmod >/dev/null

			# Installing a kernel runs the /etc/kernel.d hooks, and with
			# mkinitcpio now installed its hook would build an initramfs
			# against the stock preset, which cannot work in a container
			# (autodetect needs the real host). A /dev/null symlink is not
			# executable, so the kernel trigger skips it; the tests build
			# their images with their own configuration.
			if [ -n "$KERNEL_PKGS" ]; then
				ln -sf /dev/null /etc/kernel.d/post-install/20-initramfs
				xbps-install -y $KERNEL_PKGS >/dev/null
			fi

			exec /src/tests/run.sh $STAGES
		'
fi

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

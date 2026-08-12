#!/usr/bin/env bash
# Runs test stages in order and reports a combined result.
#
#   tests/run.sh                 # 01-lint, 02-package, 03-initramfs
#   tests/run.sh all             # the above plus 04-boot
#   tests/run.sh 03 04           # just those, by prefix or full name
#
# 04-boot is excluded by default because it downloads headscale and boots QEMU.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

DEFAULT_STAGES=(01-lint 02-package 03-initramfs)
ALL_STAGES=(01-lint 02-package 03-initramfs 04-boot)

resolve_stage() {
	local want=$1 s
	for s in "${ALL_STAGES[@]}"; do
		[[ $s == "$want" || $s == "$want"-* ]] && {
			printf '%s\n' "$s"
			return 0
		}
	done
	return 1
}

STAGES=()
if (($# == 0)); then
	STAGES=("${DEFAULT_STAGES[@]}")
elif [[ $1 == all ]]; then
	STAGES=("${ALL_STAGES[@]}")
else
	for a in "$@"; do
		s=$(resolve_stage "$a") || {
			printf 'unknown stage: %s (known: %s)\n' "$a" "${ALL_STAGES[*]}" >&2
			exit 2
		}
		STAGES+=("$s")
	done
fi

# makepkg refuses to run as root, so when the suite is driven as root (the
# normal case in a container) the packaging stage drops to an unprivileged user.
run_stage() {
	local stage=$1 script="$HERE/$1.sh"
	if [[ $stage == 02-package && $(id -u) == 0 ]]; then
		id builder >/dev/null 2>&1 ||
			{ printf 'skipping 02-package: running as root and no "builder" user exists\n' >&2; return 0; }
		runuser -u builder -- "$script"
	else
		"$script"
	fi
}

FAILED=()
for stage in "${STAGES[@]}"; do
	printf '\n\033[1m########## %s ##########\033[0m\n' "$stage"
	run_stage "$stage" || FAILED+=("$stage")
done

printf '\n\033[1m########## result ##########\033[0m\n'
if ((${#FAILED[@]})); then
	printf '\033[31mfailed stages: %s\033[0m\n' "${FAILED[*]}"
	exit 1
fi
printf '\033[32mall stages passed: %s\033[0m\n' "${STAGES[*]}"

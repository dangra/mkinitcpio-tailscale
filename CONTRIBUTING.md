# Contributing

Small project, unusual machinery. The five minutes here save an hour of
reverse-engineering.

## What ships

Four files reach users, via the AUR package:

- `initcpio-install-tailscale` builds the image (mkinitcpio "install hook")
- `initcpio-hooks-tailscale` runs inside it at boot (busybox branch only;
  the systemd branch runs `tailscaled.service` instead)
- `setup-initcpio-tailscale` registers the node and verifies setups
- `libalpm-hook-tailscale` / `libalpm-script-tailscale` rebuild the image
  when the tailscale package is upgraded, and
  `mkinitcpio-tailscale.install` migrates configs across breaking changes

Everything else is packaging, tests, or release plumbing.

## PKGBUILD is a template

`pkgver`, `pkgrel` and `sha256sums` are placeholders; `.SRCINFO` is not
tracked. `scripts/aur-stage.sh` fills them in from a git tag. Run
`make build`, not bare `makepkg`, or you get a package labelled 0.0.0.

## Tests

```sh
make test        # lint + arg-scan units, packaging, image contents
make test-all    # adds the QEMU boot matrix against a throwaway headscale
```

Both run in a disposable Arch container (podman or docker) and never touch
your system. The boot stage registers real nodes against a local headscale,
boots real images under QEMU, and logs in over the tailnet; one scenario at
a time via `BOOT_SCENARIOS=<name> ./tests/container.sh 04`.

The ground rule this repo runs on: **a promise without a test is a bug that
has not happened yet.** New behaviour comes with suite coverage -- a boot
scenario, an image assertion, an arg-scan case -- or, where the suite
genuinely cannot reach it, a one-off verification described in the commit
message. Several of this project's nastiest bugs were found by writing the
test the README's claims implied.

Style is enforced by the lint stage: shellcheck findings block, the runtime
hooks must parse under busybox ash, and the README uses no em dashes.

## Releases

Push an annotated tag and CI does the rest, in order: full suite, publish
to the AUR, GitHub release with the built package attached.

```sh
git tag -a v1.2.3 -m "Release 1.2.3" && git push origin v1.2.3
```

Every push and pull request runs the same publish path in dry-run mode
against the live AUR, so the release machinery cannot rot between releases.
A daily canary reruns the suite when a dependency the image cares about is
updated in Arch, and files an issue when that breaks something.

## Commit messages

Prose, and mostly about why. The history is written to be read: when a
change encodes a discovery (an ordering constraint, an upstream behaviour,
a measured result), the commit message is where it lives.

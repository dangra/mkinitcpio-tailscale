# Reusing this hook on Void Linux

Research notes on what it takes to run mkinitcpio-tailscale on Void Linux,
and what of that has landed. The hook and setup helper now run unchanged on
Void, and CI proves it: the `initramfs (void)` job and `make test-void` build
and inspect images with Void's mkinitcpio on a host with no systemd. What
remains open is listed below. Facts were checked against the Void handbook,
the void-packages templates and a live mirror on 2026-08-18.

## Why Void is a natural target

Void supports mkinitcpio as a first-class alternative to dracut, its default
initramfs generator. The [mkinitcpio package][void-mkinitcpio] (version 41, the
same generation Arch ships) registers in the XBPS `initramfs` alternatives
group; switching a machine over is:

```sh
xbps-install mkinitcpio
xbps-alternatives -s mkinitcpio
xbps-reconfigure -f linux<x>.<y>   # per installed kernel
```

as the [Void handbook][void-kernel] describes. From then on kernel updates
rebuild the image through Void's `/etc/kernel.d` hooks, which the alternatives
group points at mkinitcpio's own kernel hook. The supporting hooks this README
recommends are all in Void's official repos, in some cases more conveniently
than on Arch, where `netconf` lives in the AUR:

| package | version | provides |
| ------- | ------- | -------- |
| `mkinitcpio-nfs-utils` | 0.3 | the `net` hook |
| `mkinitcpio-netconf` | 0.0.5 | the `netconf` hook |
| `mkinitcpio-dropbear` | 0.0.5 | the `dropbear` hook |
| `mkinitcpio-encrypt` | 41 | the `encrypt` hook, split out of base mkinitcpio |
| `tailscale` | 1.102.2 | `tailscaled` and the CLI, in `/usr/bin` |

Void has no systemd, so only the busybox half of this project would ever run
there. That costs nothing: the install hook picks its layout by feature
detection (`add_systemd_unit` never exists on Void), so the systemd branch is
dead code rather than a porting problem, and the busybox branch is the one the
QEMU boot matrix already exercises.

## What works unchanged

Most of the codebase is distro-neutral:

- **The install hook** requires only that `tailscaled` be on PATH; it asks no
  package manager anything. (`add_binary` would fail the build anyway; the
  guard exists for the friendlier message.)
- **The runtime hook** is busybox ash against mkinitcpio's own init; nothing in
  it is Arch's.
- **The install hook's hardcoded `/usr/sbin/tailscaled`** resolves on Void even
  though its tailscale package installs to `/usr/bin`: mkinitcpio's
  `initialize_buildroot` creates `usr/sbin -> bin` inside every image, and
  `add_binary tailscaled` resolves through PATH on the host.
- **`getent`** exists on both Void libcs: glibc ships it, and Void's
  [musl package][void-musl] builds one of its own. tailscaled itself is Go and
  runs fine on musl.
- **`setup-initcpio-tailscale`** needs bash, sudo or doas, ssh-keygen, and
  optionally jq, all ordinary Void packages. Its `--check` parses the same
  `/etc/mkinitcpio.conf`, uses the same `lsinitcpio`, and inspects the same
  `/boot/initramfs-*.img` naming.
- **The configuration paths** under `/etc/initcpio/tailscale/` carry no distro
  assumption.

## What stays Arch-only

The pieces with no Void counterpart, in decreasing order of substance:

1. **Rebuild on tailscale upgrades.** The libalpm hook and script pair has no
   XBPS equivalent: XBPS has no user-definable transaction hooks, so a package
   cannot react to another package's upgrade. On Void this becomes
   documentation: after a `tailscale` upgrade, run `mkinitcpio -P` (or
   `xbps-reconfigure -f linux<x>.<y>`) by hand, or the image keeps booting the
   old daemon. This is the one functional gap.
2. **The alpm scriptlet** (`mkinitcpio-tailscale.install`, the 2.0.0 TUN
   migration) is irrelevant to a fresh Void install and needs no counterpart.
3. **The PKGBUILD and AUR pipeline** are Arch-only by nature and stay that way;
   see the next section for why no Void package is planned.
4. **The README's install guidance** assumes pacman and the AUR, and its
   systemd rows do not apply on Void; its Void section points back here.

## The existing Void package

Void's official repos already ship a [`mkinitcpio-tailscale`][void-template]
(0.1.2), by [@classabbyamp][classabbyamp-repo], whose earlier hook is credited
in this README as prior work. It is a different, leaner implementation:
registration via a pre-auth key rather than an interactive setup helper,
configuration in `/etc/tailscale/tailscaled.conf`, a kernel TUN device with
iptables in the image rather than userspace networking, and no persisted SSH
host keys or `--check` equivalent.

The stance here is to coexist, not compete: same problem, same hook name, and a
maintainer who is also a Void packager. Void users who want what this project
adds (the setup helper and `--check`, userspace networking with no tun or
netfilter in the image, persisted Tailscale SSH host identity) can install it
from git; users who want an `xbps-install` one-liner already have one. A
void-packages submission under a colliding name is not on the table.

## Manual install

What a Void user does today:

```sh
xbps-install mkinitcpio mkinitcpio-encrypt mkinitcpio-nfs-utils tailscale
xbps-alternatives -s mkinitcpio

install -m644 -D initcpio-hooks-tailscale   /etc/initcpio/hooks/tailscale
install -m644 -D initcpio-install-tailscale /etc/initcpio/install/tailscale
install -m755 -D setup-initcpio-tailscale   /usr/local/bin/setup-initcpio-tailscale
```

`/etc/initcpio/` is mkinitcpio's user-hook search path, so nothing needs to
reach into `/usr/lib/initcpio/`, which belongs to xbps. From there the README's
configure steps apply as written, busybox rows only: register the node, add a
network hook (`net` or `netconf`, both official packages), place `tailscale`
before `encrypt` in `HOOKS=`, rebuild with `mkinitcpio -P`, and verify with
`setup-initcpio-tailscale --check`. The one Void-specific habit is rebuilding
by hand after a `tailscale` upgrade, since no hook does it for you.

## Validation

1. **The Void container lane** exists: `make test-void` (or
   `tests/container.sh void`) runs the lint and image-contents stages in
   `ghcr.io/void-linux/void-glibc`, and CI runs the same as the
   `initramfs (void)` job on every change. Images are built with Void's
   mkinitcpio on a host with no systemd, so the suite exercises exactly the
   busybox variants a Void machine would boot, and skips the systemd ones.
2. **A Void QEMU boot scenario** against the throwaway headscale remains
   future work; the boot matrix stays Arch-only until someone takes it on.

[void-mkinitcpio]: https://github.com/void-linux/void-packages/blob/master/srcpkgs/mkinitcpio/template
[void-kernel]: https://docs.voidlinux.org/config/kernel.html
[void-musl]: https://github.com/void-linux/void-packages/blob/master/srcpkgs/musl/template
[void-template]: https://github.com/void-linux/void-packages/blob/master/srcpkgs/mkinitcpio-tailscale/template
[classabbyamp-repo]: https://github.com/classabbyamp/mkinitcpio-tailscale

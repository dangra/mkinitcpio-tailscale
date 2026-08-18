# Reusing this hook on Void Linux

Research notes on what it would take to run mkinitcpio-tailscale on Void Linux.
This is a report, not a commitment: nothing in the repo changes with it, and the
gaps it lists are the work a port would consist of. Facts were checked against
the Void handbook, the void-packages templates and a live mirror on 2026-08-18.

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

## What already works unchanged

Most of the codebase is distro-neutral today:

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

## The gap list

What a port would actually touch, in decreasing order of substance:

1. **Rebuild on tailscale upgrades.** The libalpm hook and script pair has no
   XBPS equivalent: XBPS has no user-definable transaction hooks, so a package
   cannot react to another package's upgrade. On Void this becomes
   documentation: after a `tailscale` upgrade, run `mkinitcpio -P` (or
   `xbps-reconfigure -f linux<x>.<y>`) by hand, or the image keeps booting the
   old daemon. This is the one functional gap.
2. **The `pacman -Qi tailscale` guard** in the install hook is likely not
   needed at all: `add_binary` already fails the build when `tailscaled` is
   absent, so the guard only buys a friendlier message, and
   `command -v tailscaled` buys the same one without asking any package
   manager. Deletion or that one-line swap makes the hook portable.
3. **The alpm scriptlet** (`mkinitcpio-tailscale.install`, the 2.0.0 TUN
   migration) is irrelevant to a fresh Void install and needs no counterpart.
4. **The PKGBUILD and AUR pipeline** are Arch-only by nature and stay that way;
   see the next section for why no Void package is planned.
5. **Docs text.** The README's install and next-steps guidance assumes pacman
   and the AUR, and its systemd rows do not apply on Void.

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

## Manual install sketch

What a Void user would do today, once the gap-list items land. File
destinations mirror the PKGBUILD's:

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

## Validation plan

When the port happens, in this order:

1. **A Void container lane** beside the Arch one in `tests/container.sh`:
   run the lint, packaging and image-contents scripts (tests/01 to 03) in
   `ghcr.io/void-linux/void-glibc`, installing `mkinitcpio` and `tailscale`
   via xbps and copying the hook files into place by hand, since there is no
   package to install. Building the image with Void's mkinitcpio 41 and
   inspecting it for `tailscaled`, the passwd database and the tun-module
   logic covers most of what the port could break.
2. **A Void QEMU boot scenario** against the throwaway headscale, later. The
   boot matrix stays Arch-only until the container lane exists and is green.

[void-mkinitcpio]: https://github.com/void-linux/void-packages/blob/master/srcpkgs/mkinitcpio/template
[void-kernel]: https://docs.voidlinux.org/config/kernel.html
[void-musl]: https://github.com/void-linux/void-packages/blob/master/srcpkgs/musl/template
[void-template]: https://github.com/void-linux/void-packages/blob/master/srcpkgs/mkinitcpio-tailscale/template
[classabbyamp-repo]: https://github.com/classabbyamp/mkinitcpio-tailscale

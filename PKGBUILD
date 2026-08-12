# Maintainer:  Daniel Graña <dangra at gmail dot com>
#
# This is a template, not a finished package definition. pkgver, pkgrel and
# sha256sums are placeholders filled in at release time by scripts/aur-stage.sh
# from the git tag being published; .SRCINFO is generated there too and is not
# tracked in this repo. Build with `make build` (which stages first) rather than
# running makepkg here, or you will get a package labelled 0.0.0.

pkgname=mkinitcpio-tailscale
pkgver=0.0.0
pkgrel=1
pkgdesc="mkinitcpio hook to launch Tailscale on systemd or busybox based initramfs"
arch=("any")
url="https://github.com/dangra/mkinitcpio-tailscale"
license=("GPL-2.0-or-later")
depends=("mkinitcpio")
source=("initcpio-hooks-tailscale"
  "initcpio-install-tailscale"
  "setup-initcpio-tailscale")
sha256sums=('SKIP'
            'SKIP'
            'SKIP')

package() {
  install -m 644 -D "${srcdir}/initcpio-hooks-tailscale" "${pkgdir}/usr/lib/initcpio/hooks/tailscale"
  install -m 644 -D "${srcdir}/initcpio-install-tailscale" "${pkgdir}/usr/lib/initcpio/install/tailscale"
  install -m 755 -D "${srcdir}/setup-initcpio-tailscale" "${pkgdir}/usr/bin/setup-initcpio-tailscale"
}

# Maintainer:  Daniel Graña <dangra at gmail dot com>

pkgname=mkinitcpio-tailscale
pkgver=1.0.1
pkgrel=1
pkgdesc="mkinitcpio hook to launch Tailscale on systemd or busybox based initramfs"
arch=("any")
url="https://github.com/dangra/mkinitcpio-tailscale"
license=("GPL-2.0-or-later")
depends=("mkinitcpio")
source=("initcpio-hooks-tailscale"
  "initcpio-install-tailscale"
  "setup-initcpio-tailscale")
sha256sums=('ce5df937e08ee7791921aad719413640aca445083694b2f526008a8ad53d4155'
            '906d1b494f8b4b2f34bc9b1c8b001a69531f59ec8c46555b16a9824ef55d3da4'
            '6a02cda2814752d64c45d6c24ae54ce760787ca169574baf907d76c5ca869c23')

package() {
  install -m 644 -D ${srcdir}/initcpio-hooks-tailscale ${pkgdir}/usr/lib/initcpio/hooks/tailscale
  install -m 644 -D ${srcdir}/initcpio-install-tailscale ${pkgdir}/usr/lib/initcpio/install/tailscale
  install -m 755 -D ${srcdir}/setup-initcpio-tailscale ${pkgdir}/usr/bin/setup-initcpio-tailscale
}

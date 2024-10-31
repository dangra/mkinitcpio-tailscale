# Maintainer:  Daniel Graña <dangra at gmail dot com>

pkgname=mkinitcpio-tailscale
pkgver=1.0
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
            'e16ffdc2ab0f46ff66f2fe09ed0d20193075ae6395451728bcece842fe02228d'
            'e6cf49ea9ac359d21665444c2a3ab009aedb52d215e47287ecff7d6d4159d4c2')

package() {
  install -m 644 -D ${srcdir}/initcpio-hooks-tailscale ${pkgdir}/usr/lib/initcpio/hooks/tailscale
  install -m 644 -D ${srcdir}/initcpio-install-tailscale ${pkgdir}/usr/lib/initcpio/install/tailscale
  install -m 755 -D ${srcdir}/setup-initcpio-tailscale ${pkgdir}/usr/bin/setup-initcpio-tailscale
}

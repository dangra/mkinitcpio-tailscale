# Maintainer:  Daniel Graña <dangra at gmail dot com>
# aur-stage:strip-start
#
# Everything between the strip markers is removed by scripts/aur-stage.sh and
# never reaches the AUR, where it would be both wrong and confusing: the
# published PKGBUILD is a finished definition and none of this applies to it.
#
# This file is a template. pkgver, pkgrel and sha256sums are placeholders filled
# in at release time from the git tag being published; .SRCINFO is generated
# there too and is not tracked in this repo. Build with `make build` (which
# stages first) rather than running makepkg here, or you will get a package
# labelled 0.0.0.
# aur-stage:strip-end

pkgname=mkinitcpio-tailscale
pkgver=0.0.0
pkgrel=1
pkgdesc="mkinitcpio hook to launch Tailscale on systemd or busybox based initramfs"
arch=("any")
url="https://github.com/dangra/mkinitcpio-tailscale"
license=("GPL-2.0-or-later")
# tailscale is needed at image build time: the install hook refuses to build
# without the package installed.
depends=("mkinitcpio" "tailscale")
optdepends=("openssh: host key generation for the default Tailscale SSH setup")
source=("initcpio-hooks-tailscale"
  "initcpio-install-tailscale"
  "setup-initcpio-tailscale"
  "libalpm-hook-tailscale"
  "libalpm-script-tailscale")
sha256sums=('SKIP'
            'SKIP'
            'SKIP'
            'SKIP'
            'SKIP')

package() {
  install -m 644 -D "${srcdir}/initcpio-hooks-tailscale" "${pkgdir}/usr/lib/initcpio/hooks/tailscale"
  install -m 644 -D "${srcdir}/initcpio-install-tailscale" "${pkgdir}/usr/lib/initcpio/install/tailscale"
  install -m 755 -D "${srcdir}/setup-initcpio-tailscale" "${pkgdir}/usr/bin/setup-initcpio-tailscale"
  install -m 644 -D "${srcdir}/libalpm-hook-tailscale" "${pkgdir}/usr/share/libalpm/hooks/mkinitcpio-tailscale.hook"
  install -m 755 -D "${srcdir}/libalpm-script-tailscale" "${pkgdir}/usr/share/libalpm/scripts/mkinitcpio-tailscale"
}

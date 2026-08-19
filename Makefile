
STAGEDIR ?= .stage
TAG ?=

.PHONY: stage build install publish test test-all test-void clean


# PKGBUILD in this repo is a template: pkgver, pkgrel and sha256sums are
# placeholders and .SRCINFO is not tracked. Everything that needs a real package
# definition stages one first, so a local build and a release cannot differ.
#
# Pass TAG to stamp a version, e.g. `make build TAG=v1.2.0`; without it the
# 0.0.0 placeholder is kept.
stage:
	rm -rf "$(STAGEDIR)"
	./scripts/aur-stage.sh "$(STAGEDIR)" $(if $(TAG),--tag "$(TAG)")

build: stage
	cd "$(STAGEDIR)" && makepkg -f

install: stage
	cd "$(STAGEDIR)" && makepkg -if

# Publish to the AUR. Requires a tagged commit, or `make publish TAG=vX.Y.Z`.
# Set AUR_REMOTE to rehearse against a scratch repo.
publish:
	./scripts/aur-publish.sh $(if $(TAG),--tag "$(TAG)")

# Runs the same scripts CI does, in a throwaway Arch container.
test:
	./tests/container.sh

# Adds the QEMU boot test against a throwaway headscale server.
test-all:
	./tests/container.sh all

# The lint and image-contents stages again, in a throwaway Void Linux
# container: no systemd, Void's mkinitcpio. See docs/void-port.md.
test-void:
	./tests/container.sh void

clean:
	rm -rf "$(STAGEDIR)"

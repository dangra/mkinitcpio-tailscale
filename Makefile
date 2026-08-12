
.PHONY: build install update checksums srcinfo publish test test-all


build: update
	makepkg -cCf

install: update
	makepkg -icCf

update: checksums srcinfo

checksums:
	updpkgsums

srcinfo:
	makepkg --printsrcinfo >.SRCINFO

publish:
	git push ssh://aur@aur.archlinux.org/mkinitcpio-tailscale.git

# Runs the same scripts CI does, in a throwaway Arch container.
test:
	./tests/container.sh

# Adds the QEMU boot test against a throwaway headscale server.
test-all:
	./tests/container.sh all

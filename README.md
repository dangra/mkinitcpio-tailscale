# mkinitcpio-tailscale

This project provides a [mkinitcpio][1] hook that lets you connect to your
[Tailscale][2] network from inside the initramfs (the early userspace
environment, before the system switches to the final root filesystem).

It's particularly useful for remotely unlocking systems with encrypted root
filesystems. For setup details on decrypting the rootfs and adding remote unlock
support, see the Arch Linux Wiki pages linked below. If you use the built-in
Tailscale SSH server you do not need an additional SSH server — see the section
on the Tailscale SSH server for details.

- [Mkinitcpio][1]
- [Tailscale][2]
- ArchWiki: [dm-crypt / Encrypting an entire system — Configuring mkinitcpio][3]
- ArchWiki: [Dm-crypt — Remote unlocking of root (or other) partition][4]

By combining mkinitcpio with Tailscale you get a secure VPN path to your locked
server from anywhere — no need to expose SSH to the internet or open firewall
ports.

## Installation

You can install the package from the AUR:

```sh
yay -S mkinitcpio-tailscale
```

## Configure

Run the helper and follow the prompts:

```sh
sudo setup-initcpio-tailscale
```

This will register a new Tailscale node using a hostname based on your system.
For example, if your host is named `homeserver`, the node will appear as
`homeserver-initrd` in the Tailscale admin panel, which makes it easy to
identify.

Next, edit `/etc/mkinitcpio.conf` and add `tailscale` to the `HOOKS` array.

- For systemd-based initramfs, place the `tailscale` hook anywhere after the
  `systemd` hook.
- For busybox-based initramfs, add it after network-related hooks but before
  blocking hooks like `encrypt` / `encryptssh`.

Example (conceptual):

```text
HOOKS=(base systemd autodetect modconf block filesystems keyboard fsck tailscale)
# or for busybox-based initramfs: ensure tailscale is before encrypt
```

After editing `mkinitcpio.conf`, regenerate your initramfs:

```sh
sudo mkinitcpio -P
# or: sudo mkinitcpio -p linux
```

This updates your initramfs so the new hook and node key are included.

### Tailscale SSH server

Tailscale includes a built-in SSH server. If you enable it when running the
setup helper, you don't need `dropbear`, `tinyssh`, or another SSH server inside
initramfs.

Enable it with:

```sh
sudo setup-initcpio-tailscale --ssh
```

Note: the Tailscale SSH server only accepts connections from within your
tailnet. The node won’t accept local connections unless the client is also part
of your Tailscale network — this reduces exposure compared to a traditional SSH
server reachable from everywhere.

## Security considerations

The Tailscale node key is stored in plaintext inside the initramfs. Initramfs is
usually not encrypted, so physical access to the machine could allow an attacker
to extract the node key and impersonate your initrd node on your tailnet.

Mitigations:

- Restrict what the initramfs node can access with Tailscale ACLs and tags. Tag
  the initrd node in the Machines panel and limit its permissions.
- Prefer granting the initrd node only the minimal access required (for example,
  only allow SSH from a narrow set of client tags).
- If a node is ever compromised, remove it from the Tailscale admin panel
  immediately and recreate the initramfs/node key.

Example ACL snippet to restrict initrd nodes (adapt to your tailnet):

```json
{
  "tagOwners": {
    "tag:initrd": ["autogroup:admin"],
    "tag:client": ["autogroup:admin"],
    "tag:server": ["autogroup:admin"]
  },

  "acls": [
    { "action": "accept", "src": ["tag:client"], "dst": ["*:*"] },
    { "action": "accept", "src": ["tag:server"], "dst": ["tag:server:*"] }
  ],

  "ssh": [
    {
      "action": "accept",
      "src": ["tag:client"],
      "dst": ["tag:initrd"],
      "users": ["autogroup:nonroot", "root"]
    }
  ]
}
```

Even if an attacker obtains your initramfs node key, the ACLs above limit what
that node can do and help protect the rest of your network.

If you suspect compromise:

- Remove the initrd device from the Tailscale admin console.
- Re-run `setup-initcpio-tailscale` to register a fresh node and rebuild your
  initramfs.

## Prior work and big thanks

- [@tavianator][gh1] — early work and inspiration:
  <https://gist.github.com/tavianator/6b00355cedae0b2ceb338e43ce8e5c1a>
- [@karepker][gh2] — detailed rootfs unlocking guide for Raspberry Pi + Arch
  Linux
- [@classabbyamp][gh3] — a similar mkinitcpio hook for non-systemd initramfs on
  Void Linux (and the idea to use ACLs)
- [@wolegis][gh4] — mkinitcpio-systemd-extras, inspiration for the systemd hook

[gh1]: https://github.com/tavianator
[gh2]: https://github.com/karepker
[gh3]: https://github.com/classabbyamp
[gh4]: https://github.com/wolegis
[1]: https://wiki.archlinux.org/title/Mkinitcpio
[2]: https://tailscale.com
[3]: https://wiki.archlinux.org/title/dm-crypt/Encrypting_an_entire_system#Configuring_mkinitcpio_2
[4]: https://wiki.archlinux.org/title/Dm-crypt/Specialties#Remote_unlocking_of_root_(or_other)_partition

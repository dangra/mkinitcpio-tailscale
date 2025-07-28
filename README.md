# mkinitcpio-tailscale

This project provides a [mkinitcpio][1] hook that allows you to connect to
your [Tailscale][2] network during the boot process from within the initramfs
(the early userspace environment, just before the system switches to the
final root filesystem).

It’s particularly useful for remotely unlocking systems with encrypted root
filesystems. For setup, see the Archlinux Wiki for details on configuring
mkinitcpio to [decrypt the rootfs][3] on boot and how to add an SSH server to
[remotely unlock it][4]. You don't need to install any additional SSH server
if you use the built-in tailscale SSH server, continue reading for details.

[1]: https://wiki.archlinux.org/title/Mkinitcpio
[2]: https://tailscale.com
[3]: https://wiki.archlinux.org/title/dm-crypt/Encrypting_an_entire_system#Configuring_mkinitcpio_2
[4]: https://wiki.archlinux.org/title/Dm-crypt/Specialties#Remote_unlocking_of_root_(or_other)_partition

By combining mkinitcpio with Tailscale, you gain a secure VPN connection to
access your locked server from anywhere. No need to expose SSH to the internet
or open firewall ports beyond your home.

## Installation

You can install the
[mkinitcpio-tailscale](https://aur.archlinux.org/packages/mkinitcpio-tailscale)
package from the AUR with your preferred helper, for example:

```sh
yay -S mkinitcpio-tailscale
```

## Configure

Run `setup-initcpio-tailscale` and follow the prompts. This will register a
new Tailscale node using a hostname based on your system. If your host is
named `homeserver`, the Tailscale node will appear as `homeserver-initrd`.
This makes it easy to identify your node in the Tailscale admin panel.

Next, edit `/etc/mkinitcpio.conf`` and add`tailscale` to HOOKS array.

* For systemd-based initramfs, you can place the `tailscale` hook anywhere
  after the `systemd` hook.

* For busybox-based initramfs, add it after any network-related hooks but
  before blocking hooks like `encrypt` or `encryptssh`.

### Tailscale SSH server

The Tailscale daemon has a built-in SSH server. If enabled, you don’t need to
install `dropbear` or `tinyssh` to remotely access your node.

To enable the built-in SSH server, use the `--ssh` flag:

`setup-initcpio-tailscale --ssh`

Unlike traditional SSH servers such as `dropbear` or `tinyssh`, the Tailscale
SSH server only accepts connections from your tailnet. The node won’t allow
local connections unless the client is also part of your Tailscale network,
providing an extra layer of security.

## Security Considerations

The Tailscale node key is stored in plaintext inside the initramfs. Even if
your root filesystem is encrypted, the initramfs itself usually isn’t.
Physical access to the machine could allow an attacker to steal the Tailscale
keys and impersonate your node on the Tailscale network.

To mitigate risk, restrict the initramfs Tailscale node to only accept
incoming connections by setting up Tailscale [ACLs][ts-acls] and tagging your clients,
servers, and initrd nodes in the [Machines panel][ts-panel].

[ts-acls]: https://login.tailscale.com/admin/acls
[ts-panel]: https://login.tailscale.com/admin/machines

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

  ssh: [
    {
        "action": "accept",
        "src":    ["tag:client"],
        "dst":    ["tag:initrd"],
        "users":  ["autogroup:nonroot", "root"],
    },
  ],
}
```

Even if an attacker obtains your node keys, these restrictions will prevent
them from accessing the rest of your Tailscale network. Other nodes will
remain protected.

## Prior work and big thanks

* [@tavianator][gh1] and his early work on
  <https://gist.github.com/tavianator/6b00355cedae0b2ceb338e43ce8e5c1a>
* [@karepker][gh2] for a very detailed rootfs unlocking on
  [Raspeberry Pi + Archlinux](https://karepker.com/raspberry-pi/)
* [@classabbyamp][gh3] for a similar
  [mkinitcpio hook](https://github.com/classabbyamp/mkinitcpio-tailscale) for
  non systemd initramfs on Void Linux. Also for the tailscale ACLs idea!
* [@wolegis][gh4] for
  [mkinitcpio-systemd-extras](https://github.com/wolegis/mkinitcpio-systemd-extras/)
  that served as major inspiration for my systemd hook

[gh1]: https://github.com/tavianator
[gh2]: https://github.com/karepker
[gh3]: https://github.com/classabbyamp
[gh4]: https://github.com/wolegis

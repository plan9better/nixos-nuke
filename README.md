# nixos-nuke

A single-purpose NixOS configuration that, when booted, **wipes every NVMe disk**
(`wipefs` + `sgdisk --zap-all` + `blkdiscard -f`) from the initrd — *before* any
root filesystem is mounted — then hard-reboots. With the ESP gone, the machine
falls through to PXE.

It runs from a **tmpfs root**, so it depends on no disk and can erase the very
device it was installed on.

## Usage

On the target node:

```sh
sudo nixos-rebuild boot --flake github:plan9better/nixos-nuke#nuke
sudo reboot
```

Or remotely (no need to SSH in first):

```sh
nixos-rebuild boot --flake github:plan9better/nixos-nuke#nuke \
  --target-host operator@<ip> --use-remote-sudo
# then: ssh operator@<ip> sudo reboot
```

`nixos-rebuild boot` sets this as the **default** boot entry (tagged
`NUKE-EVERYTHING`) without activating it now — the wipe only happens on the next
reboot. Keep BMC/console access as a backstop in case PXE doesn't catch.

## Scope / caveats

- **NVMe only.** Spinning HDDs (e.g. Ceph OSDs) are *not* touched — TRIM isn't
  supported on them anyway. Wipe those separately (`ceph-volume lvm zap
  --destroy`, or zero the BlueStore label offsets `0/1G/10G/100G/1000G`).
- **Irreversible.** `blkdiscard` drops all blocks; on SSD/NVMe the data is gone.
- For a controller-level crypto erase instead of a best-effort TRIM, uncomment
  the `nvme format ... --ses=1` line in `flake.nix`.
- Pinned to `nixos-24.11`. Run `nix flake update` if you want newer nixpkgs.

# nixos-nuke

A single-purpose NixOS configuration that, when booted, **wipes every disk** —
NVMe SSDs *and* SAS/SATA HDDs — from the initrd, *before* any root filesystem is
mounted, then hard-reboots. With the ESP gone, the machine falls through to PXE.

Per disk it: tears down LVM/md/swap holders (`vgchange -an`, `dmsetup
remove_all`), zeroes the Ceph BlueStore label offsets (`0/1G/10G/100G/1000G`,
so `ceph-volume raw list` comes back empty), then `wipefs -a` +
`sgdisk --zap-all` + `blkdiscard -f`.

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

## Ceph teardown (optional, run on the live node first)

The initrd's block-level zeroing already destroys BlueStore OSDs, raw or
LV-backed — but `ceph-volume` can't run in a stage-1 initrd (needs python, the
ceph stack, and active LVM). If you want a clean ceph-side teardown *before*
nuking, run this on the live node:

```sh
sudo nix run github:plan9better/nixos-nuke#ceph-zap
```

It reads `ceph-volume raw list` and, for each OSD device it finds (whether on an
NVMe LV or a raw `/dev/sd*`), runs `ceph-volume lvm zap --destroy`. Idempotent:
a clean node just prints `no raw OSDs`.

## Scope / caveats

- **All whole disks** matching `/dev/nvme*` and `/dev/sd*` are wiped. The SAS
  HBAs the OSD HDDs hang off of are covered by `mpt3sas`/`megaraid_sas` in the
  initrd; add your controller's module to `availableKernelModules` if a disk
  doesn't show up.
- **HDDs** get no TRIM (`blkdiscard` no-ops), but the BlueStore label zeroing +
  `sgdisk`/`wipefs` still fully clear them for Ceph re-provisioning.
- **Irreversible.** On SSD/NVMe `blkdiscard` drops all blocks; the data is gone.
- For a controller-level crypto erase instead of a best-effort TRIM, uncomment
  the `nvme format ... --ses=1` line in `flake.nix`.
- Pinned to `nixos-24.11`. Run `nix flake update` if you want newer nixpkgs.

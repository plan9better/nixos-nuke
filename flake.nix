{
  description = "Boot-to-wipe: `nixos-rebuild boot` this, reboot, and every NVMe is TRIMmed before root mounts -> then PXE.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs =
    { self, nixpkgs }:
    {
      nixosConfigurations.nuke = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          (
            { pkgs, ... }:
            {
              system.stateVersion = "24.11";
              system.nixos.tags = [ "NUKE-EVERYTHING" ]; # tags the boot entry

              # Runs entirely from RAM: depends on no disk, so it can safely wipe
              # the very disk it was installed on.
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };

              # `nixos-rebuild boot` installs into the machine's existing ESP.
              boot.loader.systemd-boot.enable = true;
              boot.loader.efi.canTouchEfiVariables = true;

              # Ensure the NVMe controllers are visible to the initrd.
              boot.initrd.availableKernelModules = [
                "nvme"
                "nvme_core"
                "xhci_pci"
                "ahci"
                "sd_mod"
              ];
              boot.initrd.kernelModules = [ "nvme" ];

              # The initrd.systemd.* options require the systemd-based initrd.
              boot.initrd.systemd.enable = true;
              boot.initrd.systemd.initrdBin = with pkgs; [
                util-linux
                gptfdisk
                nvme-cli
                lvm2
                mdadm
              ];

              boot.initrd.systemd.services.nuke = {
                description = "Wipe all NVMe disks and die";
                wantedBy = [ "initrd.target" ];
                after = [ "systemd-udevd.service" ];
                before = [
                  "initrd-root-device.target"
                  "sysroot.mount"
                ];
                unitConfig.DefaultDependencies = false;
                serviceConfig.Type = "oneshot";
                script = ''
                  udevadm settle

                  # Release anything udev auto-activated (LVM/md/swap) so it can't
                  # hold a device O_EXCL and block the discard.
                  swapoff -a          2>/dev/null || true
                  vgchange -an        2>/dev/null || true
                  mdadm --stop --scan 2>/dev/null || true
                  dmsetup remove_all  2>/dev/null || true

                  for sys in /sys/block/nvme*; do
                    [ -e "$sys" ] || continue
                    DISK="/dev/$(basename "$sys")"
                    echo "nuking $DISK"
                    wipefs -a "$DISK"        || true
                    sgdisk --zap-all "$DISK" || true
                    blkdiscard -f "$DISK"    || true
                    # nvme format "$DISK" --ses=1 --force   # crypto secure-erase, if wanted
                  done

                  sync
                  echo b > /proc/sysrq-trigger # hard reboot -> no ESP -> PXE
                '';
              };
            }
          )
        ];
      };
    };
}

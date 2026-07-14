{
  description = "Boot-to-wipe: `nixos-rebuild boot` this, reboot, and every disk (NVMe + SAS/SATA) is zapped -- partition tables, LVM, and Ceph BlueStore labels -- before root mounts, then PXE.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.nuke = nixpkgs.lib.nixosSystem {
        inherit system;
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

              # Make every disk controller visible to the initrd: NVMe, AHCI
              # (SATA), and the SAS HBAs the Ceph OSD HDDs hang off of
              # (mpt3sas = Broadcom SAS38xx, megaraid_sas for LSI/MegaRAID).
              boot.initrd.availableKernelModules = [
                "nvme"
                "nvme_core"
                "xhci_pci"
                "ahci"
                "sd_mod"
                "mpt3sas"
                "megaraid_sas"
              ];
              boot.initrd.kernelModules = [ "nvme" ];

              # The initrd.systemd.* options require the systemd-based initrd.
              boot.initrd.systemd.enable = true;
              boot.initrd.systemd.initrdBin = with pkgs; [
                util-linux # wipefs, blkdiscard, swapoff, lsblk
                coreutils # dd, sync, basename, stat
                gptfdisk # sgdisk
                nvme-cli # nvme
                lvm2 # vgchange
                mdadm # mdadm
              ];

              boot.initrd.systemd.services.nuke = {
                description = "Zap every disk (tables, LVM, Ceph BlueStore) and die";
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
                  # hold a device O_EXCL and block the discard/zap.
                  swapoff -a          2>/dev/null || true
                  vgchange -an        2>/dev/null || true
                  mdadm --stop --scan 2>/dev/null || true
                  dmsetup remove_all  2>/dev/null || true

                  # Ceph BlueStore keeps a device label at offset 0 and, on newer
                  # releases, mirror copies at 1G/10G/100G/1000G. `ceph-volume raw
                  # list` finds an OSD by reading that offset-0 label, so zeroing
                  # these ranges is a full zap at the block level -- it works for
                  # raw OSDs sitting directly on the SAS HDDs (/dev/sd*), where
                  # TRIM does nothing, as well as for LV-backed OSDs on the NVMe
                  # (whose underlying PV we wipe here too). We do NOT run
                  # ceph-volume itself: it needs python + the ceph stack + active
                  # LVM, none of which belong in a stage-1 initrd. Use the
                  # `ceph-zap` app (below) on a live node if you want a clean
                  # ceph-side teardown before nuking.
                  zap_bluestore_labels() {
                    dev="$1"
                    for off_gib in 0 1 10 100 1000; do
                      # 4 MiB is comfortably larger than any BlueStore label.
                      # dd past end-of-device just fails -> ignored.
                      dd if=/dev/zero of="$dev" bs=1M count=4 \
                         seek=$(( off_gib * 1024 )) oflag=direct conv=fsync \
                         2>/dev/null || true
                    done
                  }

                  # Every whole disk: NVMe SSDs and SAS/SATA HDDs (the Ceph OSDs).
                  for sys in /sys/block/nvme* /sys/block/sd*; do
                    [ -e "$sys" ] || continue
                    DISK="/dev/$(basename "$sys")"
                    echo "nuking $DISK"
                    zap_bluestore_labels "$DISK"      # kill Ceph OSD detection
                    wipefs -a "$DISK"        || true  # fs/partition signatures
                    sgdisk --zap-all "$DISK" || true  # GPT primary + backup
                    blkdiscard -f "$DISK"    || true  # TRIM (SSD/NVMe; no-op HDD)
                    # nvme format "$DISK" --ses=1 --force  # crypto erase, if wanted
                  done

                  sync
                  echo b > /proc/sysrq-trigger # hard reboot -> no ESP -> PXE
                '';
              };
            }
          )
        ];
      };

      # Live-system Ceph teardown: run this on a node BEFORE nuking to zap OSDs
      # the ceph-volume way (drops LVs, wipes labels, deallocates). Reads
      # `ceph-volume raw list`; if it finds OSDs, zaps each device. Idempotent --
      # a clean node just prints "no raw OSDs".
      #   nix run github:plan9better/nixos-nuke#ceph-zap
      packages.${system}.ceph-zap = pkgs.writeShellApplication {
        name = "ceph-zap";
        runtimeInputs = with pkgs; [
          ceph
          jq
          lvm2
          util-linux
        ];
        text = ''
          if [ "$(id -u)" -ne 0 ]; then echo "run as root" >&2; exit 1; fi

          list="$(ceph-volume raw list 2>/dev/null || echo '{}')"
          mapfile -t devices < <(echo "$list" | jq -r '.[].device' | sort -u)

          if [ "''${#devices[@]}" -eq 0 ]; then
            echo "no raw OSDs found by ceph-volume; nothing to zap"
            exit 0
          fi

          echo "found ''${#devices[@]} OSD device(s):"
          printf '  %s\n' "''${devices[@]}"

          for dev in "''${devices[@]}"; do
            echo "==> ceph-volume lvm zap --destroy $dev"
            ceph-volume lvm zap --destroy "$dev" || ceph-volume lvm zap "$dev" || true
          done

          echo "== ceph-volume raw list after zap =="
          ceph-volume raw list
        '';
      };
      apps.${system}.ceph-zap = {
        type = "app";
        program = "${self.packages.${system}.ceph-zap}/bin/ceph-zap";
      };
    };
}

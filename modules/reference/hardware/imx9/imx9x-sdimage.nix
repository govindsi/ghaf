# SPDX-FileCopyrightText: 2025 TII (SSRC) and the Ghaf contributors
#
# SPDX-License-Identifier: Apache-2.0

{
  config,
  pkgs,
  modulesPath,
  lib,
  target ? "imx95",   # explicit target argument, default to imx95
  ...
}: let
  # pick the boot package dynamically from pkgs (e.g. pkgs.imx93-boot or pkgs.imx95-boot)
  imxBootAttr = "${target}-boot";
  imxBootPkg = if builtins.hasAttr imxBootAttr pkgs
               then builtins.getAttr imxBootAttr pkgs
               else builtins.getAttr "imx95-boot" pkgs;  # fallback

  rootfsImage = pkgs.callPackage ./make-ext4-fs.nix ({
      inherit (config.sdImage) storePaths;
      compressImage = config.sdImage.compressImage;
      populateImageCommands = config.sdImage.populateRootCommands;
      volumeLabel = "NIXOS_SD";
    }
    // lib.optionalAttrs (config.sdImage.rootPartitionUUID != null) {
      uuid = config.sdImage.rootPartitionUUID;
    });
in
  with lib; {
    imports = [
      (mkRemovedOptionModule ["sdImage" "bootPartitionID"] "The FAT partition for SD image now only holds the boot firmware files. Use firmwarePartitionID to configure that partition's ID.")
      (mkRemovedOptionModule ["sdImage" "bootSize"] "The boot files for SD image have been moved to the main ext4 partition. The FAT partition now only holds the boot firmware files. Changing its size may not be required.")
    ];

    options.sdImage = {
      imageName = mkOption {
        default = "nixos_${target}.img";
        description = ''
          Name of the generated image file.
        '';
      };

      storePaths = mkOption {
        type = with types; listOf package;
        example = literalExpression "[ pkgs.stdenv ]";
        description = ''
          Derivations to be included in the Nix store in the generated SD image.
        '';
      };

      rootPartitionUUID = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "14e19a7b-0ae0-484d-9d54-43bd6fdc20c7";
        description = ''
          UUID for the filesystem on the main NixOS partition on the SD card.
        '';
      };

      rootfsLabelPath = mkOption {
        type = types.str;
        default = "/dev/disk/by-label/NIXOS_SD";
        description = ''
          Name of the filesystem which holds the rootfs.
        '';
      };

      populateFirmwareCommands = mkOption {
        example = literalExpression "'' cp \${pkgs.myBootLoader}/u-boot.bin firmware/ ''";
        default = ''
          echo "Using firmware package: ${imxBootAttr}"
          cp ${imxBootPkg}/image/flash.bin .
          chmod 0644 flash.bin
          mv flash.bin firmware
        '';
        description = ''
          Shell commands to populate the ./firmware directory.
          All files in that directory are copied to the
          /boot/firmware partition on the SD image.
        '';
      };

      populateRootCommands = mkOption {
        example = literalExpression "''\${config.boot.loader.generic-extlinux-compatible.populateCmd} -c \${config.system.build.toplevel} -d ./files/boot''";
        default = ''
          mkdir -p ./files/boot
          ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot

          dtbPath=$(echo ./files/boot/nixos/*-dtbs-filtered)
          chmod +w $dtbPath

          # Provide a link to dtbs to avoid hash value
          cd ./files/boot/nixos
          ln -s ./*dtbs-filtered ./dtbs-filtered
          cd /
        '';
        description = ''
          Shell commands to populate the ./files directory.
          All files in that directory are copied to the
          root (/) partition on the SD image. Use this to
          populate the ./files/boot (/boot) directory.
        '';
      };

      postBootCommands = mkOption {
        example = literalExpression "''\${config.boot.loader.generic-extlinux-compatible.populateCmd} -c \${config.system.build.toplevel} -d ./files/boot''";
        default = ''
          if [ -f ${config.sdImage.nixPathRegistrationFile} ]; then
            set -euo pipefail
            set -x

            # Figure out device names for the boot device and root filesystem.
            rootPart=$(${pkgs.util-linux}/bin/findmnt -n -o SOURCE /)
            bootDevice=$(lsblk -npo PKNAME $rootPart)

            # Fails when SDcard is present
            # lsblk outputs id 98 that can not be processed by sfdisk
            # hardcoding
            #partNum=$(lsblk -npo MAJ:MIN $rootPart | ${pkgs.gawk}/bin/awk -F: '{print $2}')
            partNum=1

            # Resize the root partition and the filesystem to fit the disk
            echo ",+," | sfdisk -N$partNum --no-reread $bootDevice
            ${pkgs.parted}/bin/partprobe
            ${pkgs.e2fsprogs}/bin/resize2fs $rootPart

            # Register the contents of the initial Nix store
            ${config.nix.package.out}/bin/nix-store --load-db < ${config.sdImage.nixPathRegistrationFile}

            # nixos-rebuild also requires a "system" profile and an /etc/NIXOS tag.
            touch /etc/NIXOS
            ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system

            # Prevents this from running on later boots.
            rm -f ${config.sdImage.nixPathRegistrationFile}
          fi
        '';
        description = ''
          Shell commands to run during boot
        '';
      };

      postBuildCommands = mkOption {
        default = ''
          echo "Writing flash.bin for i.MX${target} BootROM..."
          dd if=firmware/flash.bin of=$img bs=1K seek=32 conv=notrunc,sync

          echo "Dumping hexdump for verification..."
          mkdir -p $out
          hexdump -C -n 512 -s $((32*1024)) $img > $out/flashbin-dump.txt
          cp firmware/flash.bin $out/flash.bin
        '';
      };

      imageBuildCommands = mkOption {
        example = literalExpression "'' dd if=\${pkgs.myBootLoader}/SPL of=$img bs=1024 seek=1 conv=notrunc ''";
        default = ''
          mkdir -p $out/nix-support
          export img=$out/${config.sdImage.imageName}

          echo "${pkgs.stdenv.buildPlatform.system}" > $out/nix-support/system
          if test -n "$compressImage"; then
            echo "file sd-image $img.zst" >> $out/nix-support/hydra-build-products
          else
            echo "file sd-image $img" >> $out/nix-support/hydra-build-products
          fi

          root_fs=${rootfsImage}
          ${lib.optionalString config.sdImage.compressImage ''
            root_fs=./root-fs.img
            echo "Decompressing rootfs image"
            zstd -d --no-progress "${rootfsImage}" -o $root_fs
          ''}

          # Create the image file sized to fit / plus slack for the gap.
          rootsize=$(du -B 512 --apparent-size $root_fs | awk '{ print $1 }')
          blocksize=512
          #rootoffset=64
          rootoffset=8192

          imagesize=$(((rootoffset + rootsize)*blocksize))
          truncate -s $imagesize $img

          # type=b is 'W95 FAT32', type=83 is 'Linux'.
          # The "bootable" partition is where u-boot will look file for the bootloader
          # information (dtbs, extlinux.conf file).
          sfdisk --no-reread --no-tell-kernel $img <<EOF
              label: dos
              label-id: 0x2178694e
              unit: sectors
              sector-size: 512

              start=$rootoffset, size=$rootsize, type=83, bootable
          EOF
          echo $PWD
          ls

          # Populate the files intended for /boot/firmware
          mkdir -p firmware
          ${config.sdImage.populateFirmwareCommands}

          # Copy the rootfs and uboot into the SD image
          eval $(partx $img -o START,SECTORS --nr 1 --pairs)
          dd conv=notrunc if=$root_fs of=$img seek=$START count=$SECTORS

          ${config.sdImage.postBuildCommands}

          if test -n "$compressImage"; then
              zstd -T$NIX_BUILD_CORES --rm $img
          fi

          # Provide U-Boot image in output for flashing
          cp firmware/flash.bin $out/boot.img
        '';
        description = ''
          Shell commands to assemble image
        '';
      };

      compressImage = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the SD image should be compressed using
          {command}`zstd`.
        '';
      };

      nixPathRegistrationFile = mkOption {
        type = types.str;
        default = "/nix-path-registration";
        description = ''
          Location of the file containing the input for nix-store --load-db once the machine has booted.
          If overriding fileSystems."/" then you should to set this to the root mount + /nix-path-registration
        '';
      };
    };

    config = {
      fileSystems = {
        "/" = {
          device = "${config.sdImage.rootfsLabelPath}";
          fsType = "ext4";
        };
      };

      sdImage = {
        storePaths = [config.system.build.toplevel];
        compressImage = false;
      };

      system.build.sdImage = pkgs.callPackage ({
        stdenv,
        dosfstools,
        e2fsprogs,
        mtools,
        libfaketime,
        util-linux,
        zstd,
      }:
        stdenv.mkDerivation {
          name = config.sdImage.imageName;

          nativeBuildInputs =
            [dosfstools e2fsprogs libfaketime mtools util-linux]
            ++ lib.optional config.sdImage.compressImage zstd;

          inherit (config.sdImage) imageName compressImage;

          buildCommand = ''
            # Populate the files intended for /boot/firmware
            mkdir firmware
            ${config.sdImage.populateFirmwareCommands}

            # Assemble image
            ${config.sdImage.imageBuildCommands}
          '';
        }) {};

      boot.postBootCommands = ''
        ${config.sdImage.postBootCommands}
      '';
    };
  }


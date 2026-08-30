# Alienware 15 R1 Bazzite

A personal bootc image derived from
[`ublue-os/bazzite-nvidia:stable`](https://github.com/ublue-os/bazzite),
configured and validated for the **Alienware 15 R1** with Intel hybrid graphics
and an NVIDIA GeForce GTX 970M.

This repository is not an official Bazzite or Universal Blue product, and the
image is not intended to be a generic build for arbitrary computers. It is
published as a hardware-specific example and template. Drivers, storage and
encryption must be reviewed before adapting it to another machine.

## Goals

- Preserve Bazzite's atomic updates and rollback support.
- Keep Intel as the desktop GPU while retaining NVIDIA render offload.
- Provide a deterministic, declarative initramfs for this laptop.
- Include the tested system customizations in the deployment.
- Keep machine-specific storage and optional initramfs optimization local.

## Image customizations

The image adds:

- NordVPN CLI and GUI, with `nordvpnd.service` enabled.
- ChatGPT for Linux.
- VeraCrypt, downloaded from its official release with a pinned version and
  SHA-256 digest.
- The ACPI S4 backend used as a compatible power-off action, including its
  systemd service, Polkit rule and application launcher.
- A disabled `nvidia-persistenced.service`.

The image provisions and activates an 8 GiB swapfile at
`/var/swap/hibernation.swap` for the compatible power-off backend. The unit is
idempotent: it creates the persistent file in `/var` only when it is absent,
then validates its resume offset and minimum size before activation. An
existing valid file is preserved. The deployment uses `noresume`, so the next
boot remains a clean boot.

No disk layout, partition, LUKS mapper, filesystem UUID or Btrfs subvolume is
encoded in the image. At runtime the S4 backend derives the resume block device
and offset from the swapfile itself. The persistent swap path must be backed by
Btrfs; other filesystems fail safely instead of using an uncertain resume
offset.


## Declarative initramfs

The published image builds an initramfs from explicit Dracut-module and
kernel-driver inventories derived from the known-good 44 MiB initramfs on the
Alienware 15 R1. Generation uses `--no-hostonly`: the result must not depend on
the hardware or storage topology of the GitHub Actions runner.

The contract includes Intel graphics, USB and SATA storage, Btrfs, OSTree,
device-mapper, LUKS/systemd-cryptsetup, Plymouth and the complete console
keymap set. Validation rejects NVIDIA, Nouveau and AMDGPU kernel modules as
well as crypttab, machine identity, connection profiles, keyfiles and private
keys. Disk and removable-key UUIDs remain deployment-specific kernel
arguments. NVIDIA remains available after switch-root through
PRIME/switcheroo offload.

## Updates

The GitHub Actions workflow:

- builds and publishes the image on every push to `main`;
- performs a scheduled build every day;
- pulls the current Bazzite `stable` base;
- builds and validates the declarative initramfs for the current base kernel;
- publishes `ghcr.io/0t4k0n/alienware-15-r1-bazzite:latest`;
- signs the published digest with Cosign.

An update is not considered publishable unless the build, bootc lint,
initramfs validation, registry push and signature all succeed.

## Verification before use

A successful workflow does not replace testing on the laptop. Before rebasing,
verify at least:

1. the GitHub Actions run completed successfully;
2. the GHCR image digest;
3. the Cosign signature using this repository's public key;
4. the published image contains the expected packages and initramfs;
5. a previous Bazzite deployment remains available for rollback.

The workflow never rebases a machine automatically.

## Sources and acknowledgements

This project is based on
[`ublue-os/image-template`](https://github.com/ublue-os/image-template) and uses
Bazzite as its base image. The licenses of those projects and of the included
packages continue to apply.

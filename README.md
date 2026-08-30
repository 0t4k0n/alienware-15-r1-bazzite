# Alienware 15 R1 Bazzite

A personal bootc image derived from
[`ublue-os/bazzite-nvidia:stable`](https://github.com/ublue-os/bazzite),
configured and validated for the **Alienware 15 R1** with Intel hybrid graphics
and an NVIDIA GeForce GTX 970M.

This repository is not an official Bazzite or Universal Blue product, and the
image is not intended to be a generic build for arbitrary computers. It is
published as a hardware-specific example and template. Drivers, storage,
encryption and initramfs checks must be reviewed before adapting it to another
machine.

## Goals

- Preserve Bazzite's atomic updates and rollback support.
- Keep Intel as the desktop GPU while retaining NVIDIA render offload.
- Provide a small, deterministic initramfs for this laptop.
- Include the tested system customizations in the deployment.
- Avoid RPM overlays and local initramfs regeneration after each update.

## Image customizations

The image adds:

- NordVPN CLI and GUI, with `nordvpnd.service` enabled.
- ChatGPT for Linux.
- VeraCrypt, downloaded from its official release with a pinned version and
  SHA-256 digest.
- The ACPI S4 backend used as a compatible power-off action, including its
  systemd service, Polkit rule and application launcher.
- Italian virtual-console configuration.
- A disabled `nvidia-persistenced.service`.


## Alienware initramfs

Every build generates an initramfs for this model. Dracut uses strict host-only
generation, while the hardware and storage stack required by the laptop is
explicitly forced and the resulting image is validated before publication.

The checks require or account for:

- Intel `i915`.
- USB controllers, `usb-storage` and UAS.
- SATA/AHCI and SCSI disk support.
- Btrfs, device-mapper, LUKS and systemd-cryptsetup.
- The Italian console keymap.

The build rejects an initramfs containing:

- NVIDIA, Nouveau or AMDGPU kernel modules.
- NetworkManager connection profiles.
- Machine-specific keyfiles or private keys.

The build also fails if the initramfs exceeds 80 MiB. NVIDIA remains fully
available after switch-root through PRIME/switcheroo offload.

## Updates

The GitHub Actions workflow:

- builds and publishes the image on every push to `main`;
- performs a scheduled build every day;
- pulls the current Bazzite `stable` base;
- rebuilds and validates the initramfs for the new base kernel;
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

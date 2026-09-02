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
- Provide a reduced, declarative initramfs for this laptop.
- Include the tested system customizations in the deployment.

## Image customizations

The image adds:

- A system-wide ACPI S4 power-off workaround for the Alienware firmware/EC
  shutdown bug.
- A disabled `nvidia-persistenced.service`.

This model can fail to complete a conventional ACPI poweroff because of a
firmware/Embedded Controller issue also observable under Windows, where Fast
Startup normally avoids the affected full-shutdown path. The image works
around it by replacing the normal system poweroff backend with a custom,
disposable S4 transition. It writes only the state required to reach S4 and
uses `noresume`, so the next power-on is always a clean boot. The replacement
is system-wide: Plasma, SDDM, logind and ordinary command-line poweroff requests
all follow the same reliable path, while reboot and suspend remain unchanged.
`noresume` is a deployment kernel-argument requirement rather than an image
default; the backend checks it before touching the running session and fails
safely when it is absent.
Because the Btrfs swapfile must remain mounted, this path cannot traverse
systemd's normal `final.target`/`umount.target` sequence. Before entering S4 it
therefore detects any staged atomic update and invokes exactly the active
OSTree or bootc finalizer through its upstream systemd service. It aborts S4 if
finalization cannot be confirmed, then flushes the journal and filesystems
before touching the graphical session.


## Declarative initramfs

The published image includes a reduced, declarative initramfs tailored to the
Alienware 15 R1 boot hardware. It contains the required Intel graphics,
storage, Btrfs, OSTree, LUKS and Plymouth support without depending on the
GitHub Actions runner or embedding machine-specific storage identifiers and
keys. NVIDIA remains available after switch-root through PRIME render offload.

## Updates

The GitHub Actions workflow:

- builds and publishes the image on every push to `main`;
- performs a scheduled build every day;
- pulls the current Bazzite `stable` base;
- preserves the corresponding Bazzite build version in the derived image;
- builds and validates the declarative initramfs for the current base kernel;
- publishes `ghcr.io/0t4k0n/alienware-15-r1-bazzite:latest`;
- signs the published digest with Cosign.

The image installs its public signing key and a scoped containers policy so
that deployments can follow the signed image reference after the initial
explicit bootstrap.

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

#!/usr/bin/bash

set -euo pipefail
set -x

readonly VERACRYPT_VERSION="1.26.29"
readonly VERACRYPT_RELEASE="Fedora-44"
readonly VERACRYPT_RPM="veracrypt-${VERACRYPT_VERSION}-${VERACRYPT_RELEASE}-x86_64.rpm"
readonly VERACRYPT_URL="https://github.com/veracrypt/VeraCrypt/releases/download/VeraCrypt_${VERACRYPT_VERSION}/${VERACRYPT_RPM}"
readonly VERACRYPT_SHA256="ff6b9b4a84a546c6a6fbc0c58ac1074fc6252cae8398f52b57ff360a3cbc312e"
readonly VERACRYPT_KEY_URL="https://amcrypto.jp/VeraCrypt/VeraCrypt_PGP_public_key.asc"
readonly UPSTREAM_POWEROFF_UNIT=/usr/lib/systemd/system/systemd-poweroff.service

for required_command in \
    blkid btrfs findmnt journalctl jq lsblk ostree restorecon swapon systemctl; do
    command -v "${required_command}" >/dev/null
done

# This image intentionally replaces systemd's poweroff implementation. Record
# its upstream version and stop publication if systemd changes the structural
# responsibilities on which the reviewed replacement is based. Comments,
# descriptions and directive ordering do not affect this check.
systemctl --version
sha256sum "${UPSTREAM_POWEROFF_UNIT}"
sed -n '1,160p' "${UPSTREAM_POWEROFF_UNIT}"

grep -Fxq 'DefaultDependencies=no' "${UPSTREAM_POWEROFF_UNIT}"
grep -Fxq 'SuccessAction=poweroff-force' "${UPSTREAM_POWEROFF_UNIT}"

upstream_requires="$({ sed -n 's/^Requires=//p' "${UPSTREAM_POWEROFF_UNIT}"; } | tr '\n' ' ')"
upstream_after="$({ sed -n 's/^After=//p' "${UPSTREAM_POWEROFF_UNIT}"; } | tr '\n' ' ')"
for dependency in shutdown.target umount.target final.target; do
    if [[ " ${upstream_requires} " != *" ${dependency} "* || \
          " ${upstream_after} " != *" ${dependency} "* ]]; then
        printf 'Upstream systemd poweroff contract changed around %s; review the S4 replacement before publishing\n' \
            "${dependency}" >&2
        exit 1
    fi
done

# Files that are part of the bootable image. Personal Plasma configuration is
# deliberately left in the user's home.
cp -avf /ctx/system_files/. /

# The S4 backend bypasses final.target because its Btrfs swapfile must remain
# mounted. Require the guarded upstream-finalizer path that preserves staged
# atomic updates before the graphical session and swap configuration are
# touched.
grep -Fq 'ostree admin status --json' \
    /usr/libexec/alienware-compatible-poweroff
grep -Fq 'ostree-finalize-staged.service' \
    /usr/libexec/alienware-compatible-poweroff
grep -Fq 'bootc-finalize-staged.service' \
    /usr/libexec/alienware-compatible-poweroff
grep -Fq '/usr/bin/journalctl --sync' \
    /usr/libexec/alienware-compatible-poweroff

# Phase A: remove complete hardware/application stacks that are unrelated to
# this machine. Resolve the installed subset at build time so an upstream
# package rename/removal does not break publication merely because an obsolete
# name is no longer present.
readonly -a PHASE_A_REMOVE_PACKAGES=(
    # Android container and web administration.
    waydroid waydroid-selinux lxc lxc-libs lxc-templates lxcfs
    cockpit-bridge cockpit-files cockpit-networkmanager cockpit-podman
    cockpit-selinux cockpit-storaged cockpit-system

    # Drivers and helpers for hardware not present in the Alienware 15 R1.
    framework-laptop-kmod-common framework-system fw-ectool fw-fanctrl
    kmod-framework-laptop
    hid-fanatecff hid-fanatecff-akmod-modules kmod-hid-fanatecff
    hid-tmff2 hid-tmff2-akmod-modules kmod-hid-tmff2
    kvmfr kmod-kvmfr
    nct6687d kmod-nct6687d
    openrazer-kmod-common kmod-openrazer
    ryzen_smu ryzen_smu-akmod-modules kmod-ryzen_smu ryzenadj
    sc0710 kmod-sc0710
    system76-driver system76-io kmod-system76-driver kmod-system76-io
    t150-driver kmod-t150-driver
    zenergy zenergy-akmod-modules kmod-zenergy
)

phase_a_installed=()
for package in "${PHASE_A_REMOVE_PACKAGES[@]}"; do
    if rpm --quiet -q "${package}"; then
        phase_a_installed+=("${package}")
    fi
done
if ((${#phase_a_installed[@]})); then
    dnf5 remove --no-autoremove -y "${phase_a_installed[@]}"
fi
for package in "${PHASE_A_REMOVE_PACKAGES[@]}"; do
    if rpm --quiet -q "${package}"; then
        printf 'Phase A package unexpectedly remains installed: %s\n' \
            "${package}" >&2
        exit 1
    fi
done

# These integrations are copied into Bazzite independently of their RPMs and
# would otherwise advertise commands or hardware support that no longer exists.
rm -f \
    /etc/default/waydroid-launcher \
    /etc/yum.repos.d/tailscale.repo \
    /usr/bin/waydroid-choose-gpu \
    /usr/bin/waydroid-launcher \
    /usr/libexec/waydroid-container-restart \
    /usr/libexec/waydroid-container-start \
    /usr/libexec/waydroid-container-stop \
    /usr/libexec/waydroid-fix-controllers \
    /usr/lib/systemd/system/cockpit.service \
    /usr/lib/udev/rules.d/50-framework-inputmodule.rules \
    /usr/lib/udev/rules.d/50-framework16.rules \
    /usr/share/applications/waydroid-container-restart.desktop \
    /usr/share/fish/completions/waydroid.fish \
    /usr/share/polkit-1/actions/org.bazzite.waydroid.policy \
    /usr/share/polkit-1/rules.d/30-waydroid.rules \
    /usr/share/ublue-os/just/82-bazzite-cockpit.just \
    /usr/share/ublue-os/just/82-bazzite-waydroid.just \
    /usr/share/ublue-os/udev-rules/50-framework-inputmodule.rules \
    /usr/share/ublue-os/udev-rules/50-framework16.rules
rm -rf \
    /usr/lib/waydroid \
    /usr/share/applications/Waydroid
for removed_path in \
    /etc/yum.repos.d/tailscale.repo \
    /usr/bin/waydroid-choose-gpu \
    /usr/bin/waydroid-launcher \
    /usr/lib/waydroid \
    /usr/libexec/waydroid-container-restart \
    /usr/libexec/waydroid-container-start \
    /usr/libexec/waydroid-container-stop \
    /usr/libexec/waydroid-fix-controllers \
    /usr/lib/systemd/system/cockpit.service \
    /usr/lib/udev/rules.d/50-framework-inputmodule.rules \
    /usr/lib/udev/rules.d/50-framework16.rules \
    /usr/share/applications/Waydroid \
    /usr/share/applications/waydroid-container-restart.desktop \
    /usr/share/polkit-1/actions/org.bazzite.waydroid.policy \
    /usr/share/polkit-1/rules.d/30-waydroid.rules; do
    if [[ -e "${removed_path}" ]]; then
        printf 'Removed integration unexpectedly remains: %s\n' \
            "${removed_path}" >&2
        exit 1
    fi
done

# Phase B — unused optional frontends and payloads: remove Tailscale, Distrobox,
# KRDC, the NVIDIA container toolkit and the independent 32-bit CUDA/FBC
# payload. Keep Podman and Toolbox (including the persistent alienfx-dev
# toolbox), NVIDIA graphics, PRIME and the complete Steam/Proton 32-bit ABI.
readonly -a PHASE_B_REMOVE_PACKAGES=(
    tailscale
    libnvidia-container-tools libnvidia-container1
    nvidia-container-toolkit nvidia-container-toolkit-base
    krdc krdc-libs
    distrobox
    nvidia-driver-cuda-libs.i686 libnvidia-fbc.i686
)

phase_b_installed=()
for package in "${PHASE_B_REMOVE_PACKAGES[@]}"; do
    if rpm --quiet -q "${package}"; then
        phase_b_installed+=("${package}")
    fi
done
if ((${#phase_b_installed[@]})); then
    dnf5 remove --no-autoremove -y "${phase_b_installed[@]}"
fi
for package in "${PHASE_B_REMOVE_PACKAGES[@]}"; do
    if rpm --quiet -q "${package}"; then
        printf 'Phase B package unexpectedly remains installed: %s\n' \
            "${package}" >&2
        exit 1
    fi
done

# Remove Bazzite integrations that would otherwise advertise the removed
# Distrobox frontend. The Toolbox container storage under /var is persistent
# host state and is neither removed nor modified by the image build.
rm -rf /etc/distrobox
rm -f /usr/share/ublue-os/just/30-distrobox.just

# ujust parses every required import before it runs any recipe. Keep the
# main justfile in sync with integrations removed from this image.
for removed_just in \
    30-distrobox.just \
    82-bazzite-cockpit.just \
    82-bazzite-waydroid.just; do
    sed -i "\|^import \"/usr/share/ublue-os/just/${removed_just}\"$|d" \
        /usr/share/ublue-os/justfile
done
JUST_JUSTFILE=/usr/share/ublue-os/justfile just --list >/dev/null

# Phase C — optional desktop stacks: remove local-VM firmware/guest helpers,
# Fcitx and non-Latin input engines, unused screen-reader/Braille/speech
# services and the optional web-app wrapper. Core IBus remains for the normal
# Plasma input path. OpenCL providers follow the current Bazzite base rather
# than being pinned by package name in this derivative image.
readonly -a PHASE_C_REMOVE_PACKAGES=(
    # Firmware/emulation for local VMs, guest operation and cross-architecture
    # containers. None is required to boot this physical x86_64 machine.
    edk2-ovmf qemu-guest-agent qemu-user-static-aarch64

    # Fcitx and non-Latin input engines/data not used by this installation.
    fcitx5 fcitx5-chewing fcitx5-chinese-addons
    fcitx5-chinese-addons-data fcitx5-configtool fcitx5-data
    fcitx5-gtk fcitx5-gtk3 fcitx5-gtk4 fcitx5-hangul fcitx5-libs
    fcitx5-libthai fcitx5-lua fcitx5-m17n fcitx5-mozc
    fcitx5-qt fcitx5-qt-libfcitx5qt6widgets
    fcitx5-qt-libfcitx5qtdbus fcitx5-qt-qt6gui fcitx5-qt5 fcitx5-qt6
    fcitx5-sayura fcitx5-table-extra fcitx5-unikey
    ibus-anthy ibus-anthy-python ibus-chewing ibus-hangul
    ibus-libpinyin ibus-m17n ibus-typing-booster
    anthy-unicode kasumi-common kasumi-unicode libpinyin libpinyin-data

    # Screen reader, Braille and speech-dispatch services are not used. The
    # general Qt Speech libraries and the normal PipeWire audio stack remain.
    brltty orca espeak-ng
    speech-dispatcher speech-dispatcher-espeak-ng
    speech-dispatcher-libs speech-dispatcher-utils

    # Optional Mint web-app wrapper; browsers and Flatpak remain available.
    webapp-manager
)

phase_c_installed=()
for package in "${PHASE_C_REMOVE_PACKAGES[@]}"; do
    if rpm --quiet -q "${package}"; then
        phase_c_installed+=("${package}")
    fi
done
if ((${#phase_c_installed[@]})); then
    dnf5 remove --no-autoremove -y "${phase_c_installed[@]}"
fi
for package in "${PHASE_C_REMOVE_PACKAGES[@]}"; do
    if rpm --quiet -q "${package}"; then
        printf 'Phase C package unexpectedly remains installed: %s\n' \
            "${package}" >&2
        exit 1
    fi
done

# Phase D — self-contained applications and guest integrations: remove MakeMKV
# and the Hyper-V, VMware and VirtualBox guest agents. Keep shared multimedia
# and image libraries, pciutils and generic host virtualization support. Only
# explicit leaf stacks are removed, so dependency changes remain visible.
readonly -a PHASE_D_REMOVE_PACKAGES=(
    # Optical-disc ripping application; normal DVD/Blu-ray playback libraries
    # and the rest of the multimedia stack remain available.
    makemkv

    # Guest agents for hypervisors that this hardware does not run under.
    hyperv-daemons hyperv-daemons-license hypervfcopyd hypervkvpd hypervvssd
    open-vm-tools open-vm-tools-desktop
    virtualbox-guest-additions
)

phase_d_installed=()
for package in "${PHASE_D_REMOVE_PACKAGES[@]}"; do
    if rpm --quiet -q "${package}"; then
        phase_d_installed+=("${package}")
    fi
done
if ((${#phase_d_installed[@]})); then
    dnf5 remove --no-autoremove -y "${phase_d_installed[@]}"
fi
for package in "${PHASE_D_REMOVE_PACKAGES[@]}"; do
    if rpm --quiet -q "${package}"; then
        printf 'Phase D package unexpectedly remains installed: %s\n' \
            "${package}" >&2
        exit 1
    fi
done

# Phase E — kernel development trees: kernel modules are compiled by Universal
# Blue's server-side akmods images and arrive as kernel-versioned kmod RPMs. The
# deployed machine therefore does not need the matching kernel build tree.
# Only explicitly named packages are removed; this build does not autoremove
# other dependencies inherited from Bazzite.
phase_e_installed=()
for package in kernel-devel-matched kernel-devel; do
    if rpm --quiet -q "${package}"; then
        phase_e_installed+=("${package}")
    fi
done
if ((${#phase_e_installed[@]})); then
    dnf5 remove --no-autoremove -y "${phase_e_installed[@]}"
fi
for package in kernel-devel-matched kernel-devel; do
    if rpm --quiet -q "${package}"; then
        printf 'Local kernel build package unexpectedly remains installed: %s\n' \
            "${package}" >&2
        exit 1
    fi
done

# The custom S4 backend calls this NVIDIA hibernation hook, so it must remain
# available even when the inherited Bazzite package set changes.
test -x /usr/bin/nvidia-sleep.sh

# Trust updates from this repository only when their Sigstore signature matches
# the public key shipped with the image. The first installation remains an
# explicit bootstrap decision; subsequent signed deployments use this policy.
policy_tmp="$(mktemp)"
jq '.transports.docker["ghcr.io/0t4k0n"] = [{
        "type": "sigstoreSigned",
        "keyPath": "/etc/pki/containers/alienware-15-r1-bazzite.pub",
        "signedIdentity": {"type": "matchRepository"}
    }]' /etc/containers/policy.json > "${policy_tmp}"
install -m 0644 "${policy_tmp}" /etc/containers/policy.json
rm -f "${policy_tmp}"

# NordVPN and ChatGPT are installed from their signed upstream repositories.
# Every scheduled build resolves their current package versions.
dnf5 install -y \
    nordvpn \
    chatgpt

# The upstream GUI RPM installs its application payload below /opt. In bootc
# images /opt is a symlink to the persistent /var/opt, which RPM deliberately
# refuses to traverse and which would not be versioned with the deployment.
# Install with a temporary real /opt, then relocate the self-contained Flutter
# bundle into immutable /usr and point the packaged launcher at its new home.
test "$(readlink /opt)" = "var/opt"
unlink /opt
mkdir /opt
dnf5 install -y nordvpn-gui
mv /opt/nordvpn-gui /usr/lib/nordvpn-gui
rmdir /opt
ln -s var/opt /opt
ln -sfn /usr/lib/nordvpn-gui/nordvpn-gui /usr/sbin/nordvpn-gui

# Seed NordVPN's mutable database on first boot without shipping regular files
# directly in /var, which is persistent state outside the image deployment.
if [[ -d /var/lib/nordvpn/data ]]; then
    mkdir -p /usr/share/nordvpn
    mv /var/lib/nordvpn/data /usr/share/nordvpn/data
fi

# VeraCrypt does not publish a Fedora repository. Pin the official RPM and
# verify both its digest and embedded RPM signature.
curl --fail --location --retry 3 \
    --output "/tmp/${VERACRYPT_RPM}" \
    "${VERACRYPT_URL}"
printf '%s  %s\n' "${VERACRYPT_SHA256}" "/tmp/${VERACRYPT_RPM}" | \
    sha256sum --check --strict
rpm --import "${VERACRYPT_KEY_URL}"
rpm --checksig "/tmp/${VERACRYPT_RPM}" | grep -q 'digests signatures OK'
dnf5 install -y "/tmp/${VERACRYPT_RPM}"
rm -f "/tmp/${VERACRYPT_RPM}"

# Preserve the service policy already validated on the running machine.
systemctl enable nordvpnd.service
systemctl enable alienware-hibernation-swap-prepare.service
systemctl disable nvidia-persistenced.service || true

# On this firmware a conventional ACPI poweroff is not reliable. Replace only
# systemd's normal poweroff backend with the validated disposable-S4 path;
# reboot, suspend and emergency forced poweroff remain untouched. Bazzite's
# Plymouth wants must not start concurrently, because the backend starts the
# splash itself after the display manager has released the console and GPU.
install -m 0644 \
    /ctx/system_files/usr/lib/systemd/system/systemd-poweroff.service \
    /usr/lib/systemd/system/systemd-poweroff.service
rm -f \
    /usr/lib/systemd/system/poweroff.target.wants/plymouth-poweroff.service \
    /usr/lib/systemd/system/poweroff.target.wants/plymouth-switch-root-initramfs.service

# Build the hardware contract without inspecting the CI runner.
/ctx/build-initramfs.sh

dnf5 clean all
rm -rf /run/dnf

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

for required_command in blkid btrfs findmnt jq lsblk restorecon swapon; do
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
    new-lg4ff new-lg4ff-akmod-modules kmod-new-lg4ff
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
    dnf5 remove -y "${phase_a_installed[@]}"
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
    /usr/share/ublue-os/just/82-bazzite-cockpit.just \
    /usr/share/ublue-os/just/82-bazzite-waydroid.just \
    /usr/share/ublue-os/udev-rules/50-framework-inputmodule.rules \
    /usr/share/ublue-os/udev-rules/50-framework16.rules

# Controller support intentionally retained: the GameCube adapter and Wii
# stack are used on this machine. Xone and v4l2loopback also remain available.
for required_package in \
    gcadapter_oc kmod-gcadapter_oc xwiimote-ng \
    xone-kmod-common kmod-xone v4l2loopback kmod-v4l2loopback; do
    rpm --quiet -q "${required_package}"
done

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

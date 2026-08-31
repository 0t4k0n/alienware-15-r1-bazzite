#!/usr/bin/bash

set -euo pipefail
set -x

readonly VERACRYPT_VERSION="1.26.29"
readonly VERACRYPT_RELEASE="Fedora-44"
readonly VERACRYPT_RPM="veracrypt-${VERACRYPT_VERSION}-${VERACRYPT_RELEASE}-x86_64.rpm"
readonly VERACRYPT_URL="https://github.com/veracrypt/VeraCrypt/releases/download/VeraCrypt_${VERACRYPT_VERSION}/${VERACRYPT_RPM}"
readonly VERACRYPT_SHA256="ff6b9b4a84a546c6a6fbc0c58ac1074fc6252cae8398f52b57ff360a3cbc312e"
readonly VERACRYPT_KEY_URL="https://amcrypto.jp/VeraCrypt/VeraCrypt_PGP_public_key.asc"

for required_command in blkid btrfs findmnt lsblk restorecon swapon; do
    command -v "${required_command}" >/dev/null
done

# Files that are part of the bootable image. Personal Plasma configuration is
# deliberately left in the user's home.
cp -avf /ctx/system_files/. /

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

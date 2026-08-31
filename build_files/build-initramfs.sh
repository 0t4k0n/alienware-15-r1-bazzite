#!/usr/bin/bash

set -euo pipefail
set -x

mapfile -t kernels < <(
    find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
)

if (( ${#kernels[@]} != 1 )); then
    printf 'Expected exactly one kernel, found %d: %s\n' \
        "${#kernels[@]}" "${kernels[*]-}" >&2
    exit 1
fi

readonly kernel="${kernels[0]}"
readonly output="${INITRAMFS_OUTPUT:-/usr/lib/modules/${kernel}/initramfs.img}"
readonly listing="/tmp/alienware-initramfs.list"
readonly module_listing="/tmp/alienware-initramfs.modules"
readonly keymap_source="/usr/lib/kbd/keymaps"
readonly unpack_dir="$(mktemp -d /tmp/alienware-initramfs.XXXXXX)"

cleanup() {
    rm -rf "${unpack_dir}"
    rm -f "${listing}" "${module_listing}"
}
trap cleanup EXIT

# This is the Dracut module inventory of the known-good 44 MiB initramfs
# generated on the Alienware 15 R1. It is intentionally explicit: CI must not
# infer a boot configuration from the GitHub runner.
dracut_modules=(
    bash systemd
    systemd-ask-password systemd-battery-check systemd-cryptsetup
    systemd-initrd systemd-journald systemd-modules-load
    systemd-sysctl systemd-tmpfiles systemd-udevd i18n drm plymouth ostree
    systemd-sysusers btrfs crypt dm fs-lib kernel-modules
    prefixdevname fido2
    rootfs-block terminfo udev-rules dracut-systemd initqueue usrmount base
    memstrack shell-interpreter shutdown openssl
)

# Early boot supports this laptop, removable USB keys, FIDO2 LUKS tokens and
# the filesystems deliberately covered by the image. Module dependencies are
# derived from the image kernel, never from the CI runner's hardware.
kernel_driver_seeds=(
    i915 dm_crypt erofs overlay uas usb_storage
    exfat ext4 btrfs
    xhci_pci ehci_pci ahci sd_mod
    usbhid hid_generic atkbd i8042
)

declare -A allowed_kernel_drivers=()
set +x
for driver in "${kernel_driver_seeds[@]}"; do
    while read -r action driver_path _; do
        [[ "${action}" == "insmod" ]] || continue
        driver_name="$(modinfo -F name "${driver_path}")"
        allowed_kernel_drivers["${driver_name}"]=1
    done < <(modprobe --show-depends -S "${kernel}" "${driver}")
done

mapfile -t kernel_drivers < <(printf '%s\n' "${!allowed_kernel_drivers[@]}" | sort)

omit_drivers=()
while IFS= read -r module_file; do
    module_name="$(modinfo -F name "${module_file}")"
    if [[ ! -v "allowed_kernel_drivers[${module_name}]" ]]; then
        omit_drivers+=("${module_name}")
    fi
done < <(find "/usr/lib/modules/${kernel}" -type f \
    \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -print)
set -x

if [[ ! -d "${keymap_source}" ]]; then
    printf 'Console keymap directory is missing: %s\n' "${keymap_source}" >&2
    exit 1
fi

set +x
dracut --force "${output}" "${kernel}" \
    --no-hostonly \
    --no-hostonly-cmdline \
    --no-hostonly-i18n \
    --modules "${dracut_modules[*]}" \
    --drivers "${kernel_drivers[*]}" \
    --omit-drivers "${omit_drivers[*]}" \
    --omit "fips fips-crypto-policies nss-softokn pcsc pkcs11 tpm2-tss kernel-modules-extra systemd-pcrphase" \
    --filesystems "btrfs ext4 exfat erofs overlay" \
    --fscks "fsck.btrfs e2fsck fsck.ext4 fsck.exfat" \
    --remove "/usr/lib/ossl-modules/fips.so /usr/lib64/ossl-modules/fips.so" \
    --strip
set -x

lsinitrd "${output}" > "${listing}"
lsinitrd -m "${output}" > "${module_listing}"
(cd "${unpack_dir}" && lsinitrd --unpack "${output}")

for module in "${dracut_modules[@]}"; do
    if ! grep -Fxq "${module}" "${module_listing}"; then
        printf 'Required declarative Dracut module is missing: %s\n' \
            "${module}" >&2
        exit 1
    fi
done

boot_critical_drivers=(
    i915 xhci_pci ehci_pci usb_storage uas ahci sd_mod
    btrfs ext4 exfat erofs overlay dm_crypt
)

for driver in "${boot_critical_drivers[@]}"; do
    driver_path="$(modinfo -k "${kernel}" -n "${driver}")"
    if [[ "${driver_path}" == "(builtin)" ]]; then
        continue
    fi

    driver_file="$(basename "${driver_path}")"
    if ! grep -Fq "/${driver_file}" "${listing}"; then
        printf 'Required boot driver is missing: %s (%s)\n' \
            "${driver}" "${driver_file}" >&2
        exit 1
    fi
done

required_patterns=(
    'systemd-cryptsetup'
    'cryptsetup'
    'usr/bin/btrfs'
    'usr/lib/ostree/ostree-prepare-root'
    'usr/lib/udev/rules.d/64-btrfs-dm.rules'
    'usr/bin/loadkeys'
    'libfido2\.so'
    'libcryptsetup-token-systemd-fido2\.so'
    'usr/bin/e2fsck'
    'usr/bin/fsck\.ext4'
    'usr/bin/fsck\.exfat'
    'it\.map'
    'us\.map'
)

for pattern in "${required_patterns[@]}"; do
    if ! grep -Eq "${pattern}" "${listing}"; then
        printf 'Required initramfs content is missing: %s\n' "${pattern}" >&2
        exit 1
    fi
done

source_keymap_count="$(find "${keymap_source}" -type f -name '*.map*' | wc -l)"
initramfs_keymap_count="$(grep -Ec 'usr/lib/kbd/keymaps/.+\.map(\.(gz|zst))?$' "${listing}")"

if (( source_keymap_count == 0 || initramfs_keymap_count < source_keymap_count )); then
    printf 'Incomplete console keymap set: initramfs has %d of %d files\n' \
        "${initramfs_keymap_count}" "${source_keymap_count}" >&2
    exit 1
fi

forbidden_patterns=(
    '/nvidia[^/]*\.ko'
    '/nouveau\.ko'
    '/amdgpu\.ko'
    '/NetworkManager/system-connections/'
    '(^| )etc/crypttab$'
    '/\.a17c9e4d$'
    'BEGIN .*PRIVATE KEY'
)

for pattern in "${forbidden_patterns[@]}"; do
    if grep -Eq "${pattern}" "${listing}"; then
        printf 'Forbidden host-specific initramfs content found: %s\n' \
            "${pattern}" >&2
        exit 1
    fi
done

for forbidden_path in \
    '*/ossl-modules/fips.so' \
    '*/libtpm2*.so*' \
    '*/opensc*.so*' \
    '*/pcsc/*'; do
    if find "${unpack_dir}" -path "${forbidden_path}" -print -quit | grep -q .; then
        printf 'Forbidden initramfs file found: %s\n' "${forbidden_path}" >&2
        exit 1
    fi
done

# No Dracut module may widen the hardware contract behind --drivers. Reject
# every module file that is not part of the dependency closure above.
while IFS= read -r module_file; do
    module_name="$(modinfo -F name "${module_file}")"
    if [[ ! -v "allowed_kernel_drivers[${module_name}]" ]]; then
        printf 'Unexpected kernel driver in initramfs: %s (%s)\n' \
            "${module_name}" "${module_file#${unpack_dir}/}" >&2
        exit 1
    fi
done < <(find "${unpack_dir}/usr/lib/modules" -type f \
    \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -print)

# Dracut legitimately installs these files even in a generic image. Accept
# only neutral values; never publish identity copied from a build host.
if [[ -s "${unpack_dir}/etc/machine-id" ]]; then
    if [[ "$(< "${unpack_dir}/etc/machine-id")" != "uninitialized" ]]; then
        printf 'A real machine-id was embedded in the initramfs\n' >&2
        exit 1
    fi
fi

if [[ -s "${unpack_dir}/etc/hostname" ]]; then
    initramfs_hostname="$(< "${unpack_dir}/etc/hostname")"
    if [[ "${initramfs_hostname}" != "localhost" && \
          "${initramfs_hostname}" != "localhost.localdomain" ]]; then
        printf 'A host-specific hostname was embedded: %s\n' \
            "${initramfs_hostname}" >&2
        exit 1
    fi
fi

size_bytes="$(stat --format='%s' "${output}")"
printf 'Validated declarative Alienware initramfs for %s: %.1f MiB\n' \
    "${kernel}" "$(awk -v bytes="${size_bytes}" 'BEGIN { print bytes / 1048576 }')"

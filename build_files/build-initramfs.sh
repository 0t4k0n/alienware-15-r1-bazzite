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
readonly output="/usr/lib/modules/${kernel}/initramfs.img"
readonly listing="/tmp/alienware-initramfs.list"
readonly module_listing="/tmp/alienware-initramfs.modules"
readonly keymap_source="/usr/lib/kbd/keymaps"

# This is the Dracut module inventory of the known-good 44 MiB initramfs
# generated on the Alienware 15 R1. It is intentionally explicit: CI must not
# infer a boot configuration from the GitHub runner.
dracut_modules=(
    nss-softokn bash systemd fips fips-crypto-policies
    systemd-ask-password systemd-battery-check systemd-cryptsetup
    systemd-initrd systemd-journald systemd-modules-load systemd-pcrphase
    systemd-sysctl systemd-tmpfiles systemd-udevd i18n drm plymouth ostree
    systemd-sysusers btrfs crypt dm fs-lib kernel-modules
    kernel-modules-extra prefixdevname fido2 pcsc pkcs11 tpm2-tss
    rootfs-block terminfo udev-rules dracut-systemd initqueue usrmount base
    memstrack shell-interpreter shutdown openssl
)

# Kernel modules present in that same known-good initramfs. Dependencies are
# resolved by Dracut. Built-in boot-critical drivers are validated separately.
kernel_drivers=(
    adiantum aegis128 async_memcpy async_pq async_raid6_recov async_tx
    async_xor blowfish_common blowfish_generic camellia_generic cast5_generic
    cast6_generic cast_common cec chacha chacha20poly1305 crc32-cryptoapi
    crypto_engine crypto_user des_generic dm-crypt drm_buddy
    drm_display_helper echainiv ecrdsa_generic erofs essiv fcrypt ff-memless
    fuse gcadapter_oc hctr2 hid-fanatec hid-logitech-new hid-tmff-new hkdf
    i2c-algo-bit i2c-dev i915 iTCO_wdt intel_oc_wdt intel_pmc_bxt krb5
    krb5enc kvmfr libdes lz4 lz4_compress lz4hc lz4hc_compress mc md4
    michael_mic nct6687 nhpoly1305 ntsync overlay padlock-aes pcbc pcrypt
    pkcs8_key_parser polyval-generic raid6test rmd160 ryzen_smu serio_raw
    serpent_generic streebog_generic system76 system76-io system76-thelio-io
    tcrypt ttm twofish_common twofish_generic uas uhid usb-storage
    v4l2loopback video videodev wmi wp512 xcbc xctr zstd
)

if [[ ! -d "${keymap_source}" ]]; then
    printf 'Console keymap directory is missing: %s\n' "${keymap_source}" >&2
    exit 1
fi

dracut --force "${output}" "${kernel}" \
    --no-hostonly \
    --no-hostonly-cmdline \
    --no-hostonly-i18n \
    --modules "${dracut_modules[*]}" \
    --drivers "${kernel_drivers[*]}" \
    --strip

lsinitrd "${output}" > "${listing}"
lsinitrd -m "${output}" > "${module_listing}"

for module in "${dracut_modules[@]}"; do
    if ! grep -Fxq "${module}" "${module_listing}"; then
        printf 'Required declarative Dracut module is missing: %s\n' \
            "${module}" >&2
        exit 1
    fi
done

boot_critical_drivers=(
    i915 xhci_pci ehci_pci usb_storage uas ahci sd_mod btrfs dm_crypt
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
    '(^| )etc/machine-id$'
    '(^| )etc/hostname$'
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

size_bytes="$(stat --format='%s' "${output}")"
printf 'Validated declarative Alienware initramfs for %s: %.1f MiB\n' \
    "${kernel}" "$(awk -v bytes="${size_bytes}" 'BEGIN { print bytes / 1048576 }')"

rm -f "${listing}" "${module_listing}"

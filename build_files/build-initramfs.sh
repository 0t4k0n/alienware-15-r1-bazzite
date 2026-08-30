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

dracut --force "${output}" "${kernel}" \
    --hostonly \
    --hostonly-mode strict \
    --no-hostonly-cmdline \
    --hostonly-i18n \
    --strip

lsinitrd "${output}" > "${listing}"

required_drivers=(
    i915
    xhci_pci
    ehci_pci
    usb_storage
    uas
    ahci
    sd_mod
    btrfs
)

for driver in "${required_drivers[@]}"; do
    driver_path="$(modinfo -k "${kernel}" -n "${driver}")"
    if [[ "${driver_path}" == "(builtin)" ]]; then
        continue
    fi

    driver_file="$(basename "${driver_path}")"
    if ! grep -Fq "/${driver_file}" "${listing}"; then
        printf 'Required initramfs driver is missing: %s (%s)\n' \
            "${driver}" "${driver_file}" >&2
        exit 1
    fi
done

required_patterns=(
    'systemd-cryptsetup'
    'cryptsetup'
    'it\.map'
)

for pattern in "${required_patterns[@]}"; do
    if ! grep -Eq "${pattern}" "${listing}"; then
        printf 'Required initramfs content is missing: %s\n' "${pattern}" >&2
        exit 1
    fi
done

forbidden_patterns=(
    '/nvidia[^/]*\.ko'
    '/nouveau\.ko'
    '/amdgpu\.ko'
    '/NetworkManager/system-connections/'
    '/\.a17c9e4d$'
    'BEGIN .*PRIVATE KEY'
)

for pattern in "${forbidden_patterns[@]}"; do
    if grep -Eq "${pattern}" "${listing}"; then
        printf 'Forbidden initramfs content found: %s\n' "${pattern}" >&2
        exit 1
    fi
done

readonly size_bytes="$(stat --format='%s' "${output}")"
readonly max_size_bytes="$((80 * 1024 * 1024))"

if (( size_bytes > max_size_bytes )); then
    printf 'Initramfs is too large: %d bytes (maximum %d)\n' \
        "${size_bytes}" "${max_size_bytes}" >&2
    exit 1
fi

printf 'Validated Alienware initramfs for %s: %.1f MiB\n' \
    "${kernel}" "$(awk -v bytes="${size_bytes}" 'BEGIN { print bytes / 1048576 }')"

rm -f "${listing}"

#!/usr/bin/env bash
set -eu

# shellcheck disable=SC2034
TEST_DESCRIPTION="UEFI boot (ukify, kernel-install)"

# Uncomment this to debug failures
#DEBUGFAIL="rd.debug rd.shell"

test_check() {
    require_binaries_for_test mksquashfs

    local arch=${DRACUT_ARCH:-$(uname -m)}
    if [[ ! ${arch} =~ ^(x86_64|i.86|aarch64|riscv64)$ ]]; then
        echo "Architecture '$arch' not supported to create a UEFI executable... Skipping" >&2
        return 1
    fi

    if ! "$testdir"/run-qemu --check-uefi; then
        echo "No UEFI firmware (for QEMU) found" >&2
        return 1
    fi
}

client_run() {
    local test_name="$1"
    local esp_img="${2-}"

    client_test_start "$test_name"

    declare -a disk_args=()
    qemu_add_drive disk_args "$TESTDIR"/marker.img marker
    qemu_add_drive disk_args "$TESTDIR"/squashfs.img root
    if [[ $esp_img ]]; then
        qemu_add_drive disk_args "$esp_img" esp
    else
        disk_args+=(-drive "file=fat:rw:$TESTDIR/ESP,format=vvfat,label=EFI")
    fi

    test_marker_reset
    "$testdir"/run-qemu "${disk_args[@]}" -net none
    test_marker_check
}

test_run() {
    client_run "UEFI with UKI and squashfs root" || return 1

    if [[ -f "$TESTDIR"/esp-fips.img ]]; then
        if client_run "UEFI with UKI in FIPS mode and a corrupted HMAC" "$TESTDIR"/esp-fips-bad.img; then
            echo "FIPS mode booted a UKI whose HMAC does not match" >&2
            return 1
        fi
        client_run "UEFI with UKI in FIPS mode" "$TESTDIR"/esp-fips.img || return 1
    fi
}

# Creates GPT disk image $2 with an ESP holding the EFI directory of $1
make_esp_image() {
    local esp="$1"
    local img="$2"
    local esp_size

    # the ESP content plus some room for the file system, in MiB
    esp_size=$(($(du -s -m "$esp" | cut -f1) + 32))
    rm -f "$img" "$img".part
    mkfs.vfat -C "$img".part $((esp_size * 1024))
    mcopy -s -i "$img".part "$esp"/EFI ::/
    # 1 MiB in front of the partition and 1 MiB for the backup GPT
    truncate -s $((esp_size + 2))M "$img"
    echo "start=1MiB, size=${esp_size}MiB, type=uefi" | sfdisk -q --label gpt "$img"
    dd if="$img".part of="$img" bs=1M seek=1 conv=notrunc status=none
    rm -f "$img".part
}

# FIPS mode checks the booted UKI against the .hmac file next to it. Boot one
# that is not in EFI/Linux, from a GPT disk, as systemd-stub only reports the
# partition and path it was loaded from for GPT partitions.
test_setup_fips() {
    local esp="$TESTDIR"/ESP-fips

    if ! [[ -f /usr/share/crypto-policies/default-fips-config ]] \
        || ! require_binaries_for_test sha512hmac mkfs.vfat mcopy sfdisk; then
        echo "Skipping UEFI with UKI in FIPS mode"
        return 0
    fi

    mkdir -p "$esp"/EFI/BOOT
    call_dracut --tmpdir "$TESTDIR" \
        --add-confdir test \
        --kernel-cmdline "$TEST_KERNEL_CMDLINE fips=1 root=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root" \
        --no-hostonly \
        --add fips \
        --add-drivers 'squashfs vfat' \
        --kver "$KVERSION" \
        --uefi \
        "$esp"/EFI/BOOT/BOOTX64.efi

    # a well-formed HMAC that does not match the UKI
    printf '%0128d  BOOTX64.efi\n' 0 > "$esp"/EFI/BOOT/.BOOTX64.efi.hmac
    make_esp_image "$esp" "$TESTDIR"/esp-fips-bad.img

    (cd "$esp"/EFI/BOOT && sha512hmac BOOTX64.efi > .BOOTX64.efi.hmac)
    make_esp_image "$esp" "$TESTDIR"/esp-fips.img
}

test_setup() {
    # shellcheck source=./dracut-functions.sh
    . "$PKGLIBDIR"/dracut-functions.sh

    # Create what will eventually be our root filesystem
    call_dracut --tmpdir "$TESTDIR" \
        --add-confdir test-root \
        "$TESTDIR"/tmp-initramfs.root

    KVERSION=$(determine_kernel_version "$TESTDIR"/tmp-initramfs.root)
    KIMAGE=$(determine_kernel_image "$KVERSION")

    mksquashfs "$TESTDIR"/dracut.*/initramfs/ "$TESTDIR"/squashfs.img -quiet -no-progress

    mkdir -p "$TESTDIR"/ESP/EFI/BOOT "$TESTDIR"/dracut.conf.d

    test_setup_fips

    # This is the preferred way to build uki with dracut on a systemd based system
    if command -v kernel-install &> /dev/null \
        && command -v systemctl &> /dev/null \
        && command -v ukify &> /dev/null; then

        echo "Using ukify via kernel-install to create UKI"

        export KERNEL_INSTALL_CONF_ROOT="$TESTDIR"/kernel-install
        mkdir -p "$KERNEL_INSTALL_CONF_ROOT"

        {
            echo 'initrd_generator=dracut'
            echo 'layout=uki'
            echo 'uki_generator=ukify'
        } >> "$KERNEL_INSTALL_CONF_ROOT/install.conf"

        echo "$TEST_KERNEL_CMDLINE root=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root" >> "$KERNEL_INSTALL_CONF_ROOT/cmdline"

        # enable test dracut config
        mkdir -p /run/initramfs/dracut.conf.d
        cp "${basedir}"/dracut.conf.d/test/* ./10-uki-virt.conf /run/initramfs/dracut.conf.d/
        echo 'add_drivers+=" squashfs "' >> /run/initramfs/dracut.conf.d/extra.conf

        # using kernell-install to invoke dracut
        mkdir -p "$BOOT_ROOT/$TOKEN/$KVERSION" "$BOOT_ROOT/loader/entries"
        kernel-install add "$KVERSION" "$KIMAGE"

        mv "$TESTDIR"/EFI/Linux/*.efi "$TESTDIR"/ESP/EFI/BOOT/BOOTX64.efi

        return 0
    fi

    # test with the reference uki config when systemd is available
    if command -v systemctl &> /dev/null; then
        cp ./10-uki-virt.conf "$TESTDIR"/dracut.conf.d/

    fi

    echo "Using dracut to create UKI"
    test_dracut \
        --kernel-cmdline "$TEST_KERNEL_CMDLINE root=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root" \
        --add-drivers 'squashfs' \
        --kver "$KVERSION" \
        --uefi \
        "$TESTDIR"/ESP/EFI/BOOT/BOOTX64.efi
}

# shellcheck disable=SC1090
. "$testdir"/test-functions

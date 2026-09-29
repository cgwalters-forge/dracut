#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

# systemd lets stdout go to journal only, but the system
# has to halt when the integrity check fails to satisfy FIPS.
if [ -z "${DRACUT_SYSTEMD-}" ]; then
    fips_info() {
        info "$*"
    }
else
    fips_info() {
        echo "$*" >&2
    }
fi

FIPS_LOADER_EFIVARS=/sys/firmware/efi/efivars
FIPS_LOADER_GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f

# Prints the string value of the systemd boot loader/stub EFI variable $1.
# The efivar file has a 4 bytes header and contains UCS-2 data. Note, 'cat' is
# required as /sys/firmware/efi/efivars/ files are 'special' and don't allow
# 'seeking'.
read_loader_efivar() {
    local _var="$FIPS_LOADER_EFIVARS/$1-$FIPS_LOADER_GUID"

    [ -f "$_var" ] || return 1
    # shellcheck disable=SC2002
    cat "$_var" | tail -c +5 | tr -d '\0'
}

# Checks if a systemd-based UKI is running and ESP UUID is set
is_uki() {
    [ -f "$FIPS_LOADER_EFIVARS/StubFeatures-$FIPS_LOADER_GUID" ] \
        && [ -f "$FIPS_LOADER_EFIVARS/LoaderDevicePartUUID-$FIPS_LOADER_GUID" ]
}

# Checks if systemd-stub (v257+) reported where the UKI was loaded from
has_stub_location() {
    [ -f "$FIPS_LOADER_EFIVARS/StubDevicePartUUID-$FIPS_LOADER_GUID" ] \
        && [ -f "$FIPS_LOADER_EFIVARS/StubImageIdentifier-$FIPS_LOADER_GUID" ]
}

# Prints the partition UUID of the partition the UKI was loaded from
stub_part_uuid() {
    read_loader_efivar StubDevicePartUUID | tr 'A-F' 'a-f'
}

# Prints the path of the booted UKI relative to the root of the partition it
# was loaded from, as reported by systemd-stub in StubImageIdentifier. Fails
# if that is missing or is not a usable path.
booted_uki_path() {
    local _id _path

    _id=$(read_loader_efivar StubImageIdentifier) || return 1

    # The identifier is an EFI device path in text form. Usually it is only
    # the file path, e.g. '\EFI\Linux\foo.efi', but drop any device nodes
    # in front of it, and turn the file path into a POSIX one.
    case "$_id" in
        *\\*) _path="\\${_id#*\\}" ;;
        *)
            warn "Cannot find a file path in StubImageIdentifier '$_id'"
            return 1
            ;;
    esac
    _path=$(printf '%s\n' "$_path" | tr -s '\134' /)

    case "/$_path/" in
        */../*)
            warn "Refusing StubImageIdentifier '$_id' with a '..' component"
            return 1
            ;;
    esac
    printf '%s\n' "$_path"
}

mount_boot() {
    local _boot_arg _stub_dev

    boot=$(getarg boot=)
    _boot_arg=$boot

    if is_uki && [ -z "$boot" ]; then
        # Prefer the partition the UKI was loaded from, which is not the ESP
        # when the UKI is on an XBOOTLDR partition.
        if has_stub_location; then
            boot="PARTUUID=$(stub_part_uuid)"
        else
            boot="PARTUUID=$(read_loader_efivar LoaderDevicePartUUID | tr 'A-F' 'a-f')"
        fi
    fi

    if [ -n "$boot" ]; then
        if [ -d /boot ] && ismounted /boot; then
            boot_dev=
            if command -v findmnt > /dev/null; then
                boot_dev=$(findmnt -n -o SOURCE /boot)
            fi
            fips_info "Ignoring 'boot=$boot' as /boot is already mounted ${boot_dev:+"from '$boot_dev'"}"
            return 0
        fi

        case "$boot" in
            LABEL=* | UUID=* | PARTUUID=* | PARTLABEL=*)
                boot="$(label_uuid_to_dev "$boot")"
                ;;
            /dev/*) ;;

            *)
                die "You have to specify boot=<boot device> as a boot option for fips=1"
                ;;
        esac

        if ! [ -e "$boot" ]; then
            udevadm trigger --action=add > /dev/null 2>&1

            i=0
            while ! [ -e "$boot" ]; do
                udevadm settle --exit-if-exists="$boot"
                [ -e "$boot" ] && break
                sleep 0.5
                i=$((i + 1))
                [ $i -gt 40 ] && break
            done
        fi

        [ -e "$boot" ] || return 1

        # The UKI check looks for the booted UKI on /boot, so an explicit
        # boot= must be the partition it was loaded from.
        if [ -n "$_boot_arg" ] && is_uki && has_stub_location; then
            _stub_dev="/dev/disk/by-partuuid/$(stub_part_uuid)"
            [ -e "$_stub_dev" ] || udevadm settle --timeout=20 --exit-if-exists="$_stub_dev"
            if [ "$(readlink -f "$boot")" != "$(readlink -f "$_stub_dev")" ]; then
                warn "'boot=$_boot_arg' is not the partition the UKI was booted from ($_stub_dev)"
                return 1
            fi
        fi

        mkdir -p /boot
        fips_info "Mounting $boot as /boot"
        mount -oro "$boot" /boot || return 1
        FIPS_MOUNTED_BOOT=1
    elif ! ismounted /boot && [ -d "$NEWROOT/boot" ]; then
        # shellcheck disable=SC2114
        rm -fr -- /boot
        ln -sf "$NEWROOT/boot" /boot
    else
        die "You have to specify boot=<boot device> as a boot option for fips=1"
    fi
}

do_rhevh_check() {
    KERNEL=$(uname -r)
    kpath=${1}

    # If we're on RHEV-H, the kernel is in /run/initramfs/live/vmlinuz0
    HMAC_SUM_ORIG=$(while read -r a _ || [ -n "$a" ]; do printf "%s\n" "$a"; done < "$NEWROOT/boot/.vmlinuz-${KERNEL}.hmac")
    HMAC_SUM_CALC=$(sha512hmac "$kpath" | while read -r a _ || [ -n "$a" ]; do printf "%s\n" "$a"; done || return 1)
    if [ -z "$HMAC_SUM_ORIG" ] || [ -z "$HMAC_SUM_CALC" ] || [ "${HMAC_SUM_ORIG}" != "${HMAC_SUM_CALC}" ]; then
        warn "HMAC sum mismatch"
        return 1
    fi
    fips_info "rhevh_check OK"
    return 0
}

# Checks the UKI at path $1 against the .<name>.hmac file next to it. The
# HMAC is computed over $1 itself, whatever file name the .hmac lists.
check_uki_hmac() {
    local _hmac="${1%/*}/.${1##*/}.hmac"
    local _expected=
    local _actual

    fips_info "checking $_hmac"
    if ! [ -r "$_hmac" ]; then
        warn "$_hmac does not exist"
        return 1
    fi
    read -r _expected _ < "$_hmac" || [ -n "$_expected" ]
    _actual=$(sha512hmac "$1") || return 1
    _actual=${_actual%% *}
    if [ -z "$_expected" ] || [ "$_expected" != "$_actual" ]; then
        warn "HMAC sum mismatch for $1"
        return 1
    fi
    fips_info "$1: OK"
}

do_uki_check() {
    local KVER
    local uki_checked=0
    local UKIpath

    KVER="$(uname -r)"
    if ! [ "$FIPS_MOUNTED_BOOT" = 1 ]; then
        warn "Failed to mount ESP for doing UKI integrity check"
        return 1
    fi

    # Check exactly the UKI that was booted, wherever it is on the partition.
    if has_stub_location; then
        UKIpath="/boot$(booted_uki_path)" || return 1
        if ! [ -f "$UKIpath" ]; then
            warn "Booted UKI '$UKIpath' not found for checking"
            return 1
        fi
        check_uki_hmac "$UKIpath"
        return
    fi

    for UKIpath in /boot/EFI/Linux/*-"$KVER".efi; do
        # UKIs are installed to $ESP/EFI/Linux/<entry-token-or-machine-id>-<uname-r>.efi
        # and in some cases (e.g. when the image is used as a template for creating new
        # VMs) entry-token-or-machine-id can change. Without systemd-stub telling which
        # UKI was booted, check all UKIs which match the 'uname -r' of the running kernel
        # and fail the whole check if any of the matching UKIs are corrupted.

        [ -r "$UKIpath" ] || break

        check_uki_hmac "$UKIpath" || return 1
        uki_checked=1
    done

    if [ "$uki_checked" = 0 ]; then
        warn "Failed for find UKI for checking"
        return 1
    fi
    return 0
}

nonfatal_modprobe() {
    modprobe "$1" 2>&1 > /dev/stdout \
        | while read -r line || [ -n "$line" ]; do
            echo "${line#modprobe: FATAL: }" >&2
        done
}

fips_load_crypto() {
    local _k
    local _v
    local _module
    local _found

    fips_info "Loading and integrity checking all crypto modules"
    while read -r _module; do
        if [ "$_module" != "tcrypt" ]; then
            if ! nonfatal_modprobe "${_module}" 2> /tmp/fips.modprobe_err; then
                # check if kernel provides generic algo
                _found=0
                while read -r _k _ _v || [ -n "$_k" ]; do
                    [ "$_k" != "name" ] && [ "$_k" != "driver" ] && continue
                    [ "$_v" != "$_module" ] && continue
                    _found=1
                    break
                done < /proc/crypto
                [ "$_found" = "0" ] && cat /tmp/fips.modprobe_err >&2 && return 1
            fi
        fi
    done < /etc/fipsmodules
    if [ -f /etc/fips.conf ]; then
        mkdir -p /run/modprobe.d
        cp /etc/fips.conf /run/modprobe.d/fips.conf
    fi

    fips_info "Self testing crypto algorithms"
    modprobe tcrypt || return 1
    rmmod tcrypt
}

do_fips() {
    KERNEL=$(uname -r)

    if ! getarg rd.fips.skipkernel > /dev/null; then

        fips_info "Checking integrity of kernel"
        if [ -e "/run/initramfs/live/vmlinuz0" ]; then
            do_rhevh_check /run/initramfs/live/vmlinuz0 || return 1
        elif [ -e "/run/initramfs/live/isolinux/vmlinuz0" ]; then
            do_rhevh_check /run/initramfs/live/isolinux/vmlinuz0 || return 1
        elif [ -e "/run/install/repo/images/pxeboot/vmlinuz" ]; then
            # This is a boot.iso with the .hmac inside the install.img
            do_rhevh_check /run/install/repo/images/pxeboot/vmlinuz || return 1
        elif is_uki; then
            # This is a UKI
            do_uki_check || return 1
        else
            BOOT_IMAGE="$(getarg BOOT_IMAGE)"

            # On s390x, BOOT_IMAGE isn't a path but an integer representing the
            # entry number selected. Let's try the root of /boot first, and
            # otherwise fallback to trying to parse the BLS entries if it's a
            # BLS-based system.
            if [ "$(uname -m)" = s390x ]; then
                if [ -e "/boot/vmlinuz-${KERNEL}" ]; then
                    BOOT_IMAGE="vmlinuz-${KERNEL}"
                elif [ -d /boot/loader/entries ]; then
                    bls=$(find /boot/loader/entries -name '*.conf' | sort -rV | sed -n "$((BOOT_IMAGE + 1))p")
                    if [ -e "${bls}" ]; then
                        BOOT_IMAGE=$(grep ^linux "${bls}" | cut -d' ' -f2)
                    fi
                fi
            fi

            # Trim off any leading GRUB boot device (e.g. ($root) )
            BOOT_IMAGE="$(echo "${BOOT_IMAGE}" | sed 's/^(.*)//')"

            BOOT_IMAGE_NAME="${BOOT_IMAGE##*/}"
            BOOT_IMAGE_PATH="${BOOT_IMAGE%"${BOOT_IMAGE_NAME}"}"

            if [ -z "$BOOT_IMAGE_NAME" ]; then
                BOOT_IMAGE_NAME="vmlinuz-${KERNEL}"
            elif ! [ -e "/boot/${BOOT_IMAGE_PATH}/${BOOT_IMAGE_NAME}" ]; then
                #if /boot is not a separate partition BOOT_IMAGE might start with /boot
                BOOT_IMAGE_PATH=${BOOT_IMAGE_PATH#"/boot"}
                #on some architectures BOOT_IMAGE does not contain path to kernel
                #so if we can't find anything, let's treat it in the same way as if it was empty
                if ! [ -e "/boot/${BOOT_IMAGE_PATH}/${BOOT_IMAGE_NAME}" ]; then
                    BOOT_IMAGE_NAME="vmlinuz-${KERNEL}"
                    BOOT_IMAGE_PATH=""
                fi
            fi

            BOOT_IMAGE_HMAC="/boot/${BOOT_IMAGE_PATH}/.${BOOT_IMAGE_NAME}.hmac"
            if ! [ -e "${BOOT_IMAGE_HMAC}" ]; then
                warn "${BOOT_IMAGE_HMAC} does not exist"
                return 1
            fi

            (cd "${BOOT_IMAGE_HMAC%/*}" && sha512hmac -c "${BOOT_IMAGE_HMAC}") || return 1
        fi
    fi

    fips_info "All initrd crypto checks done"

    : > /tmp/fipsdone

    if [ "$FIPS_MOUNTED_BOOT" = 1 ]; then
        fips_info "Unmounting /boot"
        umount /boot > /dev/null 2>&1
    else
        fips_info "Not unmounting /boot"
    fi

    return 0
}

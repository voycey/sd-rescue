#!/bin/bash
# Helpers that run INSIDE the rescue container, against /dev/nbdX.
# No pipefail: dumpe2fs exits non-zero even when it prints a usable backup
# superblock, and several probes below judge it by output rather than status.
set -u

NBD_DEV="${NBD_DEV:-/dev/nbd0}"

# Backup superblock offsets to try when the primary is unreadable, as
# "block:blocksize" pairs. 4k first - that is what the Pi imager writes.
EXT_BACKUP_SB="32768:4096 98304:4096 163840:4096 229376:4096 294912:4096 \
               16384:2048 49152:2048 8193:1024 24577:1024 40961:1024"

# ---------------------------------------------------------------- discovery --
# Filesystem type of a partition. Falls back to the MBR partition type when the
# superblock is too damaged for blkid, which is the whole point of this tool.
fstype_of() {
    local p="$1" t parent num
    t=$(blkid -o value -s TYPE "$p" 2>/dev/null)
    if [ -n "$t" ]; then echo "$t"; return; fi

    # blkid needs an intact superblock. When there isn't one, read the MBR
    # partition type straight off the disk instead (lsblk can't: no udev here).
    parent="${p%p[0-9]*}"
    num="${p##*p}"
    case "$(sfdisk --part-type "$parent" "$num" 2>/dev/null | tr 'A-F' 'a-f')" in
        83)              echo "ext-suspect" ;;   # Linux
        b|c|e|6|1|4)     echo "vfat-suspect" ;;  # FAT variants
        *)               echo "" ;;
    esac
}

# Echo "block:blocksize" of a usable ext superblock, or nothing.
# "0:0" means the primary superblock is fine.
ext_superblock() {
    local p="$1" pair sb bs
    # dumpe2fs exits non-zero even when a backup superblock reads fine, so
    # judge it by what it printed, not by its exit code.
    if dumpe2fs -h "$p" 2>/dev/null | grep -q '^Block count:'; then
        echo "0:0"; return 0
    fi
    for pair in $EXT_BACKUP_SB; do
        sb="${pair%%:*}"; bs="${pair##*:}"
        if dumpe2fs -h -o superblock="$sb" -o blocksize="$bs" "$p" 2>/dev/null \
             | grep -q '^Block count:'; then
            echo "$sb:$bs"; return 0
        fi
    done
    return 1
}

# Print the e2fsck/dumpe2fs arguments needed to reach a usable superblock.
ext_sb_args() {
    local pair="$1" sb bs
    sb="${pair%%:*}"; bs="${pair##*:}"
    [ "$sb" = 0 ] || printf -- '-b %s -B %s' "$sb" "$bs"
}

is_ext()  { case "$1" in ext2|ext3|ext4|ext-suspect) return 0;; *) return 1;; esac; }
is_fat()  { case "$1" in vfat|msdos|fat|vfat-suspect) return 0;; *) return 1;; esac; }

# ------------------------------------------------------------------- report --
report() {
    local p t pair
    echo "  ● Partition table"
    fdisk -l "$NBD_DEV" 2>&1
    echo
    echo "  ● Block devices"
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPE,LABEL,UUID "$NBD_DEV" 2>&1
    echo
    for p in "${NBD_DEV}"p*; do
        [ -b "$p" ] || continue
        t=$(fstype_of "$p")
        echo "  ● $p  (${t:-unrecognised})"
        if is_ext "$t"; then
            if pair=$(ext_superblock "$p"); then
                if [ "$pair" = "0:0" ]; then
                    echo "  primary superblock: OK"
                else
                    echo "  ${_r:-}primary superblock: UNREADABLE - using backup at block ${pair%%:*} (blocksize ${pair##*:})"
                fi
                # shellcheck disable=SC2046
                dumpe2fs -h $(ext_sb_args "$pair") "$p" 2>&1 | grep -Ei \
                    'Filesystem (volume name|state|features|UUID)|Block count|Block size|Free blocks|Last (checked|mount|write)|Mount count|Maximum mount|FS Error|error count|First error|Last error'
            else
                echo "  no readable superblock, primary or backup - this partition may need ddrescue + testdisk"
            fi
        elif is_fat "$t"; then
            fsck.fat -n -v "$p" 2>&1 | tail -20
        else
            echo "  unrecognised - raw signature:"
            dd if="$p" bs=512 count=1 status=none | file -
        fi
        echo
    done
}

# ------------------------------------------------------------------ imaging --
# Image only the USED blocks of each partition. Never writes to the card.
backup() {
    local out="$1" p name t size pair rc=0
    mkdir -p "$out"
    : > "$out/manifest.txt"
    {
        echo "created:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "device:    $NBD_DEV"
        echo "size:      $(blockdev --getsize64 "$NBD_DEV") bytes"
    } >> "$out/manifest.txt"

    # MBR, the gap after it, and the head of p1. Makes the backup standalone.
    dd if="$NBD_DEV" of="$out/header-32MiB.bin" bs=1M count=32 status=none conv=sync
    echo "file:      header-32MiB.bin  (first 32 MiB, raw)" >> "$out/manifest.txt"
    sfdisk -d "$NBD_DEV" > "$out/partition-table.sfdisk" 2>/dev/null
    echo "file:      partition-table.sfdisk" >> "$out/manifest.txt"

    for p in "${NBD_DEV}"p*; do
        [ -b "$p" ] || continue
        name=$(basename "$p")
        t=$(fstype_of "$p")
        size=$(blockdev --getsize64 "$p")
        echo "  ● imaging $p  type=${t:-unrecognised}  size=$size" >&2

        if is_ext "$t" && pair=$(ext_superblock "$p") && [ "$pair" = "0:0" ]; then
            # partclone walks the block bitmap: only used blocks are read.
            if partclone.extfs -c -s "$p" -O "$out/$name.pcl" -F -L "$out/$name.partclone.log"; then
                echo "file:      $name.pcl  (partclone extfs, used blocks only, type=$t, size=$size)" >> "$out/manifest.txt"
                continue
            fi
            echo "  err partclone failed on $p - falling back to a full sparse image" >&2
        elif is_ext "$t"; then
            echo "  err $p has no usable primary superblock: partclone cannot read the" >&2
            echo "    block bitmap, so every sector must be read instead. This is slow." >&2
        elif is_fat "$t"; then
            # Boot partition is small; a full raw copy is cheapest and safest.
            if dd if="$p" of="$out/$name.img" bs=4M status=progress; then
                echo "file:      $name.img  (raw full copy, type=$t, size=$size)" >> "$out/manifest.txt"
            else
                echo "  err dd failed on $p" >&2; rc=1
            fi
            continue
        fi

        # Fallback for everything else: ddrescue into a sparse file. It reads
        # every sector but skips bad ones instead of dying, and records a map
        # so an interrupted run can be resumed.
        if ddrescue -f -n "$p" "$out/$name.img" "$out/$name.mapfile"; then
            echo "file:      $name.img  (ddrescue sparse image, type=${t:-unknown}, size=$size)" >> "$out/manifest.txt"
        else
            echo "  err ddrescue failed on $p" >&2; rc=1
        fi
    done

    sync
    echo "  ● checksumming backup" >&2
    ( cd "$out" && sha256sum ./*.pcl ./*.img ./*.bin 2>/dev/null > SHA256SUMS )
    if [ "$rc" -eq 0 ]; then
        echo "status:    complete" >> "$out/manifest.txt"
    else
        echo "status:    INCOMPLETE - see log above" >> "$out/manifest.txt"
    fi
    return "$rc"
}

# -------------------------------------------------------------------- fsck ---
# mode: check (read-only, no repairs) | repair (auto-fix)
run_fsck() {
    local mode="$1" p t pair sbargs r rc=0
    for p in "${NBD_DEV}"p*; do
        [ -b "$p" ] || continue
        t=$(fstype_of "$p")
        echo "  ● fsck ($mode) $p  type=${t:-unrecognised}"

        if is_ext "$t"; then
            if ! pair=$(ext_superblock "$p"); then
                echo "  no readable superblock - e2fsck cannot help here."
                echo "  Next step: image it with ddrescue, then try testdisk on the image."
                rc=8; continue
            fi
            sbargs=$(ext_sb_args "$pair")
            [ -n "$sbargs" ] && echo "  using backup superblock: $sbargs"
            if [ "$mode" = check ]; then
                # shellcheck disable=SC2086
                e2fsck -f -n -v $sbargs "$p"
            else
                # shellcheck disable=SC2086
                e2fsck -f -y -v $sbargs "$p"
                r=$?
                # Repairing from a backup superblock leaves the primary stale;
                # a second pass rewrites it from the now-good metadata.
                if [ -n "$sbargs" ] && [ "$r" -lt 8 ]; then
                    echo "  second pass against the rebuilt primary superblock"
                    e2fsck -f -y -v "$p"
                fi
            fi
        elif is_fat "$t"; then
            if [ "$mode" = check ]; then
                fsck.fat -n -v "$p"
            else
                fsck.fat -a -w -v "$p"
            fi
        else
            echo "  skipping: no checker for type '${t:-unrecognised}'"
            continue
        fi

        r=$?
        # 0 clean, 1 corrected, 2 corrected+reboot, 4 errors left, >=8 fatal.
        echo "    exit=$r"
        [ "$r" -ge 4 ] && rc="$r"
    done
    sync
    return "$rc"
}

# --------------------------------------------------------------- triage ------
# Decide whether this card actually needs a repair pass, and say why.
# Prints one line per reason; returns 0 if a repair is warranted, 1 if clean.
#
# An fsck exit code alone is not enough: an ext4 filesystem with a pending
# journal (needs_recovery) can pass a read-only check while still being dirty,
# because e2fsck -n deliberately skips journal recovery.
needs_repair() {
    local p t pair out state ec verdict=1
    for p in "${NBD_DEV}"p*; do
        [ -b "$p" ] || continue
        t=$(fstype_of "$p")

        if is_ext "$t"; then
            if ! pair=$(ext_superblock "$p"); then
                echo "$p: no readable superblock (e2fsck cannot fix this)"
                verdict=0; continue
            fi
            # shellcheck disable=SC2046
            out=$(dumpe2fs -h $(ext_sb_args "$pair") "$p" 2>/dev/null)

            [ "$pair" = "0:0" ] || { echo "$p: primary superblock damaged, backup in use"; verdict=0; }

            grep -q 'needs_recovery' <<<"$out" && {
                echo "$p: journal needs replay (needs_recovery) - unclean shutdown"; verdict=0; }

            state=$(sed -n 's/^Filesystem state: *//p' <<<"$out" | head -1)
            [ -n "$state" ] && [ "$state" != "clean" ] && {
                echo "$p: filesystem state is '$state'"; verdict=0; }

            ec=$(sed -n 's/^FS Error count: *//p' <<<"$out" | head -1)
            [ -n "$ec" ] && [ "$ec" -gt 0 ] 2>/dev/null && {
                echo "$p: $ec errors recorded by the kernel"; verdict=0; }

        elif is_fat "$t"; then
            fsck.fat -n "$p" >/dev/null 2>&1 || {
                echo "$p: fsck.fat reports problems"; verdict=0; }
        fi
    done
    return "$verdict"
}

# --------------------------------------------------------------- survey ------
# Emit the card's state as flat key=value lines for the macOS side to render.
# Everything here is read-only.
survey() {
    local p t pair out n=0 size used label state detail
    local bs bc fb fsstate ec fout clu cur tot bpc

    echo "disk.size=$(blockdev --getsize64 "$NBD_DEV" 2>/dev/null)"
    echo "disk.table=$(sfdisk -l "$NBD_DEV" 2>/dev/null | sed -n 's/^Disklabel type: //p')"

    for p in "${NBD_DEV}"p*; do
        [ -b "$p" ] || continue
        n=$((n+1))
        t=$(fstype_of "$p")
        size=$(blockdev --getsize64 "$p" 2>/dev/null)
        label=""; used=""; state="unknown"; detail=""

        if is_ext "$t"; then
            if pair=$(ext_superblock "$p"); then
                # shellcheck disable=SC2046
                out=$(dumpe2fs -h $(ext_sb_args "$pair") "$p" 2>/dev/null)
                label=$(sed -n 's/^Filesystem volume name: *//p' <<<"$out" | head -1)
                bs=$(sed -n 's/^Block size: *//p'   <<<"$out" | head -1)
                bc=$(sed -n 's/^Block count: *//p'  <<<"$out" | head -1)
                fb=$(sed -n 's/^Free blocks: *//p'  <<<"$out" | head -1)
                [ -n "$bs" ] && [ -n "$bc" ] && [ -n "$fb" ] && used=$(( (bc - fb) * bs ))
                [ "$t" = "ext-suspect" ] && t=ext4

                state=clean
                if [ "$pair" != "0:0" ]; then
                    state=damaged; detail="primary superblock unreadable, backup in use"
                fi
                fsstate=$(sed -n 's/^Filesystem state: *//p' <<<"$out" | head -1)
                if [ -n "$fsstate" ] && [ "$fsstate" != clean ]; then
                    state=dirty; detail="filesystem state: $fsstate"
                fi
                if grep -q 'needs_recovery' <<<"$out"; then
                    state=dirty; detail="journal needs replay (unclean shutdown)"
                fi
                ec=$(sed -n 's/^FS Error count: *//p' <<<"$out" | head -1)
                if [ -n "$ec" ] && [ "$ec" -gt 0 ] 2>/dev/null; then
                    state=errors; detail="$ec errors recorded by the kernel"
                fi
            else
                state=unreadable; detail="no readable superblock, primary or backup"
                t=ext4
            fi

        elif is_fat "$t"; then
            t=vfat
            label=$(blkid -o value -s LABEL "$p" 2>/dev/null)
            fout=$(fsck.fat -n -v "$p" 2>&1)
            bpc=$(grep -oE '^ *[0-9]+ bytes per cluster' <<<"$fout" | grep -oE '[0-9]+' | head -1)
            clu=$(grep -oE '[0-9]+/[0-9]+ clusters' <<<"$fout" | head -1)
            cur="${clu%%/*}"; tot="${clu##*/}"; tot="${tot%% *}"
            [ -n "$bpc" ] && [ -n "$cur" ] && used=$(( cur * bpc ))
            if fsck.fat -n "$p" >/dev/null 2>&1; then
                state=clean
            else
                state=dirty; detail="fsck.fat reports problems"
            fi
        fi

        echo "part.$n.dev=$(basename "$p")"
        echo "part.$n.fs=$t"
        echo "part.$n.label=$label"
        echo "part.$n.size=$size"
        echo "part.$n.used=$used"
        echo "part.$n.state=$state"
        echo "part.$n.detail=$detail"
    done
    echo "part.count=$n"
}

# --------------------------------------------------------------- verify ------
# Boot-readiness checks that fsck does not do. Mounts both partitions
# read-only and inspects what the Pi's boot chain will need.
#   verify_boot        fast checks (seconds)
#   verify_boot deep   also checks every package file against dpkg's md5sums
# Prints ok/warn/FAIL lines; returns 1 if anything FAILed.
V_FAILS=0; V_WARNS=0
v_ok()   { echo "  ok    $*"; }
v_warn() { echo "  warn  $*"; V_WARNS=$((V_WARNS+1)); }
v_fail() { echo "  FAIL  $*"; V_FAILS=$((V_FAILS+1)); }

verify_boot() {
    local deep="${1:-}" boot=/mnt/bootfs root=/mnt/rootfs p t bp="" rp=""
    V_FAILS=0; V_WARNS=0
    for p in "${NBD_DEV}"p*; do
        [ -b "$p" ] || continue
        t=$(fstype_of "$p")
        is_fat "$t" && [ -z "$bp" ] && bp="$p"
        is_ext "$t" && [ -z "$rp" ] && rp="$p"
    done
    [ -n "$bp" ] || { v_fail "no FAT boot partition found"; return 1; }
    [ -n "$rp" ] || { v_fail "no ext4 root partition found"; return 1; }

    mkdir -p "$boot" "$root"
    mount -o ro "$bp" "$boot" 2>/dev/null || { v_fail "cannot mount $bp (boot)"; return 1; }
    if ! mount -o ro "$rp" "$root" 2>/dev/null; then
        v_fail "cannot mount $rp (root) - the kernel would fail here too"
        umount "$boot"; return 1
    fi

    _verify_checks "$boot" "$root" "$bp" "$rp" "$deep"
    umount "$root" "$boot" 2>/dev/null
    echo
    if [ "$V_FAILS" -gt 0 ]; then
        echo "  result: $V_FAILS problem(s) that need fixing on the Pi, $V_WARNS warning(s)"
        return 1
    fi
    echo "  result: no boot blockers found, $V_WARNS warning(s)"
    return 0
}

_verify_checks() {
    local boot="$1" root="$2" bp="$3" rp="$4" deep="$5"
    local f k kver="" diskid="" cmdroot="" pnum

    # ---- boot partition contents ----------------------------------------
    echo "  boot partition"
    for f in config.txt cmdline.txt; do
        [ -s "$boot/$f" ] && v_ok "$f present" || v_fail "$f missing or empty"
    done
    k=""
    for f in kernel_2712.img kernel8.img kernel7l.img kernel7.img kernel.img; do
        [ -s "$boot/$f" ] && { k="$f"; break; }
    done
    [ -n "$k" ] && v_ok "kernel image: $k ($(du -h "$boot/$k" | cut -f1))" \
                || v_fail "no kernel image (kernel_2712.img / kernel8.img / ...)"
    ls "$boot"/bcm27*.dtb >/dev/null 2>&1 && v_ok "device tree blobs present" \
                                          || v_fail "no bcm27*.dtb device tree files"
    [ -d "$boot/overlays" ] && v_ok "overlays/ present" || v_warn "overlays/ missing"
    if grep -qE '^\s*auto_initramfs\s*=\s*1' "$boot/config.txt" 2>/dev/null; then
        ls "$boot"/initramfs* >/dev/null 2>&1 && v_ok "initramfs present (auto_initramfs=1)" \
                                              || v_fail "auto_initramfs=1 but no initramfs file"
    fi

    # ---- root= and fstab must point at THIS card --------------------------
    echo "  partition identity"
    diskid=$(sfdisk --disk-id "$NBD_DEV" 2>/dev/null | sed 's/^0x//')
    cmdroot=$(tr ' ' '\n' < "$boot/cmdline.txt" 2>/dev/null | sed -n 's/^root=//p' | head -1)
    pnum="${rp##*p}"
    case "$cmdroot" in
        PARTUUID=*)
            if [ "${cmdroot#PARTUUID=}" = "${diskid}-0${pnum}" ]; then
                v_ok "cmdline.txt root=$cmdroot matches this card"
            else
                v_fail "cmdline.txt root=$cmdroot but this card's root is PARTUUID=${diskid}-0${pnum}"
            fi ;;
        UUID=*)
            [ "${cmdroot#UUID=}" = "$(blkid -o value -s UUID "$rp")" ] \
                && v_ok "cmdline.txt root=$cmdroot matches" \
                || v_fail "cmdline.txt root=$cmdroot does not match the root filesystem UUID" ;;
        LABEL=*)
            [ "${cmdroot#LABEL=}" = "$(blkid -o value -s LABEL "$rp")" ] \
                && v_ok "cmdline.txt root=$cmdroot matches" \
                || v_fail "cmdline.txt root=$cmdroot does not match the root filesystem label" ;;
        /dev/*) v_ok "cmdline.txt root=$cmdroot (device path, not checked)" ;;
        "")     v_fail "cmdline.txt has no root= parameter" ;;
        *)      v_warn "cmdline.txt root=$cmdroot (unrecognised form)" ;;
    esac
    if [ -s "$root/etc/fstab" ]; then
        local line spec mp ok=1
        while read -r spec mp _; do
            case "$spec" in ''|'#'*) continue ;; esac
            case "$spec" in
                PARTUUID=*) case "${spec#PARTUUID=}" in "${diskid}-0"[0-9]) ;; *) v_fail "fstab: $spec ($mp) is not on this card"; ok=0 ;; esac ;;
                UUID=*) [ "${spec#UUID=}" = "$(blkid -o value -s UUID "$bp")" ] || [ "${spec#UUID=}" = "$(blkid -o value -s UUID "$rp")" ] \
                            || { v_fail "fstab: $spec ($mp) matches neither partition"; ok=0; } ;;
            esac
        done < "$root/etc/fstab"
        [ "$ok" = 1 ] && v_ok "fstab entries all resolve to this card"
    else
        v_fail "/etc/fstab missing or empty"
    fi

    # ---- kernel <-> modules -----------------------------------------------
    echo "  kernel and modules"
    if [ -n "$k" ]; then
        kver=$( (zcat "$boot/$k" 2>/dev/null || cat "$boot/$k") | grep -a -m1 -oE 'Linux version [^ ]+' | awk '{print $3}')
        if [ -z "$kver" ]; then
            v_warn "could not read a version string from $k"
        elif [ -f "$root/lib/modules/$kver/modules.dep" ] || [ -f "$root/usr/lib/modules/$kver/modules.dep" ]; then
            v_ok "kernel $kver has matching /lib/modules/$kver"
        else
            v_fail "kernel $kver but no /lib/modules/$kver on the root filesystem (interrupted upgrade?)"
            ls -d "$root"/lib/modules/*/ 2>/dev/null | sed 's|.*/modules/||;s|/$||' | sed 's/^/        have: /'
        fi
    fi

    # ---- boot partition files vs their dpkg-owned originals ----------------
    # On Pi OS the kernel, initramfs, DTBs and overlays on the boot partition
    # are copies of files under /boot and /usr/lib/linux-image-* on the root
    # filesystem, which dpkg can verify. Comparing them verifies the boot
    # partition's contents, not just its FAT structure.
    if [ -n "$kver" ]; then
        local src="$root/boot/vmlinuz-$kver" li="$root/usr/lib/linux-image-$kver" n=0 bad=0 f b
        if [ -f "$src" ] && [ -n "$k" ]; then
            cmp -s "$src" "$boot/$k" && v_ok "$k is byte-identical to /boot/vmlinuz-$kver" \
                                     || v_fail "$k differs from /boot/vmlinuz-$kver (damaged copy of the kernel)"
        fi
        src="$root/boot/initrd.img-$kver"
        if [ -f "$src" ]; then
            for f in "$boot"/initramfs*; do
                [ -f "$f" ] || continue
                cmp -s "$src" "$f" && v_ok "$(basename "$f") is byte-identical to /boot/initrd.img-$kver" \
                                   || v_fail "$(basename "$f") differs from /boot/initrd.img-$kver (damaged initramfs)"
            done
        fi
        if [ -d "$li/broadcom" ]; then
            for f in "$li"/broadcom/*.dtb "$li"/overlays/*; do
                [ -f "$f" ] || continue
                case "$f" in */broadcom/*) b="$boot/$(basename "$f")" ;; *) b="$boot/overlays/$(basename "$f")" ;; esac
                [ -f "$b" ] || continue
                n=$((n+1)); cmp -s "$f" "$b" || { bad=$((bad+1)); echo "        differs: ${b#$boot/}"; }
            done
            [ "$bad" -eq 0 ] && v_ok "$n device tree and overlay files match their originals" \
                             || v_fail "$bad of $n device tree/overlay files differ from their originals"
        fi
    fi

    # ---- did fsck.fat cut anything out of the boot partition? --------------
    # The firmware files (start*.elf, fixup*.dat, bootcode.bin) come from the
    # raspi-firmware package and are copied to the boot partition, so every
    # file dpkg installed should be there, byte for byte. Anything fsck.fat
    # could not reconcile it deletes; orphaned clusters end up as FSCK*.REC.
    local rec fw="$root/usr/lib/raspi-firmware" fmiss=0 fdiff=0 fn=0
    rec=$(ls "$boot"/FSCK*.REC "$boot"/fsck*.rec 2>/dev/null | wc -l)
    [ "$rec" -gt 0 ] && v_fail "$rec FSCK*.REC file(s) on the boot partition: fsck.fat orphaned data here, something was cut loose"
    if [ -d "$fw" ]; then
        for f in "$fw"/*; do
            [ -f "$f" ] || continue
            fn=$((fn+1)); b="$boot/$(basename "$f")"
            if [ ! -f "$b" ]; then fmiss=$((fmiss+1)); echo "        missing: $(basename "$f")"
            elif ! cmp -s "$f" "$b"; then fdiff=$((fdiff+1)); echo "        differs: $(basename "$f")"; fi
        done
        if [ "$fmiss" -eq 0 ] && [ "$fdiff" -eq 0 ]; then v_ok "all $fn firmware files (start*.elf, fixup*.dat, bootcode.bin) present and identical to raspi-firmware"
        else v_fail "firmware files on the boot partition: $fmiss missing, $fdiff differ (compared with /usr/lib/raspi-firmware)"; fi
    fi
    # the Pi 5 needs its own DTB by name; report it specifically
    if ls "$boot"/bcm2712*.dtb >/dev/null 2>&1 || [ -f "$boot/kernel_2712.img" ]; then
        [ -f "$boot/bcm2712-rpi-5-b.dtb" ] && v_ok "bcm2712-rpi-5-b.dtb present (Pi 5)" || v_fail "bcm2712-rpi-5-b.dtb missing: a Pi 5 will not boot this card"
    fi
    # and a full listing for the record, so a damaged card can be compared with a good one
    echo "        boot partition holds $(find "$boot" -type f -not -path '*/.*' | wc -l) files, $(du -sh "$boot" | cut -f1)"

    # ---- init and essential files ----------------------------------------
    echo "  root filesystem"
    if [ -x "$root/usr/lib/systemd/systemd" ] || [ -x "$root/lib/systemd/systemd" ] || [ -e "$root/sbin/init" ]; then
        v_ok "init (systemd) present"
    else
        v_fail "no /sbin/init or systemd binary"
    fi
    for f in etc/passwd etc/group etc/shadow etc/hostname etc/hosts etc/machine-id; do
        [ -s "$root/$f" ] && continue
        v_fail "/$f missing or empty"
    done
    local hk=0 hz=0
    for f in "$root"/etc/ssh/ssh_host_*_key; do
        [ -e "$f" ] || continue
        hk=$((hk+1)); [ -s "$f" ] || hz=$((hz+1))
    done
    if [ "$hk" -eq 0 ]; then v_warn "no SSH host keys (sshd will regenerate, but known_hosts will change)"
    elif [ "$hz" -gt 0 ]; then v_fail "$hz of $hk SSH host keys are zero-length - sshd will not start"
    else v_ok "$hk SSH host keys intact"; fi

    # macOS writes Spotlight/fsevents metadata onto any FAT volume it mounts.
    # Harmless to the Pi, but not something to scan or mistake for damage.
    local macjunk
    macjunk=$(find "$boot" -maxdepth 1 \( -name '.Spotlight-V100' -o -name '.fseventsd' -o -name '.Trashes' -o -name '.DS_Store' -o -name '._*' \) 2>/dev/null | wc -l)
    [ "$macjunk" -gt 0 ] && v_warn "macOS left $macjunk Spotlight/fsevents item(s) on the boot partition (harmless; it mounted the card)"

    # Files that exist but are all NUL bytes: the classic ext4 crash artefact.
    local nulls
    nulls=$(find "$root/etc" "$boot" -type f -size +0 \
                -not -path '*/.Spotlight-V100/*' -not -path '*/.fseventsd/*' -not -path '*/.Trashes/*' -not -name '._*' \
                2>/dev/null | head -5000 | while read -r f; do
        [ "$(head -c 4096 "$f" | tr -d '\000' | wc -c)" -eq 0 ] && { f="${f#$root}"; echo "${f#$boot/}"; }
    done)
    if [ -n "$nulls" ]; then
        v_fail "$(wc -l <<<"$nulls") file(s) in /etc or boot are NUL-filled (written during the power loss):"
        sed 's/^/        /' <<<"$nulls" | head -15
    else
        v_ok "no NUL-filled files in /etc or the boot partition"
    fi

    # ---- package manager state --------------------------------------------
    echo "  packages"
    if [ -d "$root/var/lib/dpkg/updates" ] && [ -n "$(ls -A "$root/var/lib/dpkg/updates" 2>/dev/null | grep -v '^tmp')" ]; then
        v_fail "dpkg was interrupted mid-operation - on the Pi run: sudo dpkg --configure -a"
    fi
    if [ -s "$root/var/lib/dpkg/status" ]; then
        local bad
        bad=$(awk '/^Package:/{p=$2} /^Status:/{s=$2" "$3" "$4; if (s!="install ok installed" && s!="deinstall ok config-files" && s!="hold ok installed" && s!="purge ok not-installed") print p" ("s")"}' "$root/var/lib/dpkg/status")
        if [ -n "$bad" ]; then
            v_fail "$(wc -l <<<"$bad") package(s) not fully installed:"
            sed 's/^/        /' <<<"$bad" | head -15
        else
            v_ok "all $(grep -c '^Package:' "$root/var/lib/dpkg/status") packages in a consistent state"
        fi
    else
        v_warn "no dpkg status file (not a Debian-based OS?)"
    fi

    # ---- what fsck orphaned -------------------------------------------------
    local lf
    lf=$(ls -A "$root/lost+found" 2>/dev/null | wc -l)
    if [ "$lf" -gt 0 ]; then
        v_warn "lost+found holds $lf item(s) fsck could not place:"
        ls -la "$root/lost+found" | tail -n +4 | awk '{print "        "$5"\t"$NF}' | head -10
    else
        v_ok "lost+found is empty"
    fi

    # ---- deep: every package file vs dpkg's md5sums ------------------------
    [ "$deep" = deep ] || { echo "  (run with --deep to checksum every package file)"; return; }
    echo "  package file checksums (this reads most of the card)"
    local info="$root/var/lib/dpkg/info" list=/tmp/verify.md5 conf=/tmp/verify.conffiles res
    [ -d "$info" ] || { v_warn "no dpkg info directory"; return; }
    cat "$info"/*.conffiles 2>/dev/null | sed 's|^/||' | sort -u > "$conf"
    cat "$info"/*.md5sums 2>/dev/null | awk 'NF==2' > "$list.all"
    awk 'NR==FNR{c[$1]=1;next} !($2 in c)' "$conf" "$list.all" > "$list"
    # md5sum -c is silent until the end, so check in chunks and report as we go.
    local total chunk=400 done=0 res="" part
    total=$(wc -l < "$list")
    split -l "$chunk" "$list" /tmp/verify.part.
    for part in /tmp/verify.part.*; do
        res="$res$(cd "$root" && md5sum -c --quiet "$part" 2>&1 | grep -v WARNING)
"
        done=$(( done + $(wc -l < "$part") ))
        [ "$done" -gt "$total" ] && done=$total
        printf '\r        checked %d / %d files' "$done" "$total" >&2
    done
    printf '\r%40s\r' '' >&2
    rm -f /tmp/verify.part.*
    res=$(printf '%s' "$res" | grep .)

    # A changed file is not a boot blocker in itself. Missing or changed files
    # under the directories the boot needs are; the rest are integrity warnings.
    # EXTERNALLY-MANAGED is the PEP 668 marker people edit on purpose.
    local missing changed_sys changed_other
    missing=$(grep -E 'No such file' <<<"$res" | sed 's/^md5sum: //;s/: No such file.*//')
    changed_sys=$(grep -E ': FAILED$' <<<"$res" | sed 's/: FAILED$//' | grep -E '^(usr/)?(bin|sbin|lib|lib64|lib32|libx32)/' | grep -v 'EXTERNALLY-MANAGED')
    changed_other=$(grep -E ': FAILED$' <<<"$res" | sed 's/: FAILED$//' | grep -vE '^(usr/)?(bin|sbin|lib|lib64|lib32|libx32)/|EXTERNALLY-MANAGED')
    local nmiss nsys noth
    nmiss=$(grep -c . <<<"$missing"); nsys=$(grep -c . <<<"$changed_sys"); noth=$(grep -c . <<<"$changed_other")
    grep -q 'EXTERNALLY-MANAGED' <<<"$res" && v_warn "usr/lib/python3.11/EXTERNALLY-MANAGED differs (the PEP 668 pip marker, usually edited on purpose)"
    if [ "$nmiss" -eq 0 ] && [ "$nsys" -eq 0 ] && [ "$noth" -eq 0 ]; then
        v_ok "$total package files match their checksums"
        return
    fi
    [ "$nmiss" -gt 0 ] && { v_fail "$nmiss package file(s) missing:"; sed 's/^/        /' <<<"$missing" | head -20; }
    [ "$nsys" -gt 0 ]  && { v_fail "$nsys binary/library file(s) differ from what dpkg installed:"; sed 's/^/        /' <<<"$changed_sys" | head -20; }
    [ "$noth" -gt 0 ]  && { v_warn "$noth other package file(s) differ (data or docs; edited, or damaged):"; sed 's/^/        /' <<<"$changed_other" | head -20; }
    if [ "$nmiss" -gt 0 ] || [ "$nsys" -gt 0 ]; then
        echo "        reinstall the owning packages on the Pi: dpkg -S <file> ; apt reinstall <pkg>"
    fi
}

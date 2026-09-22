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

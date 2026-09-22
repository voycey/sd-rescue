# Rescue toolbox for Raspberry Pi SD cards.
# Runs inside the colima VM, privileged, holding the NBD connection to the
# card that is physically attached to the macOS host.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        nbd-client \
        e2fsprogs \
        dosfstools \
        partclone \
        gddrescue \
        util-linux \
        parted \
        fdisk \
        zstd \
        file \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY rescue-lib.sh /usr/local/lib/rescue-lib.sh

CMD ["sleep", "infinity"]

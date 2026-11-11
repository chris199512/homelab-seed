FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils jq \
        fdisk util-linux mount e2fsprogs dosfstools \
        qemu-user-static \
    && rm -rf /var/lib/apt/lists/*

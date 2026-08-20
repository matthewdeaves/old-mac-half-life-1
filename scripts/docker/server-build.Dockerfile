# Build environment for the Linux dedicated server release.
#
# Debian 11 on purpose, not something current. glibc symbol versioning only
# works one way: a binary built against 2.31 runs on 2.35, never the reverse.
# Debian 11 gives glibc 2.31, so the release runs on Ubuntu 20.04 and anything
# newer, which covers every distro likely to end up on a VPS.
#
# This is the same argument as the 10.6 floor on the Intel Mac slice, and the
# 10.3.9 floor on the PowerPC ones: build against the oldest thing you intend
# to support, and everything above it comes free. docs/adr/0010.
FROM debian:11

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      file \
      python3 \
      pkg-config \
      procps \
      iproute2 \
 && rm -rf /var/lib/apt/lists/*

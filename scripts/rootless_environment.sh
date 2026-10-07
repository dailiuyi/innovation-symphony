#!/usr/bin/env bash
# Run inside the disposable Ubuntu rootfs, never on the host.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bash git python3 ca-certificates curl build-essential pkg-config \
  libtinfo6 libssl3t64 zlib1g libstdc++6
apt-get clean

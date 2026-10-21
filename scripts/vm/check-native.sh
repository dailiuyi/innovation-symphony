#!/usr/bin/env bash
# Native gate in the dedicated VM. The isolation itself is shared with CI.
set -euo pipefail
[[ $EUID == 0 && $# == 1 ]]
[[ $(cat /etc/symphony-vm) == symphony-local-ubuntu2404-amd64 ]]
[[ $(systemd-detect-virt --vm) == kvm || $(systemd-detect-virt --vm) == qemu ]]
exec bash "$(dirname -- "$(realpath -- "$0")")/isolated-check.sh" elma /usr/local/bin:/usr/bin:/bin "$1" /usr/bin/docker-init

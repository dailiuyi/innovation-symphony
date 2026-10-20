#!/usr/bin/env bash
# Native gate in the dedicated VM, with a disposable account HOME and PID namespace.
set -euo pipefail
[[ $EUID == 0 && $# == 1 ]]
[[ $(cat /etc/symphony-vm) == symphony-local-ubuntu2404-amd64 ]]
[[ $(systemd-detect-virt --vm) == kvm || $(systemd-detect-virt --vm) == qemu ]]
vm_repository=$(realpath -- "$1")
[[ -f $vm_repository/elixir/Makefile && -f $vm_repository/scripts/clean_check.py ]]
vm_gate_config=$(mktemp -d /var/tmp/symphony-native-check.XXXXXXXX)
chmod 0755 "$vm_gate_config"
printf '{lookup, [file, dns]}.\n' > "$vm_gate_config/inetrc"
chmod 0644 "$vm_gate_config/inetrc"
trap 'rm -- "$vm_gate_config/inetrc"; rmdir -- "$vm_gate_config"' EXIT
# OTP's external native DNS helper is intentionally not dumpable. Use Erlang's
# DNS resolver so it cannot make every retention fixture look uninspectable.
# Production resolver settings remain unchanged.
unshare --mount --pid --fork --mount-proc -- /usr/bin/docker-init -- runuser -u elma -- \
  env -i HOME=/home/elma USER=elma LOGNAME=elma PATH=/usr/local/bin:/usr/bin:/bin \
  ERL_INETRC="$vm_gate_config/inetrc" HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 \
  HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt \
  /bin/bash -c 'cd -- "$1/elixir"; exec python3 "$1/scripts/clean_check.py" -- make all' \
  symphony-native-check "$vm_repository"

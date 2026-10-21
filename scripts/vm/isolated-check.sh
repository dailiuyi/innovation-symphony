#!/usr/bin/env bash
# `make all` as an unprivileged user in a private PID namespace with a disposable HOME.
# Shared by the VM gate and CI; each caller proves its own environment before delegating.
set -euo pipefail
refuse() { echo "isolated-check: $*" >&2; exit 2; }
[[ $EUID == 0 && $# == 4 ]] || refuse "usage: run as root with USER PATH REPOSITORY INIT"
check_user=$1
check_path=$2
check_repository=$(realpath -- "$3")
check_init=$4
[[ $check_user != root ]] || refuse "the check must not run as root"
[[ -x $check_init ]] || refuse "$check_init is required to reap orphans"
check_home=$(getent passwd "$check_user" | cut -d: -f6)
[[ -d $check_home ]] || refuse "no home directory for $check_user"
[[ -f $check_repository/elixir/Makefile && -f $check_repository/scripts/clean_check.py ]] \
  || refuse "$check_repository is not a Symphony checkout"
gate_config=$(mktemp -d /var/tmp/symphony-native-check.XXXXXXXX)
chmod 0755 "$gate_config"
printf '{lookup, [file, dns]}.\n' > "$gate_config/inetrc"
chmod 0644 "$gate_config/inetrc"
trap 'rm -- "$gate_config/inetrc"; rmdir -- "$gate_config"' EXIT
# A same-uid process outside the namespace (for example a user manager helper)
# can be non-dumpable, which makes every retention fixture look uninspectable.
# The init program (docker-init in the VM, tini on runners) reaps orphans, so
# leftover zombies cannot do the same.
# OTP's external native DNS helper is intentionally not dumpable either. Use
# Erlang's DNS resolver so it cannot make every retention fixture look
# uninspectable. Production resolver settings remain unchanged.
unshare --mount --pid --fork --mount-proc -- "$check_init" -- runuser -u "$check_user" -- \
  env -i HOME="$check_home" USER="$check_user" LOGNAME="$check_user" PATH="$check_path" \
  ${SYMPHONY_TEST_CODEX:+SYMPHONY_TEST_CODEX="$SYMPHONY_TEST_CODEX"} \
  ${MIX_HOME:+MIX_HOME="$MIX_HOME"} ${MIX_ARCHIVES:+MIX_ARCHIVES="$MIX_ARCHIVES"} \
  ${MIX_REBAR3:+MIX_REBAR3="$MIX_REBAR3"} ${HEX_HOME:+HEX_HOME="$HEX_HOME"} \
  ERL_INETRC="$gate_config/inetrc" HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 \
  HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt \
  /bin/bash -c 'cd -- "$1/elixir"; exec python3 "$1/scripts/clean_check.py" -- make all' \
  symphony-native-check "$check_repository"

#!/usr/bin/env bash
# Explicit guest-only one-time bootstrap; parent owns running/installing this.
set -euo pipefail
if [[ ${1-} != --apply || $# != 2 ]]; then
  echo 'Usage: sudo bash bootstrap-guest.sh --apply /absolute/verified-artifacts.json' >&2
  exit 2
fi
[[ $EUID == 0 ]]
[[ $(systemd-detect-virt --vm) == kvm || $(systemd-detect-virt --vm) == qemu ]]
[[ $(cat /etc/symphony-vm) == symphony-local-ubuntu2404-amd64 ]]
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(uname -m) == x86_64 ]]
id elma >/dev/null
vm_script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
vm_manifest=$(realpath -- "$2")
export PYTHONDONTWRITEBYTECODE=1
# Verify ALL inputs before apt, directory creation, or package extraction.
python3 "$vm_script_dir/artifacts.py" verify "$vm_manifest"
vm_prefix=/opt/symphony
vm_config=/var/lib/innovation-symphony
vm_runtime=/var/tmp/innovation-symphony-linux-runtime
for vm_component in otp-28.5.0.7 elixir-1.19.6 node-24.21.0 codex-0.163.0; do
  [[ ! -e $vm_prefix/$vm_component ]]
done
for vm_link in erl erlc escript elixir elixirc iex mix node npm npx codex; do
  [[ ! -e /usr/local/bin/$vm_link && ! -L /usr/local/bin/$vm_link ]]
done
[[ ! -e /opt/codex && ! -L /opt/codex ]]
[[ ! -e $vm_config/toolchain-receipt.json ]]
[[ $(df --output=avail -B1 /var/tmp | tail -1) -ge 5368709120 ]]
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential autoconf m4 pkg-config \
  libncurses-dev libssl-dev libssh-dev ca-certificates git curl xz-utils unzip \
  docker.io openjdk-21-jdk-headless python3.12 python3.12-venv \
  bubblewrap apparmor-profiles apparmor-utils
# Ubuntu 24.04 permits bwrap user namespaces through this packaged profile;
# retain the global unprivileged-userns restriction.
install -m 0644 /usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/bwrap-userns-restrict
apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
install -d -m 0755 "$vm_prefix" "$vm_config"
install -d -o elma -g elma -m 0700 "$vm_runtime" "$vm_runtime/tmp" "$vm_runtime/state"
vm_build=$(mktemp -d "$vm_config/bootstrap-XXXXXXXX")
# Failed builds remain for diagnosis; no global prune or automatic removal.
for vm_component in otp elixir node codex; do
  python3 "$vm_script_dir/artifacts.py" extract "$vm_manifest" \
    --component "$vm_component" --target "$vm_build/$vm_component" --apply
done
cd "$vm_build/otp"
./configure --prefix="$vm_prefix/otp-28.5.0.7" --without-javac --without-wx --without-odbc
make -j8
make install
export PATH="$vm_prefix/otp-28.5.0.7/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[[ $(cat "$vm_prefix/otp-28.5.0.7/lib/erlang/releases/28/OTP_VERSION") == 28.5.0.7 ]]
cd "$vm_build/elixir"
make -j8
make PREFIX="$vm_prefix/elixir-1.19.6" install
install -d "$vm_prefix/codex-0.163.0/bin"
python3 "$vm_script_dir/artifacts.py" install-node "$vm_build/node" --target "$vm_prefix/node-24.21.0" --apply
vm_codex_entry=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["codex"]["entry"])' "$vm_manifest")
[[ -f $vm_build/codex/$vm_codex_entry && ! -L $vm_build/codex/$vm_codex_entry ]]
install -m 0755 "$vm_build/codex/$vm_codex_entry" "$vm_prefix/codex-0.163.0/bin/codex"
python3 "$vm_script_dir/artifacts.py" install-codex-helper "$vm_manifest" \
  --target "$vm_prefix/codex-0.163.0/bin/codex-code-mode-host" --apply
for vm_link in erl erlc escript; do
  ln -s "$vm_prefix/otp-28.5.0.7/bin/$vm_link" "/usr/local/bin/$vm_link"
done
for vm_link in elixir elixirc iex mix; do
  ln -s "$vm_prefix/elixir-1.19.6/bin/$vm_link" "/usr/local/bin/$vm_link"
done
for vm_link in node npm npx; do
  ln -s "$vm_prefix/node-24.21.0/bin/$vm_link" "/usr/local/bin/$vm_link"
done
ln -s "$vm_prefix/codex-0.163.0/bin/codex" /usr/local/bin/codex
ln -s "$vm_prefix/codex-0.163.0/bin/codex" /opt/codex
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
# Verify native escript startup through the same PATH used by the services.
vm_escript_probe=$(mktemp "$vm_config/escript-probe-XXXXXXXX")
cat > "$vm_escript_probe" <<'EOF'
#!/usr/bin/env escript
main(_) -> io:format("symphony-escript-ok~n").
EOF
chmod 0755 "$vm_escript_probe"
[[ $(runuser -u elma -- env -i HOME=/home/elma PATH=/usr/local/bin:/usr/bin:/bin "$vm_escript_probe") == symphony-escript-ok ]]
# End native escript probe; preserve the small source file for audit.
elixir --version | grep -F 'Elixir 1.19.6'
[[ $(runuser -u elma -- env -i HOME=/home/elma PATH=/usr/local/bin:/usr/bin:/bin node --version) == v24.21.0 ]]
[[ $(runuser -u elma -- env -i HOME=/home/elma PATH=/usr/local/bin:/usr/bin:/bin codex --version) == 'codex-cli 0.163.0' ]]
# Zero-model probe: a writable fixture must become read-only inside Codex.
install -d -o elma -g elma -m 0700 "$vm_runtime/sandboxes"
vm_sandbox_probe=$(mktemp -d "$vm_runtime/sandboxes/run-bootstrap-probe-XXXXXXXX")
chown elma:elma "$vm_sandbox_probe"
install -d -o elma -g elma -m 0700 "$vm_sandbox_probe/codex-home"
pushd "$vm_sandbox_probe" >/dev/null
runuser -u elma -- env -i HOME="$vm_sandbox_probe" PATH=/usr/local/bin:/usr/bin:/bin \
  /bin/sh -c 'printf "symphony-sandbox-original\n" > "$1"' sh "$vm_sandbox_probe/write-test"
runuser -u elma -- env -i HOME="$vm_sandbox_probe" CODEX_HOME="$vm_sandbox_probe/codex-home" PATH=/usr/local/bin:/usr/bin:/bin \
  codex sandbox -c 'sandbox_mode="read-only"' -- /usr/bin/true
vm_sandbox_result=$(runuser -u elma -- env -i HOME="$vm_sandbox_probe" CODEX_HOME="$vm_sandbox_probe/codex-home" PATH=/usr/local/bin:/usr/bin:/bin \
  codex sandbox -c 'sandbox_mode="read-only"' -- /usr/bin/python3 -c '
import errno, pathlib, sys
try:
    pathlib.Path(sys.argv[1]).write_text("unexpected-write\n")
except OSError as error:
    if error.errno not in (errno.EACCES, errno.EROFS):
        raise
    print("symphony-codex-read-only-ok")
else:
    raise SystemExit("Codex read-only sandbox permitted a write")
' "$vm_sandbox_probe/write-test")
[[ $vm_sandbox_result == symphony-codex-read-only-ok ]]
[[ $(cat "$vm_sandbox_probe/write-test") == symphony-sandbox-original ]]
popd >/dev/null
# End zero-model probe; retain its isolated home and fixture for diagnosis.
python3.12 --version
java -version
python3 "$vm_script_dir/artifacts.py" receipt "$vm_config/toolchain-receipt.json" --apply
# Docker is rootful and reachable only through this guest-local Unix socket.
install -d /etc/systemd/system/docker.service.d
[[ ! -e /etc/systemd/system/docker.service.d/symphony-local.conf ]]
cat > /etc/systemd/system/docker.service.d/symphony-local.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --host=unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock
EOF
usermod -aG docker elma
systemctl daemon-reload
systemctl enable docker
systemctl restart docker
docker --host unix:///var/run/docker.sock info >/dev/null
# No Symphony services, model calls or credential provisioning here.
[[ ! -e $vm_config/view-venv ]]
python3.12 -m venv "$vm_config/view-venv"
chown -R elma:elma "$vm_config/view-venv"
[[ ! -e /etc/tmpfiles.d/symphony-runtime.conf ]]
cat > /etc/tmpfiles.d/symphony-runtime.conf <<'EOF'
# Retain task workspaces, TMPDIR, transcripts, receipts and recovery evidence.
x /var/tmp/innovation-symphony-linux-runtime - - - - -
EOF
echo 'Guest toolchain installed; native services/configuration and authentication remain parent-owned.'

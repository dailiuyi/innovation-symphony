#!/usr/bin/env bash
# Fail-closed Bubblewrap runner for coder sessions and controller checks.
set -Eeuo pipefail
umask 077

readonly CGROUP_PARENT=/sys/fs/cgroup/innovation-symphony-execution
readonly SCRIPT_PATH="$(realpath -e -- "$0")"

die() { printf 'execution_sandbox: %s\n' "$*" >&2; exit 2; }
log() { printf 'execution_sandbox: %s\n' "$*" >&2; }
usage() {
  cat <<'EOF'
Usage: execution_sandbox.sh --check
  execution_sandbox.sh --workspace DIR --scratch-root DIR --toolchain DIR --codex FILE
    --trusted-root DIR --dependencies DIR --baseline DIR --evidence DIR
    --timeout-seconds N --memory-mb N --disk-mb N --pids N --cpus N
    [--read-only-workspace true] -- COMMAND [ARG...]

Runs in a private offline namespace. /workspace is a bounded tmpfs copy and .git is read-only.
Standard streams pass through. Host-only result.json and export/ are written after cleanup.
EOF
}
check_runtime() {
  [[ "$(uname -s)" == Linux ]] || die 'Linux is required'
  (( EUID == 0 )) || die 'root is required for bounded tmpfs and cgroups'
  local app
  for app in bwrap unshare timeout python3 tar ip; do command -v "$app" >/dev/null || die "$app is not installed"; done
  [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" == cgroup2fs ]] || die 'cgroup v2 is required'
  for app in cpu memory pids; do grep -qw "$app" /sys/fs/cgroup/cgroup.controllers || die "cgroup controller unavailable: $app"; done
  [[ -w /sys/fs/cgroup/cgroup.subtree_control ]] || die 'writable cgroup v2 delegation is required'
  [[ -d /usr && -d /bin && -d /lib && -d /etc/ssl/certs ]] || die 'runtime/CA mounts are incomplete'
}
real_dir() { [[ -d "$1" ]] || die "expected directory: $1"; realpath -e -- "$1"; }
real_file() { [[ -f "$1" ]] || die "expected regular file: $1"; realpath -e -- "$1"; }
write_result() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" <<'PY'
import json, os, sys, tempfile
root, cg, status, cleanup, exported, outcome, started, ended = sys.argv[1:]
try:
    populated = any(x.strip() == 'populated 1' for x in open(os.path.join(cg, 'cgroup.events')))
except OSError:
    populated = True
value = {'scratch_root': os.path.realpath(root), 'exit_status': int(status),
         'cleanup_complete': cleanup == 'true' and not populated,
         'descendants_cleaned': cleanup == 'true' and not populated,
         'background_output_closed': True,
         'background_output_drain_grace_seconds': 1,
         'export_complete': exported == 'true', 'outcome': outcome,
         'started_at_epoch': int(started), 'ended_at_epoch': int(ended),
         'output_limit_bytes': 67108864}
def read_text(name):
    try: return open(os.path.join(cg, name), encoding='utf-8').read().strip()
    except OSError: return None
def read_events(name):
    raw = read_text(name) or ''
    return {key: int(value) for key, value in (line.split() for line in raw.splitlines())}
value['resource_limits'] = {'cpu_max': read_text('cpu.max'), 'memory_max_bytes': read_text('memory.max'),
                           'pids_max': read_text('pids.max')}
value['resource_events'] = {'memory': read_events('memory.events'), 'pids': read_events('pids.events')}
fd, temp = tempfile.mkstemp(prefix='.result-', dir=root)
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(value, f, sort_keys=True); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(temp, os.path.join(root, 'result.json'))
PY
}
export_workspace() {
  python3 "$(dirname -- "$SCRIPT_PATH")/sandbox_artifacts.py" "$1" "$2" "$3"
}
wait_cgroup_empty() {
  local i
  for i in $(seq 1 100); do
    if grep -q '^populated 0$' "$1/cgroup.events"; then return 0; fi
    sleep .05
  done
  return 1
}
kill_cgroup_tasks() { printf '1\n' > "$1/cgroup.kill" 2>/dev/null || true; }
run_bounded_prep() {
  local remaining pid status
  remaining=$((deadline_tick - SECONDS))
  if (( remaining <= 0 )); then prep_status=124; prep_clean=true; return 1; fi
  (
    printf '%s\n' "$BASHPID" > "$cg/cgroup.procs"
    exec timeout --foreground --signal=TERM --kill-after=1s "$remaining" "$@" >/dev/null 2>&1
  ) &
  pid=$!
  if wait "$pid"; then status=0; else status=$?; fi
  kill_cgroup_tasks "$cg"
  if wait_cgroup_empty "$cg"; then prep_clean=true; else prep_clean=false; fi
  prep_status=$status
  [[ $status -eq 0 && $prep_clean == true ]]
}
supervisor() {
  local workspace= scratch= private= cg= toolchain= codex= scripts= deps= baseline= evidence= disk= timeout_s= host_netns= read_only=false
  while (($#)); do
    case "$1" in
      --workspace) workspace=$2; shift 2;; --scratch-root) scratch=$2; shift 2;; --private) private=$2; shift 2;;
      --cgroup) cg=$2; shift 2;; --toolchain) toolchain=$2; shift 2;; --codex) codex=$2; shift 2;;
      --scripts) scripts=$2; shift 2;; --dependencies) deps=$2; shift 2;; --baseline) baseline=$2; shift 2;;
      --evidence) evidence=$2; shift 2;; --disk-mb) disk=$2; shift 2;; --timeout-seconds) timeout_s=$2; shift 2;;
      --host-netns) host_netns=$2; shift 2;; --cpus) cpus=$2; shift 2;; --pids) pids=$2; shift 2;;
      --read-only-workspace) read_only=$2; shift 2;;
      --) shift; break;; *) log "invalid supervisor argument: $1"; return 2;;
    esac
  done
  local started ended pid code=125 clean=false exported=false outcome=failed
  local deadline_tick prep_status=125 prep_clean=false remaining
  started=$(date +%s)
  deadline_tick=$((SECONDS + timeout_s))
  if [[ -z "$host_netns" || "$(readlink /proc/self/ns/net)" == "$host_netns" ]]; then
    write_result "$scratch" "$cg" 125 true false network_namespace_not_private "$started" "$(date +%s)"; return 1
  fi
  # Configure loopback before Bubblewrap's AppArmor child profile drops
  # capabilities. The supervisor already owns a private network namespace;
  # the task shares only that namespace, never the host network.
  if ! ip link set lo up >/dev/null 2>&1; then
    write_result "$scratch" "$cg" 125 true false loopback_setup_failed "$started" "$(date +%s)"; return 1
  fi
  if ! mount -t tmpfs -o "size=${disk}m,nr_inodes=$((disk * 128)),mode=0700,nosuid,nodev" tmpfs "$private"; then
    write_result "$scratch" "$cg" 125 true false tmpfs_mount_failed "$started" "$(date +%s)"; return 1
  fi
  if ! mkdir -p "$private/workspace" "$private/home/.codex" "$private/home/.mix" "$private/home/.cache/elixir_make" "$private/tmp"; then
    write_result "$scratch" "$cg" 125 true false workspace_setup_failed "$started" "$(date +%s)"; return 1
  fi
  if ! chmod 0700 "$private/home" "$private/home/.codex" "$private/tmp"; then
    write_result "$scratch" "$cg" 125 true false workspace_setup_failed "$started" "$(date +%s)"; return 1
  fi
  if ! mkdir -p "$private/workspace/.git" "$private/workspace/elixir/deps"; then
    write_result "$scratch" "$cg" 125 true false workspace_setup_failed "$started" "$(date +%s)"; return 1
  fi
  if ! cat > "$private/relay.py" <<'PYRELAY'
import os, selectors, subprocess, sys, time
limit = 67108864
argv = sys.argv[1:]
p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
s = selectors.PollSelector(); os.set_blocking(sys.stdin.fileno(), False)
for fd, dst in ((p.stdout.fileno(), sys.stdout.fileno()), (p.stderr.fileno(), sys.stderr.fileno())):
    os.set_blocking(fd, False); s.register(fd, selectors.EVENT_READ, ('out', dst))
s.register(sys.stdin.fileno(), selectors.EVENT_READ, ('in', p.stdin)); total=0; exceeded=False; drain_expired=False; drain_deadline=None
while s.get_map():
    if p.poll() is not None and sys.stdin.fileno() in s.get_map():
        s.unregister(sys.stdin.fileno())
        try: p.stdin.close()
        except Exception: pass
    if p.poll() is not None:
        if drain_deadline is None: drain_deadline=time.monotonic()+1.0
        elif time.monotonic() >= drain_deadline: drain_expired=True; break
    for key, _ in s.select(.2):
        fd, (kind, dst) = key.fd, key.data
        try: data=os.read(fd,65536)
        except BlockingIOError: continue
        if not data:
            s.unregister(fd)
            if kind=='in':
                try: dst.close()
                except Exception: pass
            continue
        if kind=='in':
            try: dst.write(data); dst.flush()
            except (BrokenPipeError,OSError): s.unregister(fd)
        else:
            prior=total; total+=len(data)
            if total>limit: data=data[:max(0,limit-prior)]; exceeded=True
            try:
                view=memoryview(data)
                while view: n=os.write(dst,view); view=view[n:]
            except OSError: pass
            if exceeded: break
    if exceeded: break
    if drain_expired: break
if exceeded:
    try: p.terminate()
    except OSError: pass
    try: p.wait(timeout=1)
    except subprocess.TimeoutExpired: p.kill()
    raise SystemExit(125)
while p.poll() is None:
    try: p.wait(timeout=.2)
    except subprocess.TimeoutExpired: pass
raise SystemExit(p.returncode if p.returncode>=0 else 128-p.returncode)
PYRELAY
  then
    write_result "$scratch" "$cg" 125 true false relay_setup_failed "$started" "$(date +%s)"
    return 1
  fi
  if ! chmod 0444 "$private/relay.py"; then
    write_result "$scratch" "$cg" 125 true false relay_setup_failed "$started" "$(date +%s)"
    return 1
  fi
  if ! run_bounded_prep /bin/bash -o pipefail -c \
       'tar -C "$1" --exclude=./.git --exclude=./.codex --exclude=./.check-evidence --exclude=./elixir/deps --exclude=./elixir/_build --exclude=./elixir/cover --exclude=./elixir/bin --one-file-system -cf - . | tar -C "$2" -xf -' \
       workspace-copy "$workspace" "$private/workspace"; then
    outcome=workspace_copy_failed
    [[ $prep_status -ne 124 ]] || outcome=preparation_timeout
    write_result "$scratch" "$cg" "$prep_status" "$prep_clean" false "$outcome" "$started" "$(date +%s)"
    return 1
  fi
  if ! run_bounded_prep /bin/cp -a "$deps"/. "$private/workspace/elixir/deps/"; then
    outcome=dependency_seed_failed
    [[ $prep_status -ne 124 ]] || outcome=preparation_timeout
    write_result "$scratch" "$cg" "$prep_status" "$prep_clean" false "$outcome" "$started" "$(date +%s)"
    return 1
  fi
  if [[ -d "$toolchain/cache/elixir_make" ]]; then
    if ! run_bounded_prep /bin/cp -a -- "$toolchain/cache/elixir_make"/. "$private/home/.cache/elixir_make/"; then
      outcome=elixir_make_cache_seed_failed
      [[ $prep_status -ne 124 ]] || outcome=preparation_timeout
      write_result "$scratch" "$cg" "$prep_status" "$prep_clean" false "$outcome" "$started" "$(date +%s)"
      return 1
    fi
  fi
  local -a b=(bwrap --die-with-parent --clearenv --unshare-user --uid 0 --gid 0 --unshare-pid --unshare-uts --unshare-ipc --share-net --cap-drop ALL
    --cap-add CAP_SETUID --cap-add CAP_SETGID --cap-add CAP_SETFCAP
    --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib)
  [[ ! -e /lib64 ]] || b+=(--ro-bind /lib64 /lib64)
  b+=(--ro-bind /etc/ssl/certs /etc/ssl/certs --ro-bind /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
    --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf --ro-bind /etc/passwd /etc/passwd --ro-bind /etc/group /etc/group
    --proc /proc --dev /dev --dir /run)
  if [[ $read_only == true ]]; then b+=(--ro-bind "$private/workspace" /workspace); else b+=(--bind "$private/workspace" /workspace); fi
  b+=(--ro-bind "$workspace/.git" /workspace/.git
    --ro-bind "$toolchain" /opt/toolchain --ro-bind "$codex" /opt/codex --ro-bind "$scripts" /opt/symphony/scripts
    --ro-bind "$deps" /opt/deps --ro-bind "$baseline" /baseline --ro-bind "$evidence" /evidence
    --bind "$private/tmp" /tmp --bind "$private/home" /home/coder --ro-bind "$private/relay.py" /run/symphony-relay.py
    --setenv HOME /home/coder --setenv CODEX_HOME /home/coder/.codex
    --setenv ELIXIR_MAKE_CACHE_DIR /home/coder/.cache/elixir_make
    --setenv PATH /opt/toolchain/data/installs/elixir/1.19.5-otp-28/bin:/opt/toolchain/data/installs/erlang/28.5/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
    --setenv MIX_HOME /home/coder/.mix --setenv MIX_ARCHIVES /opt/toolchain/data/installs/elixir/1.19.5-otp-28/.mix/archives
    --setenv MIX_REBAR3 /opt/toolchain/mix/elixir/1-19-otp-28/rebar3 --setenv HEX_HOME /opt/toolchain/hex --setenv TMPDIR /tmp
    --setenv SYMPHONY_CHECK_CPUS "$cpus" --setenv SYMPHONY_CHECK_PIDS "$pids" --setenv ERL_FLAGS "+S $((cpus < pids / 32 ? cpus : (pids / 32 > 0 ? pids / 32 : 1))):$((cpus < pids / 32 ? cpus : (pids / 32 > 0 ? pids / 32 : 1))) +SDcpu 1:1 +SDio 1" --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8 --setenv TERM dumb --setenv CI 1 --setenv HEX_OFFLINE 1
    --setenv GIT_CONFIG_NOSYSTEM 1 --setenv GIT_CONFIG_GLOBAL /dev/null --chdir /workspace)
  # OTP and trusted PLTs retain their installation prefix; expose the same
  # already-approved read-only toolchain there without mounting its parents.
  b+=(--ro-bind "$toolchain" "$toolchain")
  local child_input
  exec {child_input}<&0
  remaining=$((deadline_tick - SECONDS))
  if (( remaining <= 0 )); then
    code=124
  else
    (
      printf '%s\n' "$BASHPID" > "$cg/cgroup.procs"
      exec timeout --foreground --signal=TERM --kill-after=5s "$remaining" "${b[@]}" /usr/bin/python3 /run/symphony-relay.py "$@"
    ) <&"$child_input" &
    pid=$!
    if wait "$pid"; then code=0; else code=$?; fi
  fi
  if [[ $code -eq 124 ]]; then outcome=timeout
  elif [[ $code -eq 137 ]]; then outcome=resource_limit_or_signal
  elif [[ $code -eq 125 ]]; then outcome=output_limit_or_bootstrap_failure
  elif [[ $code -eq 0 ]]; then outcome=completed
  else outcome=command_failed; fi
  printf '1\n' > "$cg/cgroup.kill" 2>/dev/null || true
  local i
  for i in $(seq 1 100); do if grep -q '^populated 0$' "$cg/cgroup.events"; then clean=true; break; fi; sleep .05; done
  if [[ $clean == true ]] && export_workspace "$private/workspace" "$scratch/export" "$disk"; then exported=true; else outcome=unsafe_or_incomplete_export; fi
  ended=$(date +%s)
  write_result "$scratch" "$cg" "$code" "$clean" "$exported" "$outcome" "$started" "$ended"
  [[ $clean == true && $exported == true ]]
}

if [[ "${1-}" == --backend && "${2-}" == rootless ]]; then
  shift 2
  exec unshare --mount --propagation private -- python3 "$(dirname -- "$SCRIPT_PATH")/rootless_sandbox.py" "$@"
fi

if [[ "${1-}" == --__supervisor ]]; then shift; supervisor "$@"; exit $?; fi
if [[ "${1-}" == --help || "${1-}" == -h ]]; then usage; exit 0; fi
if [[ "${1-}" == --check ]]; then check_runtime; printf 'execution_sandbox: ready\n' >&2; exit 0; fi

workspace= scratch= toolchain= codex= trusted= deps= baseline= evidence= timeout_s= memory= disk= pids= cpus= read_only=false
while (($#)); do
  case "$1" in
    --workspace) workspace=$2; shift 2;; --scratch-root) scratch=$2; shift 2;; --toolchain) toolchain=$2; shift 2;;
    --codex) codex=$2; shift 2;; --trusted-root) trusted=$2; shift 2;; --dependencies) deps=$2; shift 2;;
    --baseline) baseline=$2; shift 2;; --evidence) evidence=$2; shift 2;; --timeout-seconds) timeout_s=$2; shift 2;;
    --memory-mb) memory=$2; shift 2;; --disk-mb) disk=$2; shift 2;; --pids) pids=$2; shift 2;; --cpus) cpus=$2; shift 2;;
    --read-only-workspace) read_only=$2; shift 2;;
    --) shift; break;; *) usage >&2; die "unknown option: $1";;
  esac
done
[[ -n "$workspace" && -n "$scratch" && -n "$toolchain" && -n "$codex" && -n "$trusted" && -n "$deps" && -n "$baseline" && -n "$evidence" && -n "$timeout_s" && -n "$memory" && -n "$disk" && -n "$pids" && -n "$cpus" ]] || die 'all paths and limits are required'
(($#)) || die 'command is required after --'
[[ $read_only == true || $read_only == false ]] || die 'read-only-workspace must be true or false'
for val in "$timeout_s" "$memory" "$disk" "$pids" "$cpus"; do [[ "$val" =~ ^[1-9][0-9]*$ ]] || die 'limits must be positive integers'; done
(( timeout_s <= 86400 && memory >= 128 && memory <= 65536 && disk >= 128 && disk <= 65536 && pids <= 65536 && cpus <= 64 )) || die 'resource limit outside supported range'
check_runtime
workspace=$(real_dir "$workspace"); toolchain=$(real_dir "$toolchain"); trusted=$(real_dir "$trusted"); deps=$(real_dir "$deps")
baseline=$(real_dir "$baseline"); evidence=$(real_dir "$evidence"); codex=$(real_file "$codex")
[[ -x "$codex" && -d "$trusted/scripts" && -d "$workspace/.git" ]] || die 'codex/scripts/.git path validation failed'
tool_bins="$toolchain/data/installs/elixir/1.19.5-otp-28/bin"
erlang_bins="$toolchain/data/installs/erlang/28.5/bin"
[[ -d "$tool_bins" && -d "$erlang_bins" ]] || die 'frozen Elixir/Erlang toolchain paths are missing'
nif_cache="$toolchain/cache/elixir_make"
if [[ -e "$nif_cache" || -L "$nif_cache" ]]; then
  [[ -d "$nif_cache" && ! -L "$nif_cache" ]] || die 'trusted elixir_make cache must be a real directory'
  cache_unsafe=$(find "$nif_cache" -mindepth 1 \( -type l -o \! -type f -a \! -type d \) -print -quit)
  [[ -z "$cache_unsafe" ]] || die 'trusted elixir_make cache contains an unsafe entry'
fi
mkdir -p "$scratch"; scratch=$(real_dir "$scratch")
[[ "$scratch" != / && "$scratch" != "$workspace" && "$scratch" != "$workspace/"* && "$workspace" != "$scratch/"* ]] || die 'scratch and workspace must be disjoint'
[[ -z "$(find "$scratch" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'scratch root must be empty'
available=$(df -Pk "$scratch" | awk 'NR==2 {print $4}'); need=$((disk * 1024 + 64 * 1024 + 128 * 1024))
(( available >= need )) || die 'insufficient host scratch space for bounded export and reserve'
for val in cpu memory pids; do
  case " $(cat /sys/fs/cgroup/cgroup.subtree_control) " in *" $val "*) ;; *) printf '+%s\n' "$val" > /sys/fs/cgroup/cgroup.subtree_control || die "cannot enable cgroup $val";; esac
done
mkdir -p "$CGROUP_PARENT"
for val in cpu memory pids; do
  case " $(cat "$CGROUP_PARENT/cgroup.subtree_control" 2>/dev/null || true) " in *" $val "*) ;; *) printf '+%s\n' "$val" > "$CGROUP_PARENT/cgroup.subtree_control" || die "cannot delegate cgroup $val";; esac
done
cg="$CGROUP_PARENT/run-$$-$RANDOM"; cg_owned=0; private=; supervisor_pid=
kill_group() {
  [[ "$cg_owned" == 1 && -e "$cg/cgroup.kill" ]] || return 0
  printf '1\n' > "$cg/cgroup.kill" 2>/dev/null || true
}
cleanup() {
  status=$?; trap - EXIT INT TERM HUP; kill_group
  [[ -z "$supervisor_pid" ]] || wait "$supervisor_pid" 2>/dev/null || true
  if [[ "$cg_owned" == 1 && -d "$cg" ]]; then kill_group; rmdir "$cg" 2>/dev/null || log 'cgroup still populated'; fi
  [[ -z "$private" || ! -d "$private" ]] || rm -rf -- "$private"
  exit "$status"
}
trap cleanup EXIT
trap 'kill_group; exit 143' INT TERM HUP
mkdir "$cg" || die 'cannot create run cgroup'
cg_owned=1
[[ -e "$cg/cgroup.kill" ]] || { rmdir "$cg"; die 'per-run cgroup.kill is unavailable'; }
printf '%s %s\n' "$((cpus * 100000))" 100000 > "$cg/cpu.max"
printf '%s\n' "$((memory * 1024 * 1024))" > "$cg/memory.max"
[[ ! -e "$cg/memory.swap.max" ]] || printf '0\n' > "$cg/memory.swap.max"
printf '%s\n' "$pids" > "$cg/pids.max"
private=$(mktemp -d "$scratch/.private.XXXXXXXX")
exec {input_fd}<&0
host_netns=$(readlink /proc/self/ns/net)
unshare --mount --net --propagation private --fork -- /bin/bash "$SCRIPT_PATH" --__supervisor \
  --workspace "$workspace" --scratch-root "$scratch" --private "$private" --cgroup "$cg" \
  --toolchain "$toolchain" --codex "$codex" --scripts "$trusted/scripts" --dependencies "$deps" \
  --baseline "$baseline" --evidence "$evidence" --disk-mb "$disk" --timeout-seconds "$timeout_s" --host-netns "$host_netns" --cpus "$cpus" --pids "$pids" --read-only-workspace "$read_only" -- "$@" \
  </proc/self/fd/"$input_fd" &
supervisor_pid=$!
wait "$supervisor_pid" || true
supervisor_pid=
python3 - "$scratch/result.json" <<'PY'
import json, sys
try:
    r=json.load(open(sys.argv[1],encoding='utf-8'))
    if r.get('cleanup_complete') is not True or r.get('export_complete') is not True: raise ValueError()
    raise SystemExit(max(0,min(255,int(r['exit_status']))))
except Exception: raise SystemExit(125)
PY

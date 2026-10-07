#!/usr/bin/env python3
"""Trusted host supervisor. Task commands run only after dropping to an OCI worker."""
import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import selectors
import select
import signal
import subprocess
import sys
import time

from sandbox_artifacts import export_source, save_json, source_manifest
from runtime_identity import native_client

CGROUP = Path("/sys/fs/cgroup/innovation-symphony-execution")
BLOCKED = ("0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
           "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "192.168.0.0/16",
           "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4")
TOOLS = ("podman", "crun", "newuidmap", "newgidmap", "ip", "nft", "mount",
         "umount", "mkfs.ext4", "setpriv", "timeout", "iptables", "nsenter")


def public_destination(address):
    """Used by fixtures; the host nft rules enforce the actual packet boundary."""
    ip = ipaddress.ip_address(address)
    return ip.version == 4 and ip.is_global and not any(ip in ipaddress.ip_network(net) for net in BLOCKED)


def network_rules(table, interface):
    if not re.fullmatch(r"sy[0-9a-f]{8}", table) or not re.fullmatch(r"sh[0-9a-f]{8}", interface):
        raise ValueError("invalid network identity")
    networks = ", ".join(BLOCKED)
    return f"""
table inet {table} {{
  set blocked {{ type ipv4_addr; flags interval; elements = {{ {networks} }}; }}
  chain input {{ type filter hook input priority -20; policy accept;
    iifname "{interface}" drop
  }}
  chain forward {{ type filter hook forward priority -20; policy accept;
    iifname "{interface}" meta nfproto ipv6 drop
    iifname "{interface}" ip daddr @blocked drop
    iifname "{interface}" accept
    oifname "{interface}" ct state established,related accept
    oifname "{interface}" drop
  }}
}}
table ip {table} {{
  chain postrouting {{ type nat hook postrouting priority srcnat; policy accept;
    ip saddr 100.127.255.2 masquerade
  }}
}}
"""


def image_identity(output):
    identity = output.strip()
    if re.fullmatch(r"[0-9a-f]{64}", identity):
        identity = "sha256:" + identity
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", identity):
        raise ValueError("prepared image identity missing")
    return identity


def forwarding_rules(interface):
    if not re.fullmatch(r"sh[0-9a-f]{8}", interface):
        raise ValueError("invalid network identity")
    return [["-i", interface, "-j", "ACCEPT"],
            ["-o", interface, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"]]


def view_check(argv):
    return (len(argv) == 6 and argv[:5] == [
        '/opt/toolchain/view-validation/python/bin/python', '-I', '-B',
        '/opt/symphony/scripts/check_view_isolated.py', '--candidate-sha']
        and bool(re.fullmatch(r'[0-9a-f]{40}', argv[5])))


def formal_check(argv):
    return argv[0] == 'python3' or view_check(argv)


def detach_view_network(argv, namespace, peer, command):
    """Keep the fixed View stage offline after its environment is prepared."""
    if not view_check(argv):
        return False
    command(["ip", "-n", namespace, "link", "delete", peer])
    return True


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    for name in ("workspace", "scratch-root", "toolchain", "codex", "trusted-root",
                 "dependencies", "baseline", "evidence", "image", "worker"):
        result.add_argument("--" + name, required=True)
    for name in ("timeout-seconds", "memory-mb", "disk-mb", "pids", "cpus"):
        result.add_argument("--" + name, type=int, required=True)
    result.add_argument("--read-only-workspace", choices=("true", "false"), default="false")
    result.add_argument("--environment-recipe", default="")
    result.add_argument("--preflight", choices=("true", "false"), default="false")
    result.add_argument("command", nargs=argparse.REMAINDER)
    return result


def validate(args):
    if os.geteuid() != 0:
        raise ValueError("trusted root supervisor is required; the container worker stays unprivileged")
    if not re.fullmatch(r"[A-Za-z0-9./:_-]+@sha256:[0-9a-f]{64}", args.image):
        raise ValueError("a digest-pinned OCI image is required")
    worker = pwd.getpwnam(args.worker)
    if worker.pw_uid == 0 or worker.pw_name == "root":
        raise ValueError("worker must not be root")
    for name in TOOLS:
        if not shutil.which(name):
            raise ValueError("missing runtime: " + name)
    if not (1 <= args.timeout_seconds <= 7200 and 128 <= args.memory_mb <= 65536
            and 128 <= args.disk_mb <= 65536 and 1 <= args.pids <= 65536 and 1 <= args.cpus <= 64):
        raise ValueError("invalid resource budget")
    if Path("/proc/sys/net/ipv4/ip_forward").read_text().strip() != "1":
        raise ValueError("trusted IPv4 forwarding must be prepared before activation")
    paths = [Path(getattr(args, key)) for key in
             ("workspace", "scratch_root", "toolchain", "codex", "trusted_root", "dependencies", "baseline", "evidence")]
    if any(not path.is_absolute() or path.resolve() != path or path.is_symlink()
           or any(char in str(path) for char in ":,\n\r") for path in paths):
        raise ValueError("paths must be absolute, canonical and non-linked")
    scratch = Path(args.scratch_root)
    workspace = Path(args.workspace)
    if scratch == workspace or scratch.is_relative_to(workspace) or workspace.is_relative_to(scratch):
        raise ValueError("workspace and scratch must be disjoint")
    if scratch.exists() and any(scratch.iterdir()):
        raise ValueError("scratch must be empty")
    if not Path(args.codex).is_file() or not (workspace / ".git").is_dir():
        raise ValueError("native client or Git metadata missing")
    recipe = Path(args.environment_recipe)
    if args.environment_recipe and (recipe.is_absolute() or ".." in recipe.parts
                                    or (workspace / recipe).resolve() != workspace / recipe
                                    or (workspace / recipe).is_symlink()
                                    or ((workspace / recipe).exists() and not (workspace / recipe).is_file())):
        raise ValueError("environment recipe must be a regular task-relative file")
    gate = Path(args.trusted_root) / "gate-python/bindings.json"
    if not gate.is_file() or gate.is_symlink():
        raise ValueError("protected formal Python inventory missing")
    if not args.command or args.command[0] != "--" or len(args.command) < 2:
        raise ValueError("command must follow --")
    native_client(args.codex)
    if not all(any(line.split(":")[0] == worker.pw_name and int(line.split(":")[2]) >= 65536
                   for line in Path(path).read_text().splitlines() if len(line.split(":")) == 3)
               for path in ("/etc/subuid", "/etc/subgid")):
        raise ValueError("worker subordinate UID/GID allocation missing")
    return worker


def capture(argv, deadline, *, input=None, check=True, preexec_fn=None, limit=64 * 1048576):
    process = subprocess.Popen(argv, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=preexec_fn)
    output = {process.stdout: bytearray(), process.stderr: bytearray()}
    try:
        if input is not None:
            process.stdin.write(input.encode())
            process.stdin.close()
        with selectors.DefaultSelector() as selector:
            for stream in output:
                selector.register(stream, selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(argv, 0, output=bytes(output[process.stdout]).decode(errors="replace"), stderr=bytes(output[process.stderr]).decode(errors="replace"))
                for key, _ in selector.select(0.1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        output[key.fileobj].extend(chunk)
                        if sum(map(len, output.values())) > limit:
                            raise ValueError("trusted setup output limit exceeded")
        status = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        stdout, stderr = [output[stream].decode("utf-8", errors="replace") for stream in output]
        if check and status:
            raise subprocess.CalledProcessError(status, argv, stdout, stderr)
        return subprocess.CompletedProcess(argv, status, stdout, stderr)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        for stream in output:
            stream.close()


def fixed_command(argv):
    if argv[0] != "python3":
        return argv
    # -I/-S discard guest HOME, PYTHONPATH and site customization. Sibling scripts
    # are loaded only from the protected controller installation.
    return ["/opt/gate-python", "-I", "-S", "-c",
            "import sys,runpy;sys.path.insert(0,'/opt/symphony/scripts');p=sys.argv.pop(1);runpy.run_path(p,run_name='__main__')",
            *argv[1:]]


def relay(process, deadline, limit=64 * 1048576):
    """Bound task stdout/stderr without buffering them in controller memory."""
    total = 0
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ, sys.stdout.buffer)
        selector.register(process.stderr, selectors.EVENT_READ, sys.stderr.buffer)
        while selector.get_map():
            if time.monotonic() >= deadline:
                return 124
            for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                total += len(chunk)
                if total > limit:
                    return 125
                key.data.write(chunk)
                key.data.flush()
    return process.wait(timeout=max(0.01, deadline - time.monotonic()))


def main(arguments=None):
    args = parser().parse_args(arguments)
    worker = validate(args)
    if args.preflight == "true":
        print(json.dumps(dict(status="ready", backend="rootless", ipv6_policy="deny")))
        return 0
    scratch = Path(args.scratch_root)
    scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(scratch, 0o711)
    token = hashlib.sha256(str(scratch).encode()).hexdigest()[:8]
    namespace, interface, peer, table = "sn" + token, "sh" + token, "sp" + token, "sy" + token
    name = "symphony-" + token
    group = CGROUP / name
    disk, volume = scratch / "work.img", scratch / "volume"
    started, deadline = time.time(), time.monotonic() + args.timeout_seconds
    status, cleanup, report = 125, False, None
    mounted = False
    original = {}
    network_created = False
    network_detached = False
    forwarding = []
    lock = os.open("/run/lock/innovation-symphony-rootless.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def command(argv, *, check=True, input=None, join_group=False):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("task deadline exhausted")
        def enter():
            if join_group:
                (group / "cgroup.procs").write_text(str(os.getpid()))
        return capture(argv, deadline, input=input, check=check, preexec_fn=enter if join_group else None)

    def as_worker(argv):
        return ["nsenter", "--net=/run/netns/" + namespace, "setpriv", "--reuid", str(worker.pw_uid),
                "--regid", str(worker.pw_gid), "--init-groups", "env", "-i",
                "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME=" + str(volume / "home"), "XDG_RUNTIME_DIR=" + str(volume / "run"),
                "XDG_CONFIG_HOME=" + str(volume / "config"),
                "XDG_DATA_HOME=" + str(volume / "data"), "TMPDIR=" + str(volume / "tmp"),
                "podman", "--root", str(volume / "graph"), "--runroot", str(volume / "run"),
                "--storage-driver=overlay", "--cgroup-manager=cgroupfs", *argv]

    def interrupted(_signal, _frame):
        raise InterruptedError("trusted bridge interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        # The disk is persistent, capacity bounded, and never exposed as a task device.
        with disk.open("xb") as handle:
            handle.truncate(args.disk_mb * 1048576)
        command(["mkfs.ext4", "-q", "-F", str(disk)])
        volume.mkdir(mode=0o700)
        command(["mount", "-o", "loop,nodev,nosuid", str(disk), str(volume)])
        mounted = True
        for directory in ("home", "run", "config", "data", "tmp", "graph", "workspace"):
            path = volume / directory
            path.mkdir(mode=0o700)
            os.chown(path, worker.pw_uid, worker.pw_gid)
        os.chmod(volume, 0o711)
        shutil.copytree(args.workspace, volume / "workspace", dirs_exist_ok=True,
                        ignore=lambda directory, names: [name for name in names if any(
                            str((Path(directory) / name).relative_to(args.workspace)) == excluded
                            for excluded in (".git", ".codex", ".symphony-import", ".check-evidence", "elixir/_build", "elixir/deps", "elixir/cover", "elixir/bin"))],
                        symlinks=True)
        (volume / "workspace/.git").mkdir(mode=0o755)
        shutil.copytree(args.dependencies, volume / "workspace/elixir/deps", symlinks=True)
        for root, dirs, files in os.walk(volume / "workspace", followlinks=False):
            for path in [Path(root), *(Path(root) / item for item in dirs + files)]:
                os.chown(path, worker.pw_uid, worker.pw_gid, follow_symlinks=False)

        for directory, dirs, files in os.walk(Path(args.workspace) / ".git"):
            os.chmod(directory, 0o755)
            for filename in files:
                path = Path(directory) / filename
                if not path.is_symlink():
                    os.chmod(path, 0o644)
        original = source_manifest(volume / "workspace")
        save_json(scratch / "original-manifest.json", original)
        CGROUP.mkdir(exist_ok=True)
        for parent in (Path("/sys/fs/cgroup"), CGROUP):
            (parent / "cgroup.subtree_control").write_text("+cpu +memory +pids")
        group.mkdir()
        for key, value in {"cpu.max": f"{args.cpus * 100000} 100000",
                           "memory.max": str(args.memory_mb * 1048576), "memory.swap.max": "0",
                           "pids.max": str(args.pids)}.items():
            (group / key).write_text(value)

        command(["ip", "netns", "add", namespace])
        network_created = True
        command(["ip", "link", "add", interface, "type", "veth", "peer", "name", peer])
        command(["ip", "link", "set", peer, "netns", namespace])
        command(["ip", "addr", "add", "100.127.255.1/30", "dev", interface])
        command(["ip", "link", "set", interface, "up"])
        for argv in (["link", "set", "lo", "up"], ["addr", "add", "100.127.255.2/30", "dev", peer],
                     ["link", "set", peer, "up"], ["route", "add", "default", "via", "100.127.255.1"]):
            command(["ip", "-n", namespace, *argv])
        command(["nft", "-f", "-"], input=network_rules(table, interface))
        # Docker may set FORWARD=DROP. Our earlier nft hook still rejects private
        # destinations; these exact-interface rules admit only the task's traffic.
        for rule in forwarding_rules(interface):
            command(["iptables", "-w", "5", "-I", "FORWARD", "1", *rule])
            forwarding.append(rule)


        # This runner is already in a private mount namespace. Give Podman
        # public DNS too; the host loopback resolver is unreachable in the netns.
        resolver = volume / "resolv.conf"
        resolver.write_text("nameserver 127.0.0.1\noptions timeout:2 attempts:2\n")
        resolver.chmod(0o644)
        command(["mount", "--bind", str(resolver), "/etc/resolv.conf"])
        def dns_group():
            (group / "cgroup.procs").write_text(str(os.getpid()))
        dns = subprocess.Popen(["nsenter", "--net=/run/netns/" + namespace, "/usr/bin/python3", "-I",
                                str(Path(__file__).with_name("rootless_dns.py")),
                                "--uid", str(worker.pw_uid), "--gid", str(worker.pw_gid),
                                "--host-network", os.readlink("/proc/self/ns/net")],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, preexec_fn=dns_group)
        if not select.select([dns.stdout], [], [], min(5, max(0, deadline - time.monotonic())))[0] or dns.stdout.readline() != b"ready\n":
            raise ValueError("task DNS resolver failed to start")
        dns.stdout.close()

        command(as_worker(["pull", args.image]), join_group=True)
        # No host namespace, runtime socket, credential environment or host HOME is inherited.
        options = ["run", "--name", name, "--interactive", "--pull=never", "--runtime=crun",
                   "--network=host", "--cgroups=disabled", "--user=0", "--cap-add=SYS_PTRACE",
                   "--security-opt=no-new-privileges",
                   "--hostname=symphony-task", "--workdir=/workspace", "--tmpfs=/tmp:rw,size=256m"]
        mounts = [(str(resolver), "/etc/resolv.conf", "ro"), (str(volume / "workspace"), "/workspace", "ro" if args.read_only_workspace == "true" else "rw"),
                  (args.workspace + "/.git", "/workspace/.git", "ro"),
                  (args.toolchain, "/opt/toolchain", "ro"), (args.toolchain, args.toolchain, "ro"),
                  (args.codex, "/opt/codex", "ro"), (args.trusted_root + "/scripts", "/opt/symphony/scripts", "ro"),
                  (args.dependencies, "/opt/deps", "ro"), (args.baseline, "/baseline", "ro"),
                  (args.evidence, "/evidence", "ro")]
        protected_volumes = set()
        gate = Path(args.trusted_root) / "gate-python"
        if formal_check(args.command[1:]) or args.read_only_workspace == "true":
            bindings = json.loads((gate / "bindings.json").read_text())
            if not bindings or any(Path(item["source"]).resolve() != gate / item["relative"] for item in bindings):
                raise ValueError("trusted Python binding inventory invalid")
            mounts += [(item["source"], item["target"], "ro") for item in bindings]
            protected_volumes = {item["source"] + ":" + item["target"] + ":ro" for item in bindings}
        for source, target, access in mounts:
            options.extend(["--volume", source + ":" + target + ":" + access])
        bins = "/opt/toolchain/data/installs/elixir/1.19.5-otp-28/bin:/opt/toolchain/data/installs/erlang/28.5/bin"
        for key, value in {"HOME": "/root", "CODEX_HOME": "/root/.codex",
                           "PATH": bins + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "MIX_HOME": "/opt/toolchain/mix" if formal_check(args.command[1:]) else "/root/.mix", "HEX_HOME": "/opt/toolchain/hex",
                           "MIX_ARCHIVES": "/opt/toolchain/data/installs/elixir/1.19.5-otp-28/.mix/archives",
                           "MIX_REBAR3": "/opt/toolchain/mix/elixir/1-19-otp-28/rebar3",
                           "LANG": "C.UTF-8", "TMPDIR": "/tmp", "CI": "1",
                           "SYMPHONY_TEST_CODEX": "/opt/codex", "SYMPHONY_CHECK_CPUS": str(args.cpus),
                           "SYMPHONY_CHECK_PIDS": str(args.pids),
                           "ERL_FLAGS": f"+S {min(args.cpus, max(1, args.pids // 32))}:"
                                        f"{min(args.cpus, max(1, args.pids // 32))} +SDcpu 1:1 +SDio 1",
                           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                           "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": "/workspace"}.items():
            options.extend(["--env", key + "=" + value])
        recipe_path = Path(args.workspace) / args.environment_recipe if args.environment_recipe else None
        recipe = "/workspace/" + args.environment_recipe if recipe_path and recipe_path.is_file() else ""
        if recipe_path and not recipe and (formal_check(args.command[1:]) or args.read_only_workspace == "true"):
            raise ValueError("declared formal environment recipe is missing")
        recipe_sha = hashlib.sha256(recipe_path.read_bytes()).hexdigest() if recipe else None
        prepared_image = args.image
        if recipe:
            prep_name = name + "-prepare"
            prep_options = []
            index = 0
            while index < len(options):
                if options[index] == "--volume" and options[index + 1] in protected_volumes:
                    index += 2
                else:
                    prep_options.append(options[index])
                    index += 1
            prep_options[prep_options.index("--name") + 1] = prep_name
            # Environment preparation has a writable private copy; authority metadata remains readonly.
            for index, value in enumerate(prep_options):
                if value == str(volume / "workspace") + ":/workspace:ro":
                    prep_options[index] = str(volume / "workspace") + ":/workspace:rw"
            prepared = command(as_worker(prep_options + [args.image, "bash", recipe]), join_group=True)
            (scratch / "prepare.log").write_text(prepared.stdout + prepared.stderr)
            if source_manifest(volume / "workspace") != original:
                raise ValueError("environment recipe changed candidate source")
            prepared_image = image_identity(command(as_worker(["commit", prep_name]), join_group=True).stdout)
            command(as_worker(["rm", prep_name]), join_group=True)
        environment = dict(image=args.image, prepared_image=prepared_image, recipe_sha256=recipe_sha, profile="rootless-open-v1",
                           runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                           native_sha256=hashlib.sha256(Path(args.codex).read_bytes()).hexdigest())
        environment["sha256"] = hashlib.sha256(json.dumps(environment, sort_keys=True).encode()).hexdigest()
        save_json(scratch / "environment.json", environment)
        network_detached = detach_view_network(args.command[1:], namespace, peer, command)
        argv = as_worker(options + [prepared_image, *fixed_command(args.command[1:])])
        # Bind inherited network identity before starting the rootless runtime.
        actual = command(["ip", "netns", "exec", namespace, "readlink", "/proc/self/ns/net"]).stdout.strip()
        if actual == os.readlink("/proc/self/ns/net"):
            raise ValueError("refusing host network namespace")
        def enter_group():
            (group / "cgroup.procs").write_text(str(os.getpid()))
        process = subprocess.Popen(argv, preexec_fn=enter_group, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        status = relay(process, deadline)
        status = status if status >= 0 else 128 - status
    except (OSError, ValueError, subprocess.SubprocessError, TimeoutError) as error:
        if isinstance(error, (subprocess.CalledProcessError, subprocess.TimeoutExpired)):
            (scratch / "setup-error.log").write_text((error.stdout or "") + (error.stderr or ""))
        save_json(scratch / "failure.json", dict(schema=1, stage="sandbox", category="environment",
                                               reason=type(error).__name__, detail=str(error)))
    finally:
        # Cleanup runs outside the spent task budget, but each operation is bounded.
        if network_created:
            try:
                subprocess.run(as_worker(["rm", "--force", name, name + "-prepare"]), timeout=15,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
                               preexec_fn=lambda: (group / "cgroup.procs").write_text(str(os.getpid())) if group.exists() else None)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if group.exists():
            try:
                (group / "cgroup.kill").write_text("1")
                for _ in range(100):
                    if "populated 0" in (group / "cgroup.events").read_text():
                        cleanup = True
                        break
                    time.sleep(0.05)
            except OSError:
                pass
        else:
            cleanup = True
        if cleanup and mounted:
            report = export_source(volume / "workspace", scratch / "export", args.disk_mb * 1048576,
                                   identity=dict(run_id=name, backend="rootless", image=args.image), original=original)
        result = dict(schema=2, scratch_root=str(scratch), exit_status=status, cleanup_complete=cleanup,
                      descendants_cleaned=cleanup, export_complete=bool(report and report["export_complete"]),
                      source_saved=mounted, source_volume=str(disk), backend="rootless", profile="rootless-open-v1",
                      ipv6_policy="deny", started_at_epoch=int(started), ended_at_epoch=int(time.time()))
        for filename in ("memory.events", "pids.events"):
            try:
                result.setdefault("resource_events", {})[filename.split(".")[0]] = dict(
                    (key, int(value)) for key, value in (line.split() for line in (group / filename).read_text().splitlines()))
            except OSError:
                pass
        host_cleanup = True
        operations = []
        operations += [["iptables", "-w", "5", "-D", "FORWARD", *rule] for rule in reversed(forwarding)]
        if network_created:
            operations += [["nft", "delete", "table", "inet", table], ["nft", "delete", "table", "ip", table]]
            if not network_detached:
                operations += [["ip", "link", "delete", interface]]
            operations += [["ip", "netns", "delete", namespace]]
        if mounted:
            operations += [["umount", str(volume)]]
        for argv in operations:
            try:
                outcome = subprocess.run(argv, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                host_cleanup = host_cleanup and outcome.returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                host_cleanup = False
        if group.exists() and cleanup:
            try:
                group.rmdir()
            except OSError:
                host_cleanup = False
        result["host_cleanup_complete"] = host_cleanup
        result["cleanup_complete"] = cleanup and host_cleanup
        save_json(scratch / "result.json", result)
        os.close(lock)
    return status if cleanup and host_cleanup and report and report["export_complete"] else 125


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError) as error:
        print("rootless sandbox refused: " + str(error), file=sys.stderr)
        raise SystemExit(125)

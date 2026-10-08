#!/usr/bin/env python3
"""Repository CI checks on private synthetic copies; not controller acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "view_validation"))
from validator import validate_python_report, validate_render, validate_tap

FIXTURE = ROOT / "scripts" / "view_validation" / "fixtures" / "acceptance.json"
EXPECTED = ROOT / "view" / "tests" / "fixtures" / "migration-expected.json"


def projection(stage, output):
    """Normalize only private staging paths and the viewer's minute stamp."""
    def normalize(text):
        return text.replace(str(stage), "/fixture-view")
    snapshot = json.loads(normalize((output / "fixture-snapshot.json").read_text()))
    contexts = json.loads(normalize((output / "fixture-contexts.json").read_text()))
    pages = {}
    for path in sorted((output / "rendered").glob("*.html")):
        html = re.sub(r"Generated \d{4}-\d{2}-\d{2} \d{2}:\d{2}", "Generated", normalize(path.read_text()))
        pages[path.name] = hashlib.sha256(html.encode()).hexdigest()
    return {"snapshot": snapshot, "contexts": contexts, "html_sha256": pages}


def render(stage, output):
    # The worker owns candidate imports, captured runner integrity and isolation.
    # Its CLI is shared with the controller's synthetic validation path.
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, "-I", "-B", str(ROOT / "scripts/view_validation/worker.py"),
                    "--stage", str(stage), "--fixture", str(FIXTURE),
                    "--evidence", str(output), "--render"], check=True, timeout=120)
    report = json.loads((output / "worker-result.json").read_text(encoding="utf-8"))
    validate_render(report)
    result = projection(stage, output)
    (output / "projection.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


def copy_view(source, destination):
    # Runtime directories and local configs never enter the fixture stage.
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(
        ".git", "__pycache__", "*.pyc", "config.toml", "config.json", "build", "data",
        "prototypes", "logs", ".venv", "node_modules", ".zcode"))


def entrypoint(stage, mode):
    """Execute app/run.py as __main__; only the external collector is simulated."""
    sys.path.insert(0, str(stage / "app"))
    from symphony_board import api, runtime_source
    cwd = stage.parent if mode.startswith("root") else stage
    os.chdir(cwd)
    script = os.path.relpath(stage / "app/run.py", cwd)
    args = [script, "13", "--port", "8622"]
    if mode.endswith("toml") or mode.endswith("json"):
        suffix = mode.rsplit("-", 1)[1]
        args.extend(["--config", os.path.relpath(stage / f"app/config.example.{suffix}", cwd)])
    serving = mode.endswith("serve")
    if not serving:
        args.extend(["once", "--out", "snapshot.json"])
    seen = []
    def serve(state, cfg, raw, store, **kwargs):
        seen.append((cfg.interval, cfg.port))
        return type("FixtureHTTP", (), {"serve_forever": lambda self: None})()
    with patch.object(sys, "argv", args), patch.object(runtime_source, "pull_snapshot", return_value={"runtimes": []}), \
            patch.object(api, "serve", side_effect=serve), patch("time.sleep", side_effect=StopIteration("end fixture cycle")):
        try:
            runpy.run_path(script, run_name="__main__")
        except StopIteration:
            if not serving:
                raise
    if not (stage / "data/board.db").is_file():
        raise AssertionError("script entrypoint did not create its own database")
    if serving:
        if seen != [(13, 8622)] or not (stage / "prototypes").is_dir():
            raise AssertionError("service entrypoint did not apply overrides/publish pages")
    else:
        payload = json.loads((cwd / "snapshot.json").read_text())
        if payload["interval"] != 13 or payload["tasks"] != [] or seen:
            raise AssertionError("once entrypoint output or service isolation differs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node", default="node")
    parser.add_argument("--output", type=Path, required=True)
    # Internal child mode isolates imports from the unittest process and old source.
    parser.add_argument("--fixture-stage", type=Path)
    parser.add_argument("--entrypoint-stage", type=Path)
    parser.add_argument("--entrypoint-mode")
    args = parser.parse_args()
    output = args.output.resolve()
    if args.entrypoint_stage:
        entrypoint(args.entrypoint_stage.resolve(), args.entrypoint_mode)
        return 0
    output.mkdir(parents=True, exist_ok=False)
    if args.fixture_stage:
        render(args.fixture_stage.resolve(), output)
        return 0
    report = {"passed": False, "formal_acceptance": False, "real_windows_wsl": False,
              "browser": "not yet executed", "commands": []}
    try:
        with tempfile.TemporaryDirectory(prefix="view-ci-") as directory:
            stage = Path(directory) / "view"
            copy_view(ROOT / "view", stage)
            actual = render(stage, output / "fixture")
            worker_report = json.loads((output / "fixture/worker-result.json").read_text(encoding="utf-8"))
            python = worker_report["python"]
            frozen = json.loads((ROOT / "scripts/view_validation/frozen/baseline.json").read_text())
            validate_python_report({"passed": python["passed"], "python": python},
                                   frozen["python_baseline_count"], frozen["python_identities"])
            report["python"] = python
            js = [args.node, "--test", "--test-reporter=tap", str(stage / "tests/rounds.test.mjs"),
                  str(stage / "tests/model-settings.test.mjs")]
            result = subprocess.run(js, capture_output=True, text=True, timeout=120)
            (output / "javascript.stdout").write_text(result.stdout)
            (output / "javascript.stderr").write_text(result.stderr)
            print(result.stdout)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            result.check_returncode()
            report["commands"].append(js)
            report["javascript"] = validate_tap(result.stdout, frozen["javascript_baseline_count"] + 1)
            expected = json.loads(EXPECTED.read_text())
            if actual != expected:
                raise AssertionError("fixed pre-migration snapshot/context/HTML results differ; inspect fixture/projection.json")
            report["migration_equivalent"] = True
            report["self_check_rendered"] = True
            report["entrypoints"] = []
            for mode in ("root-default", "view-default", "root-toml", "view-toml", "root-json", "view-json", "root-serve", "view-serve"):
                private_view = Path(directory) / mode / "view"
                copy_view(ROOT / "view", private_view)
                cmd = [sys.executable, "-B", str(Path(__file__).resolve()), "--entrypoint-stage", str(private_view),
                       "--entrypoint-mode", mode, "--output", str(output)]
                report["commands"].append(cmd)
                subprocess.run(cmd, check=True, timeout=120)
                report["entrypoints"].append(mode)
            # Real Linux collection is deliberately a separate interpreter and
            # stage; the frozen worker still forbids every real subprocess.
            if sys.platform.startswith("linux"):
                private_view = Path(directory) / "local-integration" / "view"
                copy_view(ROOT / "view", private_view)
                cmd = [sys.executable, "-I", "-B", str(ROOT / "scripts/view_validation/local_integration.py"),
                       "--stage", str(private_view), "--output", str(output / "local-integration")]
                report["commands"].append(cmd)
                subprocess.run(cmd, check=True, timeout=120)
                integration_report = json.loads((output / "local-integration/local-integration-result.json").read_text())
                if not integration_report.get("passed") or not integration_report.get("loopback_service_stopped"):
                    raise AssertionError("isolated Linux integration failed or left its service running")
                report["linux_integration"] = integration_report
            else:
                report["linux_integration"] = "not executed: requires Linux"
            browser = [args.node, str(stage / "tests/browser-fixture.cjs"), str(output / "fixture")]
            report["commands"].append(browser)
            report["browser"] = {"passed": False, "status": "attempted"}
            subprocess.run(browser, check=True, timeout=180)
            browser_report = json.loads((output / "fixture/browser-fixture-result.json").read_text())
            if not browser_report.get("passed"):
                raise AssertionError("synthetic browser acceptance failed")
            report["browser"] = browser_report
            report["python_version"] = sys.version
            report["node_version"] = subprocess.check_output([args.node, "--version"], text=True, timeout=15).strip()
            report["passed"] = True
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
    (output / "code-check-result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

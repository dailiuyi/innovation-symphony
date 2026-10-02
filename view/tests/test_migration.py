"""GH-7: synthetic first run, invocation isolation and existing entrypoint paths."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen

VIEW = Path(__file__).resolve().parents[1]
APP_DIR = str(VIEW / "app")
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)
import run as entry
from symphony_board import api, collector, config, context, wslpull
from symphony_board.state import BoardState
from symphony_board.store import BoardStore


class MigrationTests(unittest.TestCase):
    def import_migration_tests(self):
        spec = importlib.util.spec_from_file_location("migration_import_probe", __file__)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(Path(module.entry.__file__).resolve(), VIEW / "app" / "run.py")
        self.assertIs(module.collector, collector)
        return module

    def test_import_preserves_preconfigured_module_search_path(self):
        # Keep app away from the front to catch both duplication and reordering.
        before = [path for path in sys.path if path != APP_DIR]
        before.insert(1, APP_DIR)
        with patch.object(sys, "path", before.copy()):
            self.import_migration_tests()
            self.assertEqual(sys.path, before)

    def test_import_adds_missing_app_path_for_normal_test_entry(self):
        before = [path for path in sys.path if path != APP_DIR]
        with patch.object(sys, "path", before.copy()):
            self.import_migration_tests()
            self.assertEqual(sys.path, [APP_DIR, *before])
            # Check path resolution even when the modules are already cached.
            from importlib.machinery import PathFinder
            for name, path in (("run", VIEW / "app" / "run.py"),
                               ("symphony_board", VIEW / "app" / "symphony_board" / "__init__.py")):
                self.assertEqual(Path(PathFinder.find_spec(name, sys.path).origin).resolve(), path)

    def test_first_cycle_caches_and_renders_without_existing_directories(self):
        sid = "00000007-0000-4000-8000-000000000040"
        rows = [
            {"type": "session_meta", "payload": {"id": sid, "cwd": "/fixture/GH-7"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user",
                "content": [{"type": "input_text", "text": "Implement only this repository's issue: GH-7 fixture"}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "FIRST_RUN_FIXTURE_OUTPUT"}]}},
        ]
        data = "\n".join(json.dumps(row) for row in rows) + "\n"
        snapshot = {"runtimes": [{"root": "/fixture", "receipts": [], "logs": [],
            "sessions": [{"path": "/fixture/rollout-first.jsonl", "bytes": len(data)}]}]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "build" / "rollouts"
            self.assertFalse(cache.exists())
            with patch.object(collector, "BUILD_ROLLOUTS", str(cache)), \
                    patch.object(context, "BUILD_ROLLOUTS", str(cache)), \
                    patch.object(entry, "ROOT", str(root)), \
                    patch.object(entry, "pull_snapshot", return_value=snapshot), \
                    patch.object(entry, "enrich_pulls"), patch.object(wslpull, "wsl", return_value=data) as read:
                store = BoardStore(str(root / "board.db"))
                try:
                    state = BoardState()
                    result = entry.run_cycle(config.BoardConfig(), store, state, api.RawRef())
                    self.assertEqual(len(result[-1]), 1)
                    self.assertEqual(result[2][0]["id"], sid)
                    self.assertEqual(result[2][0]["lastOutput"], "FIRST_RUN_FIXTURE_OUTPUT")
                    self.assertEqual(Path(result[-1][0]["local"]).read_text(), data)
                    self.assertTrue(entry.write_context_pages(config.BoardConfig(), result[-1]))
                    page = (root / "prototypes" / f"context-{sid}.html").read_text()
                    self.assertIn("FIRST_RUN_FIXTURE_OUTPUT", page)
                    self.assertIn('id="messages"', page)
                    # Repeat uses this session's cache and preserves unchanged HTML.
                    again = entry.run_cycle(config.BoardConfig(), store, state, api.RawRef())
                    self.assertFalse(entry.write_context_pages(config.BoardConfig(), again[-1]))
                    read.assert_called_once()
                finally:
                    store.close()
        collector.load_sessions({})

    def test_overlapping_snapshot_calls_use_their_own_scripts_and_clean_up(self):
        barrier = threading.Barrier(2)
        paths = []
        def fake_run(argv, **kwargs):
            script = Path(argv[-1])
            paths.append(script)
            barrier.wait(timeout=10)
            # Inspect the exact globs in the script supplied to this invocation.
            import ast
            tree = ast.parse(script.read_text())
            assignment = next(node for node in tree.body if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id == "roots" for target in node.targets))
            globs = ast.literal_eval(assignment.value.args[0].generators[0].iter)
            return SimpleNamespace(returncode=0, stderr=b"", stdout=json.dumps({
                "runtimes": [{"root": globs[0]}]}).encode())
        with patch.object(wslpull, "to_wsl_path", side_effect=lambda path: path), \
                patch.object(wslpull.subprocess, "run", side_effect=fake_run):
            with ThreadPoolExecutor(max_workers=2) as pool:
                a = pool.submit(wslpull.pull_snapshot, ["/fixture/a*'quoted"])
                b = pool.submit(wslpull.pull_snapshot, ["/fixture/b*中文"])
                self.assertEqual(a.result()["runtimes"][0]["root"], "/fixture/a*'quoted")
                self.assertEqual(b.result()["runtimes"][0]["root"], "/fixture/b*中文")
        self.assertEqual(len(set(paths)), 2)
        self.assertTrue(all(not path.exists() for path in paths))

    def test_snapshot_failure_and_malformed_output_clean_up_and_allow_retry(self):
        paths = []
        responses = [OSError("spawn failed"), KeyboardInterrupt(),
            SimpleNamespace(returncode=1, stdout=b"{}", stderr=b"fixture failure"),
            SimpleNamespace(returncode=0, stdout=b"no JSON", stderr=b""),
            SimpleNamespace(returncode=0, stdout=b"{broken", stderr=b""),
            SimpleNamespace(returncode=0, stdout=b'{"runtimes":[]}', stderr=b"")]
        def fake_run(argv, **kwargs):
            paths.append(Path(argv[-1]))
            self.assertTrue(paths[-1].is_file())
            response = responses.pop(0)
            if isinstance(response, BaseException):
                raise response
            return response
        with patch.object(wslpull, "to_wsl_path", side_effect=lambda path: path), \
                patch.object(wslpull.subprocess, "run", side_effect=fake_run):
            for error in (OSError, KeyboardInterrupt, RuntimeError, RuntimeError, json.JSONDecodeError):
                with self.assertRaises(error):
                    wslpull.pull_snapshot(["/fixture/error"])
                self.assertFalse(paths[-1].exists())
            self.assertEqual(wslpull.pull_snapshot(["/fixture/retry"]), {"runtimes": []})
        self.assertTrue(all(not path.exists() for path in paths))

    def test_script_generation_failure_removes_allocated_file(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(wslpull.tempfile, "tempdir", directory), \
                patch.object(wslpull, "remote_script", side_effect=RuntimeError("fixture generation failure")):
            with self.assertRaisesRegex(RuntimeError, "fixture generation failure"):
                wslpull.pull_snapshot(["/fixture/error"])
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_configuration_precedence_and_relative_path_semantics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            toml, js = root / "config.toml", root / "config.json"
            with patch.object(config, "CONFIG_TOML", str(toml)), patch.object(config, "CONFIG_JSON", str(js)):
                defaults = config.load_config()
                self.assertFalse(defaults.exists)
                self.assertEqual((defaults.interval, defaults.port), (5, 8613))
                js.write_text(json.dumps({"board": {"title": "JSON", "interval": 9, "port": 8619}}))
                self.assertEqual(config.load_config().title, "JSON")
                toml.write_text('[board]\ntitle="TOML"\ninterval=7\nport=8617\n')
                self.assertEqual(config.load_config().title, "TOML")
                self.assertEqual(config.load_config(str(js)).title, "JSON")
                self.assertFalse(config.load_config(str(root / "missing.toml")).exists)
                old = Path.cwd()
                try:
                    os.chdir(root)
                    self.assertEqual(config.load_config("config.toml").interval, 7)
                    self.assertEqual(config.load_config("config.json").port, 8619)
                finally:
                    os.chdir(old)
                for path, data in ((toml, "[board broken"), (js, "{broken"), (js, "[]")):
                    path.write_text(data)
                    with self.assertRaises((ValueError, AttributeError)):
                        config.load_config(str(path))

    def test_once_entrypoint_from_root_and_view_preserves_out_and_overrides(self):
        aliases_before = entry.common.REPO_ALIASES.copy()
        self.assertEqual(Path(config.CONFIG_TOML), VIEW / "app" / "config.toml")
        self.assertEqual(Path(api.WEB_DIR), VIEW / "app" / "web")
        self.assertEqual(Path(collector.BUILD_ROLLOUTS), VIEW / "build" / "rollouts")
        self.assertEqual(Path(entry.DATA_DIR), VIEW / "data")
        with tempfile.TemporaryDirectory() as directory:
            old = Path.cwd()
            try:
                for cwd in (VIEW.parent, VIEW):
                    with self.subTest(cwd=cwd):
                        os.chdir(cwd)
                        relative_out = os.path.relpath(Path(directory) / "snapshot.json", cwd)
                        supplied = []
                        real_cycle = entry.run_cycle
                        def cycle(cfg, *args):
                            supplied.append((cfg.interval, cfg.port, cfg.path))
                            return real_cycle(cfg, *args)
                        with patch.object(entry, "DATA_DIR", directory), \
                                patch.dict(entry.common.REPO_ALIASES), \
                                patch.object(entry, "self_check"), \
                                patch.object(entry, "pull_snapshot", return_value={"runtimes": []}), \
                                patch.object(entry, "enrich_pulls"), \
                                patch.object(entry, "run_cycle", side_effect=cycle), \
                                patch.object(sys, "argv", [str(VIEW / "app" / "run.py"), "once", "11",
                                    "--port", "8620", "--config", str(VIEW / "app" / "config.example.toml"), "--out", relative_out]), \
                                contextlib.redirect_stdout(io.StringIO()):
                            entry.main()
                        self.assertEqual(entry.common.REPO_ALIASES, aliases_before)
                        payload = json.loads((Path(directory) / "snapshot.json").read_text())
                        self.assertEqual(payload["tasks"], [])
                        self.assertEqual(payload["interval"], 11)
                        self.assertEqual(supplied, [(11, 8620, str(VIEW / "app" / "config.example.toml"))])
            finally:
                os.chdir(old)

    def test_malformed_cli_does_not_start_collection(self):
        for args in (["--port"], ["--port", "broken"], ["--config"], ["once", "--out"]):
            with self.subTest(args=args), patch.object(entry, "self_check"), \
                    patch.object(sys, "argv", ["run.py", *args]), patch.object(entry, "pull_snapshot") as pull:
                with self.assertRaises((IndexError, ValueError)):
                    entry.main()
                pull.assert_not_called()

    def test_static_and_generated_page_routes_from_root_and_view(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(api, "PROTOTYPE_DIR", directory):
            page = b"<html>GH-7 GENERATED PAGE FIXTURE</html>"
            Path(directory, "context-fixture.html").write_bytes(page)
            server = api.BoardHTTPServer(("127.0.0.1", 0),
                api.make_handler(BoardState(), config.BoardConfig(), api.RawRef(), None))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            origin = f"http://127.0.0.1:{server.server_address[1]}"
            old = Path.cwd()
            try:
                for cwd in (VIEW.parent, VIEW):
                    os.chdir(cwd)
                    for route, expected in (("/", (VIEW / "app/web/index.html").read_bytes()),
                            ("/assets/css/theme.css", (VIEW / "app/web/assets/css/theme.css").read_bytes()),
                            ("/assets/js/main.js", (VIEW / "app/web/assets/js/main.js").read_bytes()),
                            ("/prototypes/context-fixture.html", page)):
                        with self.subTest(cwd=cwd, route=route), urlopen(origin + route, timeout=5) as response:
                            self.assertEqual(response.read(), expected)
                    with self.assertRaises(HTTPError) as error:
                        urlopen(origin + "/prototypes/missing.html", timeout=5)
                    self.assertEqual(error.exception.code, 404)
            finally:
                os.chdir(old)
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()

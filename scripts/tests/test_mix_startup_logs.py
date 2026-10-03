"""Real Mix startup must not leave rotating logs in a View check candidate."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(os.environ.get("RUN_MIX_INTEGRATION") == "1" and shutil.which("mix"),
                     "opt-in real Mix integration")
class MixStartupLogTests(unittest.TestCase):
    def fixture(self, root):
        project = root / "project"
        for directory in ("config", "lib", "test"):
            (project / directory).mkdir(parents=True)
        shutil.copy2(ROOT / "elixir/config/config.exs", project / "config/config.exs")
        shutil.copy2(ROOT / "elixir/lib/symphony_elixir/log_file.ex", project / "lib/log_file.ex")
        (project / "mix.exs").write_text('''defmodule LogProbe.MixProject do
  use Mix.Project
  def project, do: [app: :symphony_elixir, version: "0.1.0"]
  def application, do: [extra_applications: [:logger], mod: {LogProbe, []}]
end
''')
        (project / "lib/probe.ex").write_text('''defmodule LogProbe do
  use Application
  require Logger
  def start(_, _) do
    :ok = SymphonyElixir.LogFile.configure()
    {:ok, handler} = :logger.get_handler_config(:symphony_disk_log)
    path = List.to_string(handler.config.file)
    Logger.warning("GH7 startup before test helper")
    Logger.flush()
    :ok = :logger_disk_log_h.filesync(:symphony_disk_log)
    File.write!(System.fetch_env!("GH7_LOG_PROBE"), path <> "\\n" <> File.read!(path <> ".1"))
    if System.get_env("GH7_STARTUP_FAIL") == "1", do: raise("GH7 application startup failure")
    Supervisor.start_link([], strategy: :one_for_one)
  end
end
''')
        (project / "test/probe_test.exs").write_text('''defmodule LogProbeTest do
  use ExUnit.Case
  test "application started before helper", do: assert(File.exists?(System.fetch_env!("GH7_LOG_PROBE")))
end
''')
        return project

    def inventory(self, project):
        # Include ignored files and compare bytes, not just Git's source list.
        return {str(path.relative_to(project)): path.read_bytes()
                for path in project.rglob("*") if path.is_file()}

    def exercise_invocations(self, root, project):
        temp = root / "temp"
        temp.mkdir(exist_ok=True)
        environment = dict(os.environ, MIX_ENV="test", TMPDIR=str(temp),
                           MIX_BUILD_PATH=str(root / "build"),
                           GH7_LOG_PROBE=str(root / "probe"), GH7_STARTUP_FAIL="0")
        paths = []
        for failure in (None, "helper", "startup", None, None):
            with self.subTest(failure=failure, invocation=len(paths)):
                helper = 'raise "GH7 helper failure"' if failure == "helper" else "ExUnit.start()"
                (project / "test/test_helper.exs").write_text(helper + "\n")
                before = self.inventory(project)
                environment["GH7_STARTUP_FAIL"] = "1" if failure == "startup" else "0"
                result = subprocess.run(["mix", "test"], cwd=project, env=environment,
                                        capture_output=True, text=True, timeout=60)
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 1 if failure else 0, output)
                if failure:
                    message = "GH7 helper failure" if failure == "helper" else "GH7 application startup failure"
                    self.assertIn(message, output)
                else:
                    self.assertIn("1 test, 0 failures", output)
                path, log = (root / "probe").read_text().split("\n", 1)
                path = Path(path)
                self.assertIn("GH7 startup before test helper", log)
                self.assertEqual(path.parent.parent, temp)
                self.assertNotIn(path, paths, "each Mix invocation needs its own log directory")
                paths.append(path)
                self.assertFalse(path.parent.exists(), "at_exit must remove rotating log siblings")
                self.assertEqual(list(temp.glob("symphony-test-logs-*")), [],
                                 "success and failure must clean up every invocation's logs")
                self.assertEqual(self.inventory(project), before,
                                 "Mix must neither add source-tree artifacts nor alter retained files")

    def test_startup_logs_are_external_and_removed_after_success_failure_and_retry(self):
        with tempfile.TemporaryDirectory(prefix="gh7-log-regression-") as temporary:
            root = Path(temporary)
            project = self.fixture(root)
            self.exercise_invocations(root, project)
            self.assertFalse((project / "log").exists())

    def test_retained_logs_survive_tests_and_can_be_preserved_outside_candidate(self):
        with tempfile.TemporaryDirectory(prefix="gh7-retained-log-regression-") as temporary:
            root = Path(temporary)
            project = self.fixture(root)
            logs = project / "log"
            logs.mkdir()
            retained = {"symphony.log.1": b"GH7 retained startup evidence\n",
                        "symphony.log.idx": b"\x00\x01legacy index",
                        "symphony.log.siz": b"\x00\x02legacy sizes"}
            for name, data in retained.items():
                (logs / name).write_bytes(data)
            self.exercise_invocations(root, project)
            self.assertEqual({p.name: p.read_bytes() for p in logs.iterdir()}, retained)
            # Redirecting new logs does not remove old artifacts. In a disposable
            # task copy only, explicitly preserve them before candidate validation.
            before = self.inventory(project)
            archive = root / "retained-evidence"
            shutil.copytree(logs, archive)
            self.assertEqual({p.name: p.read_bytes() for p in archive.iterdir()}, retained)
            shutil.move(str(logs), str(root / "original-log"))
            clean = {name: data for name, data in before.items() if not name.startswith("log/")}
            self.assertEqual(self.inventory(project), clean)
            self.exercise_invocations(root, project)
            self.assertEqual(self.inventory(project), clean)
            self.assertEqual({p.name: p.read_bytes() for p in archive.iterdir()}, retained)
            self.assertEqual({p.name: p.read_bytes() for p in (root / "original-log").iterdir()}, retained)

    def test_development_configuration_keeps_existing_log_default(self):
        with tempfile.TemporaryDirectory(prefix="gh7-dev-log-regression-") as temporary:
            root = Path(temporary)
            project = self.fixture(root)
            temp = root / "temp"
            temp.mkdir()
            result = subprocess.run(["mix", "run", "-e",
                                     'IO.puts("GH7_LOG_DEFAULT=#{inspect(Application.get_env(:symphony_elixir, :log_file))}")'],
                                    cwd=project, env=dict(os.environ, MIX_ENV="dev", TMPDIR=str(temp),
                                                         MIX_BUILD_PATH=str(root / "build"),
                                                         GH7_LOG_PROBE=str(root / "probe"), GH7_STARTUP_FAIL="0"),
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("GH7_LOG_DEFAULT=nil", result.stdout)
            self.assertIn("GH7 startup before test helper", (project / "log/symphony.log.1").read_text())
            self.assertTrue((project / "log/symphony.log.idx").is_file())
            self.assertTrue((project / "log/symphony.log.siz").is_file())
            self.assertEqual(list(temp.glob("symphony-test-logs-*")), [])


if __name__ == "__main__":
    unittest.main()

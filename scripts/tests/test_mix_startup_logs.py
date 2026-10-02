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

    def test_startup_logs_are_external_and_removed_after_success_failure_and_retry(self):
        with tempfile.TemporaryDirectory(prefix="gh7-log-regression-") as temporary:
            root = Path(temporary)
            project = self.fixture(root)
            temp = root / "temp"
            temp.mkdir()
            environment = dict(os.environ, MIX_ENV="test", TMPDIR=str(temp),
                               GH7_LOG_PROBE=str(root / "probe"))
            paths = []
            for failing in (False, True, False):
                with self.subTest(helper_failure=failing, invocation=len(paths)):
                    helper = 'raise "GH7 helper failure"' if failing else "ExUnit.start()"
                    (project / "test/test_helper.exs").write_text(helper + "\n")
                    result = subprocess.run(["mix", "test"], cwd=project, env=environment,
                                            capture_output=True, text=True, timeout=60)
                    output = result.stdout + result.stderr
                    self.assertEqual(result.returncode, 1 if failing else 0, output)
                    if failing:
                        self.assertIn("GH7 helper failure", output)
                    else:
                        self.assertIn("1 test, 0 failures", output)
                    path, log = (root / "probe").read_text().split("\n", 1)
                    path = Path(path)
                    self.assertIn("GH7 startup before test helper", log)
                    self.assertEqual(path.parent.parent, temp)
                    self.assertNotIn(path, paths, "each Mix invocation needs its own log directory")
                    paths.append(path)
                    self.assertFalse(path.parent.exists(), "at_exit must remove rotating log siblings")
                    self.assertFalse((project / "log").exists(), "startup must not dirty the checkout")
                    self.assertEqual(list(temp.glob("symphony-test-logs-*")), [],
                                     "success and failure must clean up every invocation's logs")

    def test_development_configuration_keeps_existing_log_default(self):
        with tempfile.TemporaryDirectory(prefix="gh7-dev-log-regression-") as temporary:
            root = Path(temporary)
            project = self.fixture(root)
            temp = root / "temp"
            temp.mkdir()
            result = subprocess.run(["mix", "run", "--no-start", "-e",
                                     'IO.puts("GH7_LOG_DEFAULT=#{inspect(Application.get_env(:symphony_elixir, :log_file))}")'],
                                    cwd=project, env=dict(os.environ, MIX_ENV="dev", TMPDIR=str(temp)),
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("GH7_LOG_DEFAULT=nil", result.stdout)
            self.assertEqual(list(temp.glob("symphony-test-logs-*")), [])


if __name__ == "__main__":
    unittest.main()

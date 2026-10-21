# Local-only fault-injection fixture. Model and publication callbacks are synthetic;
# Git, persisted receipts, checks, OS ownership and restart recovery are real.
alias SymphonyElixir.{Workflow, Workspace}
alias SymphonyElixir.Tracker.Issue
alias SymphonyElixir.Mvp.{Commands, Executor, Receipt, Recovery, RestartRecovery}

[root] = System.argv()
true = Regex.match?(~r/\A\/var\/lib\/symphony-vm-fixtures\/[a-z0-9-]+\z/, root)
File.mkdir_p!(root)
workflow = Path.join(root, "WORKFLOW.md")

File.write!(
  workflow,
  "---\n" <>
    Jason.encode!(%{
      "tracker" => %{
        "kind" => "github",
        "active_states" => ["open"],
        "terminal_states" => ["closed"],
        "provider" => %{"repo" => "fixture/repo", "token" => "synthetic-not-a-credential"}
      },
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "mvp" => %{"enabled" => false}
    }) <> "\n---\nLocal restart fixture; never dispatch platform work.\n"
)

Workflow.set_workflow_file_path(workflow)

workspace = Path.join(root, "workspaces/" <> Workspace.workspace_key(%{identifier: "LOCAL-901", id: "901"}))
remote = Path.join(root, "origin.git")

unless File.dir?(remote) do
  File.mkdir_p!(workspace)
  Commands.git!(["init", "--bare", remote], root)
  Commands.git!(["init"], workspace)
  File.write!(Path.join(workspace, "source.txt"), "local fixture baseline\n")
  Commands.git!(["add", "source.txt"], workspace)
  Commands.git!(["commit", "-m", "fixture baseline"], workspace)
  Commands.git!(["branch", "-M", "main"], workspace)
  Commands.git!(["push", remote, "main"], workspace)
end

marker = Path.join(root, "check-started")
check = "import pathlib,time; p=pathlib.Path(#{inspect(marker)}); first=not p.exists(); p.write_text('formal check started'); print('local formal check', flush=True); time.sleep(180 if first else 0)"
{:ok, policy} = Recovery.settings(%{"enabled" => true, "resume_on_restart" => true, "max_elapsed_ms" => 14_400_000})
{uuid, 0} = System.cmd("sudo", ["-n", "cat", "/sys/class/dmi/id/product_uuid"])

settings = %{
  checks: [["python3", "-u", "-c", check]],
  check_timeout_ms: 600_000,
  max_rework: 0,
  ready_label: "ready",
  recovery: policy,
  sandbox: %{enabled: false},
  state_dir: Path.join(root, "state"),
  workflow_path: workflow,
  execution_workspace_root: Path.join(root, "workspaces"),
  execution_readiness: %{enabled: true, required_backend: "vm", vm_uuid: String.trim(uuid)},
  model_command: "codex app-server"
}

issue = %Issue{
  id: "901",
  identifier: "LOCAL-901",
  title: "local restart fixture",
  description: "Preserve the exact candidate and original budget after interruption.",
  state: "open",
  labels: ["ready"],
  native_ref: %{"kind" => "github", "repo" => "fixture/repo", "number" => 901}
}

models = %{coder: "synthetic-coder", reviewer: "synthetic-reviewer", services: nil}
receipt = Receipt.path(settings, issue)

options = [
  repository: fn _, _ -> {:ok, %{repo: "fixture/repo", base: "main", url: remote}} end,
  tracker_settings: %{kind: "github", provider: %{"repo" => "fixture/repo", "token" => "synthetic-not-a-credential"}},
  request_fun: fn "POST", _, _, body, _ -> {:ok, %{status: 201, body: %{"id" => 1, "body" => body["body"]}}} end,
  agent: fn directory, _, _, options ->
    options[:on_message].(%{usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}})

    if options[:read_only] do
      review = %{
        "approved" => true,
        "summary" => "Local synthetic review; no external model called.",
        "blockers" => [],
        "criteria" => [
          %{
            "acceptance" => "Persist the candidate",
            "tests" => ["local formal check"],
            "assertion_strength" => "Fixture verifies exact SHA and original budget after OS restart",
            "failure_sensitivity" => "Changed candidate or reset counters fails fixture assertions",
            "adequate" => true
          }
        ]
      }

      {:ok, %{output_text: Jason.encode!(review)}}
    else
      File.write!(Path.join(directory, "candidate.txt"), "synthetic model output\n")
      {:ok, %{output_text: "Local synthetic coder; no external model called."}}
    end
  end,
  publish: fn _, _, _, _, sha, path, _ ->
    Receipt.update(path, "awaiting_human", %{"pull_request" => "local-fixture://draft", "fixture_candidate_sha" => sha})
    {:ok, "local-fixture://draft"}
  end
]

result =
  if File.exists?(receipt) do
    RestartRecovery.resume(workspace, issue, settings, models, receipt, options)
  else
    {:ok, ^receipt} = Receipt.claim(settings, issue)
    Executor.run(workspace, issue, settings, models, receipt, options)
  end

data = Receipt.read(receipt)

File.write!(
  Path.join(root, "fixture-result.json"),
  Jason.encode!(
    %{
      "result" => inspect(result),
      "candidate_sha" => data["candidate_sha"],
      "generation" => get_in(data, ["restart_recovery", "generation"]),
      "started_at" => get_in(data, ["recovery", "started_at"]),
      "agent_attempts" => get_in(data, ["recovery", "agent_attempts"]),
      "real_model_calls" => 0,
      "real_platform_writes" => 0
    },
    pretty: true
  )
)

case result do
  {:ok, "local-fixture://draft"} -> :ok
  _ -> System.halt(1)
end

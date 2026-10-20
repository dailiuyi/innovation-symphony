defmodule SymphonyElixir.Mvp.CheckEvidenceExecutorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ModelServicesFixture, as: Fixture
  alias SymphonyElixir.Mvp.{CheckEvidence, Commands, Delivery, Executor, Intake, Receipt, Recovery, Review}

  @tag :check_evidence_boundary
  test "zero-rework review rejects malformed audit collections and approval types without exceptions" do
    base = %{"approved" => true, "summary" => "checked candidate"}

    for field <- ~w(criteria blockers), value <- [true, 42, "not a list", %{}, [nil], [" "], [%{}]] do
      raw = base |> Map.put(field, value) |> Jason.encode!()
      assert {:error, :mvp_invalid_review} = Review.parse(raw, 0)
      assert [%{"code" => "invalid_review_schema"}] = Review.validation_errors(raw, 0)
    end

    for changed <- [%{"approved" => "true"}, %{"summary" => 1}, %{"summary" => ""}, %{"unexpected" => "field"}] do
      raw = base |> Map.merge(changed) |> Jason.encode!()
      assert {:error, :mvp_invalid_review} = Review.parse(raw, 0)
    end
  end

  @tag :check_evidence_boundary
  test "zero-rework optional audit traces preserve approval and rejection safety" do
    base = %{"approved" => true, "summary" => "checked candidate"}

    for fields <- [%{}, %{"criteria" => nil}, %{"criteria" => []}, %{"criteria" => ["signature verified", %{"adequate" => true}], "blockers" => []}] do
      expected = Map.merge(base, fields)
      raw = Jason.encode!(expected)
      assert {:ok, ^expected} = Review.parse(raw, 0)
      assert Review.validation_errors(raw, 0) == []
      assert Review.disposition(expected) == :approved
    end

    inadequate = Map.put(base, "criteria", [%{"adequate" => false}])
    assert {:error, :mvp_invalid_review} = Review.parse(Jason.encode!(inadequate), 0)
    rejection = Map.merge(inadequate, %{"approved" => false, "blockers" => ["missing signature assertion"]})
    assert {:ok, ^rejection} = Review.parse(Jason.encode!(rejection), 0)
    assert Review.disposition(rejection) == :repair_code
    refute Review.external_draft?(rejection)
  end

  test "Reviewer receives every current check and no prior failed-attempt output" do
    context = execution_context!()
    counter = Path.join(context.root, "attempt-count")

    checks = [
      [
        "sh",
        "-c",
        "n=0; test ! -f '#{counter}' || n=$(cat '#{counter}'); n=$((n+1)); echo $n > '#{counter}'; if test $n = 1; then echo ORIGINAL_FAILED_ATTEMPT; exit 1; fi; echo CURRENT_PASSING_ATTEMPT"
      ],
      ["sh", "-c", "printf '{\"passed\":true,\"checks\":2}'"]
    ]

    policy = %{"enabled" => true, "max_rework" => 2, "diagnose_every" => 1, "max_agent_attempts" => 10, "stage_attempts" => 3, "max_elapsed_ms" => 60_000}
    {:ok, recovery} = Recovery.settings(policy)
    settings = %{checks: checks, check_timeout_ms: 10_000, max_rework: 2, recovery: recovery}

    assert {:ok, "local-publish"} = Executor.run(context.workspace, context.issue, settings, models(), context.receipt, options(context))
    assert_receive {:formal_reviewer_prompt, prompt}
    assert prompt =~ "CURRENT_PASSING_ATTEMPT"
    assert prompt =~ Jason.encode!("CURRENT_PASSING_ATTEMPT\n")
    assert prompt =~ "checks"
    assert prompt =~ "check-attempt-2/check-1.log"
    assert prompt =~ "check-attempt-2/check-2.log"
    assert prompt =~ ~s("attempt":2)
    assert prompt =~ "Do not classify an already verified acceptance as an external_condition"
    refute prompt =~ "ORIGINAL_FAILED_ATTEMPT\\n"

    data = Receipt.read(context.receipt)
    root = hd(data["rounds"])["evidence"]
    assert File.read!(Path.join(root, "check-1.log")) == "ORIGINAL_FAILED_ATTEMPT\n"
    assert File.read!(Path.join(root, "check-attempt-2/check-1.log")) == "CURRENT_PASSING_ATTEMPT\n"
    record = File.read!(Path.join(root, "check-attempt-2/check-2.json")) |> Jason.decode!()
    assert record["candidate_sha"] == data["candidate_sha"]
    assert record["round"] == 1
    assert record["attempt"] == 2
    assert record["structured_result"] == %{"passed" => true, "checks" => 2}
    assert File.read!(counter) == "2\n"
  end

  test "legacy zero-rework execution passes all current formal records to Reviewer" do
    context = execution_context!()
    settings = %{checks: [["printf", "CURRENT_ONE"], ["printf", "CURRENT_TWO"]], check_timeout_ms: 10_000}

    assert {:ok, "local-publish"} = Executor.run(context.workspace, context.issue, settings, models(), context.receipt, options(context))
    assert_receive {:formal_reviewer_prompt, prompt}
    assert prompt =~ "CURRENT_ONE"
    assert prompt =~ "CURRENT_TWO"
    assert prompt =~ Jason.encode!("CURRENT_ONE")
    assert prompt =~ Jason.encode!("CURRENT_TWO")
    assert prompt =~ ~s("attempt":1)
    assert prompt =~ "UNTRUSTED PROJECT OUTPUT"
    assert prompt =~ Commands.git!(["rev-parse", "HEAD"], context.workspace)
    assert File.regular?(context.receipt <> ".evidence/check-1.log")
    assert File.regular?(context.receipt <> ".evidence/check-2.log")
    refute Map.has_key?(Receipt.read(context.receipt), "rounds")
  end

  test "zero rework with frozen services publishes through Delivery with complete round evidence" do
    context = execution_context!()
    previous_coder = System.get_env("GH12_CODER_KEY")
    previous_reviewer = System.get_env("GH12_REVIEWER_KEY")
    System.put_env("GH12_CODER_KEY", "synthetic-coder")
    System.put_env("GH12_REVIEWER_KEY", "synthetic-reviewer")

    on_exit(fn ->
      restore_env("GH12_CODER_KEY", previous_coder)
      restore_env("GH12_REVIEWER_KEY", previous_reviewer)
    end)

    config = %{checks: [["test", "-f", "{workspace}/candidate.txt"]], check_timeout_ms: 10_000, max_rework: 0}
    settings = Map.merge(Fixture.settings(Path.join(context.root, "authority")), config)
    Workflow.set_workflow_file_path(settings.workflow_path)
    assert :ok = WorkflowStore.force_reload()
    {:ok, selected} = Intake.resolve_comments([], settings)

    opts =
      context
      |> options()
      |> Keyword.put(:agent, &frozen_service_agent/4)
      |> Keyword.put(:publish, &Delivery.publish/7)
      |> Keyword.put(:ready_label, "ready")
      |> Keyword.put(:request_fun, frozen_delivery_request(context))

    url = "https://github.com/owner/repo/pull/42"
    assert {:ok, ^url} = Executor.run(context.workspace, context.issue, settings, selected, context.receipt, opts)
    data = Receipt.read(context.receipt)
    assert data["status"] == "awaiting_human"
    refute data["recovery"]["enabled"]
    assert data["rework_count"] == 0
    assert [round] = data["rounds"]
    assert round["candidate_sha"] == data["candidate_sha"]
    assert round["review"] == data["review"]
    assert round["review_path"] == data["review_path"]
    assert round["services"] == selected.services
    assert File.regular?(round["review_path"])
    assert round["formal_check_binding"] == data["formal_check_binding"]
    assert {:ok, [_]} = CheckEvidence.delivery_proof(context.receipt, context.workspace, data["candidate_sha"])
    assert Commands.git!(["--git-dir", context.remote, "rev-parse", "refs/heads/#{data["branch"]}"], context.root) == data["candidate_sha"]
    assert_receive {:frozen_delivery_created, ^url}
  end

  test "missing or corrupted formal evidence stops before Reviewer or publish despite passing check exits" do
    mutations = ~w(sha attempt round incomplete wrong_argv missing_record missing_log tampered_log truncated_log missing_manifest)

    for mutation <- mutations do
      context = execution_context!()

      code = """
      import json, pathlib, sys
      root, receipt, mutation = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
      record_path = root / 'check-1.json'
      record = json.loads(record_path.read_text())
      log = pathlib.Path(record['log_path'])
      if mutation == 'missing_record':
          record_path.unlink()
      elif mutation == 'missing_log':
          log.unlink()
      elif mutation == 'tampered_log':
          log.write_text('X' * len(log.read_bytes()))
      elif mutation == 'truncated_log':
          log.write_text('first')
      elif mutation == 'missing_manifest':
          data = json.loads(receipt.read_text())
          del data['formal_check_evidence']
          receipt.write_text(json.dumps(data))
      else:
          fields = {'sha': ('candidate_sha', 'b' * 40), 'attempt': ('attempt', 99),
                    'round': ('round', 99), 'incomplete': ('completed', False),
                    'wrong_argv': ('argv', ['wrong'])}
          field, value = fields[mutation]
          record[field] = value
          record_path.write_text(json.dumps(record))
      print('final check exited successfully')
      """

      checks = [["printf", "first check passed"], ["python3", "-c", code, "{evidence}", context.receipt, mutation]]
      settings = %{checks: checks, check_timeout_ms: 10_000}

      assert {:error, :mvp_check_evidence_unavailable} =
               Executor.run(context.workspace, context.issue, settings, models(), context.receipt, options(context))

      refute_receive {:formal_reviewer_prompt, _}, 10
      refute_receive :formal_publish, 10
    end
  end

  test "an empty check configuration cannot silently enter Review" do
    context = execution_context!()
    settings = %{checks: [], check_timeout_ms: 10_000}

    assert {:error, :mvp_check_evidence_unavailable} =
             Executor.run(context.workspace, context.issue, settings, models(), context.receipt, options(context))

    refute_receive {:formal_reviewer_prompt, _}
    refute_receive :formal_publish
  end

  test "normal publication rejects corrupt new evidence before receipt or remote effects" do
    context = execution_context!()
    settings = %{checks: [["printf", "completed candidate check"]], check_timeout_ms: 10_000}
    assert {:ok, "local-publish"} = Executor.run(context.workspace, context.issue, settings, models(), context.receipt, options(context))
    data = Receipt.read(context.receipt)
    [path] = data["formal_check_evidence"]["records"]
    original = File.read!(path)
    record = Jason.decode!(original)

    opts = [request_fun: fn _, _, _, _, _ -> flunk("must not contact the forge for invalid evidence") end]
    repository = %{repo: "owner/repo", base: "main", url: context.remote}

    for change <- [%{"completed" => false}, %{"attempt" => 99}, %{"candidate_sha" => String.duplicate("f", 40)}, %{"log_sha256" => String.duplicate("0", 64)}] do
      File.write!(path, Jason.encode!(Map.merge(record, change)))
      before = File.read!(context.receipt)
      assert {:error, :mvp_check_evidence_unavailable} = Delivery.publish(context.workspace, context.issue, repository, data["branch"], data["candidate_sha"], context.receipt, opts)
      assert File.read!(context.receipt) == before
      assert Commands.git!(["ls-remote", context.remote, "refs/heads/#{data["branch"]}"], context.workspace) == ""
    end

    File.write!(path, original)
    File.write!(record["log_path"], "changed raw output")
    before = File.read!(context.receipt)
    assert {:error, :mvp_check_evidence_unavailable} = Delivery.publish(context.workspace, context.issue, repository, data["branch"], data["candidate_sha"], context.receipt, opts)
    assert File.read!(context.receipt) == before
  end

  defp execution_context! do
    root = Path.join(System.tmp_dir!(), "symphony-formal-check-executor-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(workspace)
    Commands.git!(["init", "--bare", remote], root)
    Commands.git!(["init"], workspace)
    File.write!(Path.join(workspace, "source.txt"), "base")
    Commands.git!(["add", "source.txt"], workspace)
    Commands.git!(["commit", "-m", "base"], workspace)
    Commands.git!(["branch", "-M", "main"], workspace)
    Commands.git!(["remote", "add", "origin", remote], workspace)
    Commands.git!(["push", "origin", "main"], workspace)

    issue = %Issue{id: "42", identifier: "GH-42", title: "Create candidate", description: "Create candidate.txt", native_ref: %{"repo" => "owner/repo", "number" => 42}}
    {:ok, receipt} = Receipt.claim(%{state_dir: Path.join(root, "state")}, issue)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, remote: remote, issue: issue, receipt: receipt}
  end

  defp frozen_service_agent(workspace, _, _, opts) do
    role = opts[:model_service]["role"]
    if role == "coder", do: File.write!(Path.join(workspace, "candidate.txt"), "frozen candidate")
    output = if role == "reviewer", do: Jason.encode!(%{"approved" => true, "summary" => "verified"}), else: "implemented"
    {:ok, %{output_text: output}}
  end

  defp frozen_delivery_request(context) do
    fn method, path, _, body, _ ->
      frozen_delivery_reply(context, method, path, body)
    end
  end

  defp frozen_delivery_reply(_context, "GET", "/repos/owner/repo/issues/42", nil) do
    {:ok, %{status: 200, body: %{"state" => "open", "labels" => [%{"name" => "ready"}]}}}
  end

  defp frozen_delivery_reply(_context, "GET", "/repos/owner/repo/pulls", nil), do: {:ok, %{status: 200, body: []}}

  defp frozen_delivery_reply(context, "POST", "/repos/owner/repo/pulls", body) do
    data = Receipt.read(context.receipt)
    assert data["status"] == "publish_pending"
    assert body["draft"] == true
    url = "https://github.com/owner/repo/pull/42"

    pull = %{
      "head" => %{"repo" => %{"full_name" => "owner/repo"}, "ref" => body["head"], "sha" => data["candidate_sha"]},
      "base" => %{"repo" => %{"full_name" => "owner/repo"}, "ref" => body["base"]},
      "html_url" => url
    }

    send(self(), {:frozen_delivery_created, url})
    {:ok, %{status: 201, body: pull}}
  end

  defp options(context) do
    parent = self()

    agent = fn workspace, prompt, _, opts ->
      cond do
        opts[:output_schema] == Recovery.schema() ->
          {:ok, %{output_text: Jason.encode!(%{"action" => "retry_stage", "summary" => "temporary check failure", "steps" => ["retry trusted checks"], "external_conditions" => []})}}

        opts[:read_only] ->
          send(parent, {:formal_reviewer_prompt, prompt})

          review = %{
            "approved" => true,
            "summary" => "verified",
            "criteria" => [
              %{
                "acceptance" => "Create candidate.txt",
                "tests" => ["candidate check"],
                "assertion_strength" => "checks the candidate",
                "failure_sensitivity" => "missing candidate fails",
                "adequate" => true
              }
            ],
            "blockers" => []
          }

          {:ok, %{output_text: Jason.encode!(review)}}

        true ->
          File.write!(Path.join(workspace, "candidate.txt"), "candidate")
          {:ok, %{output_text: "implemented"}}
      end
    end

    [
      repository: fn _, _ -> {:ok, %{repo: "owner/repo", base: "main", url: context.remote}} end,
      tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "synthetic"}},
      agent: agent,
      publish: fn _, _, _, _, _, _, _ ->
        send(parent, :formal_publish)
        {:ok, "local-publish"}
      end
    ]
  end

  defp models, do: %{coder: "coder-model", reviewer: "reviewer-model"}
end

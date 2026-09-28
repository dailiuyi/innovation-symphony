defmodule SymphonyElixir.Mvp.ExecutorTest do
  use SymphonyElixir.TestSupport

  alias Mix.Tasks.PrBody.Check, as: PrBodyCheck
  alias SymphonyElixir.Mvp.{Commands, Delivery, Executor, Receipt}

  @review_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["approved", "summary"],
    "properties" => %{
      "approved" => %{"type" => "boolean"},
      "summary" => %{"type" => "string"}
    }
  }

  test "five-argument run fails closed when its default GitHub repository adapter has no credentials" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    previous_repo = System.get_env("GITHUB_REPO")
    previous_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      restore_env("GITHUB_REPO", previous_repo)
      restore_env("GITHUB_TOKEN", previous_token)
    end)

    System.delete_env("GITHUB_REPO")
    System.delete_env("GITHUB_TOKEN")

    assert {:error, :mvp_repository_lookup_failed} =
             Executor.run(
               context.workspace,
               context.issue,
               check_settings([]),
               models(),
               context.receipt
             )
  end

  test "creates a checked candidate and calls coder and reviewer independently before publish" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    add_snapshot_edge_entries!(context)

    agent = agent_stub(self())
    publish = recording_publish(self())

    assert {:ok, "https://github.com/owner/repo/pull/42"} =
             Executor.run(
               context.workspace,
               context.issue,
               check_settings([
                 ["test", "-f", "{workspace}/candidate.txt"],
                 ["test", "-f", "{baseline}/source.txt"]
               ]),
               models(),
               context.receipt,
               executor_opts(context, agent: agent, publish: publish)
             )

    assert_receive {:mvp_agent_call, 1, :coder, coder_workspace, coder_prompt, "GH-42", coder_opts}
    assert coder_workspace == context.workspace
    assert coder_prompt =~ "Implement only this repository's issue"
    assert Keyword.get(coder_opts, :model) == "coder-model"
    assert Keyword.get(coder_opts, :tools) == false
    refute Keyword.has_key?(coder_opts, :read_only)

    assert_receive {:mvp_agent_call, 2, :reviewer, reviewer_workspace, review_prompt, "GH-42", reviewer_opts}
    assert reviewer_workspace == context.workspace
    assert review_prompt =~ "Review git diff"
    assert Keyword.get(reviewer_opts, :model) == "reviewer-model"
    assert Keyword.get(reviewer_opts, :tools) == false
    assert Keyword.get(reviewer_opts, :read_only) == true
    assert Keyword.get(reviewer_opts, :output_schema) == @review_schema

    assert_receive {:mvp_publish_call, publish_workspace, "GH-42", repository, branch, sha, receipt, publish_opts}
    assert publish_workspace == context.workspace
    assert repository.repo == "owner/repo"
    assert repository.base == "main"
    assert branch == "codex/symphony-#{Path.basename(context.receipt, ".json")}"
    assert receipt == context.receipt
    assert sha == Commands.git!(["rev-parse", "HEAD"], context.workspace)
    assert review_prompt =~ sha
    publish_tracker_settings = Keyword.fetch!(publish_opts, :tracker_settings)
    assert publish_tracker_settings.provider["token"] == "fake-token"

    receipt_data = Receipt.read(context.receipt)
    assert receipt_data["candidate_sha"] == sha
    assert receipt_data["base_sha"] != sha
    assert receipt_data["status"] == "reviewing"

    assert File.exists?(context.receipt <> ".evidence/check-1.log")
    assert File.exists?(context.receipt <> ".evidence/check-2.log")
    baseline = Path.join(context.receipt <> ".evidence", "baseline")
    assert File.lstat!(Path.join(baseline, "source-link.txt")).type == :symlink
    assert File.lstat!(Path.join(baseline, "nested")).type == :directory
    assert File.read!(Path.join(context.workspace, "candidate.txt")) == "candidate change\n"
    assert Commands.git(["status", "--porcelain"], context.workspace) == {:ok, ""}
    refute_receive {:mvp_agent_call, _, _, _, _, _, _}
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
  end

  test "a failed check prevents review and publish" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    assert {:error, {:mvp_check_failed, 1}} =
             Executor.run(
               context.workspace,
               context.issue,
               check_settings([["false"]]),
               models(),
               context.receipt,
               executor_opts(context,
                 agent: agent_stub(self()),
                 publish: recording_publish(self())
               )
             )

    assert_receive {:mvp_agent_call, 1, :coder, _, _, "GH-42", _}
    refute_receive {:mvp_agent_call, _, :reviewer, _, _, _, _}
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
    assert File.exists?(context.receipt <> ".evidence/check-1.log")
    assert Receipt.read(context.receipt)["status"] == "checking"
  end

  test "a check that changes the frozen baseline prevents review and publish" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    assert {:error, :mvp_candidate_or_baseline_changed} =
             Executor.run(
               context.workspace,
               context.issue,
               check_settings([["touch", "{baseline}/tampered.txt"]]),
               models(),
               context.receipt,
               executor_opts(context,
                 agent: agent_stub(self()),
                 publish: recording_publish(self())
               )
             )

    assert_receive {:mvp_agent_call, 1, :coder, _, _, "GH-42", _}
    refute_receive {:mvp_agent_call, _, :reviewer, _, _, _, _}
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
    assert File.exists?(context.receipt <> ".evidence/baseline/tampered.txt")
    assert Receipt.read(context.receipt)["status"] == "checking"
  end

  test "a rejected review prevents publish" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    agent =
      agent_stub(self(),
        review_result: %{"approved" => false, "summary" => "The candidate misses a requirement."}
      )

    assert {:error, :mvp_review_not_approved} =
             Executor.run(
               context.workspace,
               context.issue,
               check_settings([["test", "-f", "{workspace}/candidate.txt"]]),
               models(),
               context.receipt,
               executor_opts(context, agent: agent, publish: recording_publish(self()))
             )

    assert_receive {:mvp_agent_call, 1, :coder, _, _, "GH-42", _}
    assert_receive {:mvp_agent_call, 2, :reviewer, _, _, "GH-42", opts}
    assert Keyword.get(opts, :read_only) == true
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
    assert Receipt.read(context.receipt)["status"] == "reviewing"
    assert Jason.decode!(File.read!(context.receipt <> ".evidence/review.json"))["approved"] == false
  end

  test "blocks an agent that changes the Git HEAD" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    assert {:error, :mvp_head_changed} =
             Executor.run(
               context.workspace,
               context.issue,
               check_settings([["true"]]),
               models(),
               context.receipt,
               executor_opts(context,
                 agent: agent_stub(self(), tamper: :head),
                 publish: recording_publish(self())
               )
             )

    assert_receive {:mvp_agent_call, 1, :coder, _, _, "GH-42", _}
    refute_receive {:mvp_agent_call, _, :reviewer, _, _, _, _}
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
  end

  test "blocks an agent that changes Git metadata" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    assert {:error, :mvp_git_metadata_changed} =
             Executor.run(
               context.workspace,
               context.issue,
               check_settings([["true"]]),
               models(),
               context.receipt,
               executor_opts(context,
                 agent: agent_stub(self(), tamper: :metadata),
                 publish: recording_publish(self())
               )
             )

    assert_receive {:mvp_agent_call, 1, :coder, _, _, "GH-42", _}
    refute_receive {:mvp_agent_call, _, :reviewer, _, _, _, _}
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
  end

  test "receipt claims are exclusive across repeated attempts" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    assert context.receipt == Receipt.path(%{state_dir: Path.join(context.root, "state")}, context.issue)
    assert Receipt.exists?(%{state_dir: Path.join(context.root, "state")}, context.issue)

    assert {:error, :mvp_receipt_exists} =
             Receipt.claim(%{state_dir: Path.join(context.root, "state")}, context.issue)

    assert {:error, :mvp_receipt_exists} =
             Receipt.claim(%{state_dir: Path.join(context.root, "state")}, context.issue)
  end

  test "git environment uses GITHUB_TOKEN when the configured provider token is absent" do
    prior_token = System.get_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", prior_token) end)
    fallback_token = "mvp-git-env-fallback-token"
    System.put_env("GITHUB_TOKEN", fallback_token)

    assert {:ok, env} =
             Delivery.git_env(tracker_settings: %{provider: %{"repo" => "owner/repo"}})

    expected_header = "AUTHORIZATION: basic " <> Base.encode64("x-access-token:" <> fallback_token)
    assert {"GIT_CONFIG_VALUE_0", expected_header} in env
  end

  test "git environment resolves a configured token reference and rejects missing credentials or API overrides" do
    prior_github_token = System.get_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", prior_github_token) end)
    System.delete_env("GITHUB_TOKEN")

    env_key = "SYMP_MVP_TEST_TOKEN_#{System.unique_integer([:positive])}"
    on_exit(fn -> restore_env(env_key, nil) end)
    System.put_env(env_key, "provider-env-token")

    assert {:ok, env} =
             Delivery.git_env(tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "$#{env_key}"}})

    expected_header = "AUTHORIZATION: basic " <> Base.encode64("x-access-token:provider-env-token")
    assert {"GIT_CONFIG_VALUE_0", expected_header} in env

    assert {:error, :mvp_requires_github_com_token} =
             Delivery.git_env(tracker_settings: %{provider: %{"repo" => "owner/repo"}})

    assert {:error, :mvp_requires_github_com_token} =
             Delivery.git_env(
               tracker_settings: %{
                 provider: %{"repo" => "owner/repo", "token" => "fake-token", "api_url" => "https://github.example.test"}
               }
             )
  end

  test "repository lookup returns the GitHub identity and rejects a different identity" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    request_fun = fn "GET", "/repos/owner/repo", %{}, nil, github_settings ->
      assert github_settings.repo == "owner/repo"
      assert github_settings.token == "fake-token"
      {:ok, %{status: 200, body: %{"full_name" => "owner/repo", "default_branch" => "main"}}}
    end

    assert {:ok, repository} =
             Delivery.repository(
               context.issue,
               tracker_settings: github_tracker_settings(),
               request_fun: request_fun
             )

    assert repository == %{
             repo: "owner/repo",
             base: "main",
             url: "https://github.com/owner/repo.git"
           }

    wrong_identity_request = fn "GET", "/repos/owner/repo", %{}, nil, _github_settings ->
      {:ok, %{status: 200, body: %{"full_name" => "someone-else/repo", "default_branch" => "main"}}}
    end

    assert {:error, :mvp_repository_lookup_failed} =
             Delivery.repository(
               context.issue,
               tracker_settings: github_tracker_settings(),
               request_fun: wrong_identity_request
             )

    unavailable_request = fn "GET", "/repos/owner/repo", %{}, nil, _github_settings ->
      {:error, :network_unavailable}
    end

    assert {:error, :mvp_repository_lookup_failed} =
             Delivery.repository(
               context.issue,
               tracker_settings: github_tracker_settings(),
               request_fun: unavailable_request
             )
  end

  test "publish pushes the candidate branch and creates a draft PR with the exact delivery identity" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    sha = candidate_commit!(context)
    branch = "codex/symphony-publish"
    request_fun = publish_request(self(), sha: sha)
    opts = delivery_opts(request_fun)

    assert {:ok, "https://github.com/owner/repo/pull/42"} =
             Delivery.publish(
               context.workspace,
               context.issue,
               context.repository,
               branch,
               sha,
               context.receipt,
               opts
             )

    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/issues/42", %{}, nil}
    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/pulls", pull_query, nil}
    assert pull_query == %{"head" => "owner:#{branch}", "state" => "all", "per_page" => 100}

    assert_receive {:mvp_delivery_request, "POST", "/repos/owner/repo/pulls", %{}, pull_body}
    assert pull_body["title"] == "GH-42: Add a candidate file"
    assert pull_body["head"] == branch
    assert pull_body["base"] == "main"
    assert pull_body["draft"] == true

    assert pull_body["body"] =~ sha
    pull_body_file = Path.join(context.root, "pull-request-body.md")
    File.write!(pull_body_file, pull_body["body"])
    PrBodyCheck.run(["--file", pull_body_file])

    assert remote_ref_sha(context, branch) == sha
    receipt_data = Receipt.read(context.receipt)
    assert receipt_data["status"] == "awaiting_human"
    assert receipt_data["candidate_sha"] == sha
    assert receipt_data["pull_request"] == "https://github.com/owner/repo/pull/42"
  end

  test "publish does not overwrite a branch created remotely after the candidate was prepared" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    candidate_sha = candidate_commit!(context)
    branch = "codex/symphony-existing-branch"
    competing_sha = push_competing_branch!(context, branch)
    request_fun = publish_request(self(), sha: candidate_sha)

    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} =
             Delivery.publish(
               context.workspace,
               context.issue,
               context.repository,
               branch,
               candidate_sha,
               context.receipt,
               delivery_opts(request_fun)
             )

    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/issues/42", _, nil}
    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/pulls", _, nil}
    refute_receive {:mvp_delivery_request, "POST", "/repos/owner/repo/pulls", _, _}
    assert remote_ref_sha(context, branch) == competing_sha
    assert competing_sha != candidate_sha
    assert Receipt.read(context.receipt)["status"] == "publish_pending"
  end

  test "publish rejects a non-list pull lookup response before pushing" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    sha = candidate_commit!(context)
    branch = "codex/symphony-invalid-pull-lookup"
    request_fun = publish_request(self(), sha: sha, existing_pulls: %{"unexpected" => true})

    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} =
             Delivery.publish(
               context.workspace,
               context.issue,
               context.repository,
               branch,
               sha,
               context.receipt,
               delivery_opts(request_fun)
             )

    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/issues/42", _, nil}
    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/pulls", _, nil}
    refute_receive {:mvp_delivery_request, "POST", "/repos/owner/repo/pulls", _, _}
    assert remote_refs(context, branch) == ""
    assert Receipt.read(context.receipt)["status"] == "publish_pending"
  end

  test "publish leaves a pending receipt without pushing after the ready label is removed" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    sha = candidate_commit!(context)
    branch = "codex/symphony-not-ready"
    request_fun = publish_request(self(), sha: sha, ready: false)

    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} =
             Delivery.publish(
               context.workspace,
               context.issue,
               context.repository,
               branch,
               sha,
               context.receipt,
               delivery_opts(request_fun)
             )

    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/issues/42", _, nil}
    refute_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/pulls", _, _}
    refute_receive {:mvp_delivery_request, "POST", "/repos/owner/repo/pulls", _, _}
    assert remote_refs(context, branch) == ""
    assert Receipt.read(context.receipt)["status"] == "publish_pending"
  end

  test "publish keeps the receipt pending after the GitHub PR request fails" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    sha = candidate_commit!(context)
    branch = "codex/symphony-lost-post"
    request_fun = publish_request(self(), sha: sha, post_response: {:error, :network_lost})

    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} =
             Delivery.publish(
               context.workspace,
               context.issue,
               context.repository,
               branch,
               sha,
               context.receipt,
               delivery_opts(request_fun)
             )

    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/issues/42", _, nil}
    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/pulls", _, nil}
    assert_receive {:mvp_delivery_request, "POST", "/repos/owner/repo/pulls", %{}, _}
    assert remote_ref_sha(context, branch) == sha
    assert Receipt.read(context.receipt)["status"] == "publish_pending"
  end

  test "publish rejects a PR response with a different candidate SHA and keeps pending state" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    sha = candidate_commit!(context)
    branch = "codex/symphony-wrong-pr"
    request_fun = publish_request(self(), sha: sha, pull_sha: String.duplicate("b", 40))

    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} =
             Delivery.publish(
               context.workspace,
               context.issue,
               context.repository,
               branch,
               sha,
               context.receipt,
               delivery_opts(request_fun)
             )

    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/issues/42", _, nil}
    assert_receive {:mvp_delivery_request, "GET", "/repos/owner/repo/pulls", _, nil}
    assert_receive {:mvp_delivery_request, "POST", "/repos/owner/repo/pulls", %{}, _}
    assert remote_ref_sha(context, branch) == sha
    assert Receipt.read(context.receipt)["status"] == "publish_pending"
  end

  test "publish does not contact GitHub or push when API credentials are missing" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    prior_token = System.get_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", prior_token) end)
    System.delete_env("GITHUB_TOKEN")
    sha = candidate_commit!(context)
    branch = "codex/symphony-no-token"
    request_fun = publish_request(self(), sha: sha)
    tracker_settings = %{provider: %{"repo" => "owner/repo"}}

    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} =
             Delivery.publish(
               context.workspace,
               context.issue,
               context.repository,
               branch,
               sha,
               context.receipt,
               delivery_opts(request_fun, tracker_settings)
             )

    refute_receive {:mvp_delivery_request, _, _, _, _}
    assert remote_refs(context, branch) == ""
    assert Receipt.read(context.receipt)["status"] == "publish_pending"
  end

  test "reconcile leaves a claimed receipt unresolved without making an API request" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    assert {:error, :mvp_no_unique_matching_pr} = Delivery.reconcile(context.receipt)
    assert Receipt.read(context.receipt)["status"] == "claimed"
  end

  test "controller commands report a timeout as a failed command" do
    assert {:error, {:command_failed, status, _output}} =
             Commands.run(["sleep", "5"], System.tmp_dir!(), 1)

    assert status != 0
  end

  test "reconciles a lost publish response to the unique PR with the candidate SHA" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    branch = "codex/symphony-lost-publish"
    candidate_sha = String.duplicate("a", 40)
    Receipt.update(context.receipt, "publish_pending", delivery_fields(branch, candidate_sha))
    request_fun = reconcile_request(self(), pull(context.repository.repo, branch, candidate_sha))

    assert {:ok, "https://github.com/owner/repo/pull/42"} =
             Delivery.reconcile(
               context.receipt,
               tracker_settings: github_tracker_settings(),
               request_fun: request_fun
             )

    assert_receive {:mvp_reconcile_request, "GET", "/repos/owner/repo/pulls", params}
    assert params["head"] == "owner:#{branch}"
    assert params["state"] == "all"
    assert Receipt.read(context.receipt)["status"] == "awaiting_human"
    assert Receipt.read(context.receipt)["pull_request"] == "https://github.com/owner/repo/pull/42"
  end

  test "reconcile rejects a PR whose head SHA differs from the receipt" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    branch = "codex/symphony-wrong-sha"
    candidate_sha = String.duplicate("a", 40)
    Receipt.update(context.receipt, "publish_pending", delivery_fields(branch, candidate_sha))
    request_fun = reconcile_request(self(), pull(context.repository.repo, branch, String.duplicate("b", 40)))

    assert {:error, :mvp_no_unique_matching_pr} =
             Delivery.reconcile(
               context.receipt,
               tracker_settings: github_tracker_settings(),
               request_fun: request_fun
             )

    assert_receive {:mvp_reconcile_request, "GET", "/repos/owner/repo/pulls", _params}
    assert Receipt.read(context.receipt)["status"] == "publish_pending"
    refute Map.has_key?(Receipt.read(context.receipt), "pull_request")
  end

  defp execution_context! do
    root = Path.join(System.tmp_dir!(), "symphony-mvp-executor-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(workspace)

    Commands.git!(["init", "--bare", remote], root)
    Commands.git!(["init"], workspace)
    File.write!(Path.join(workspace, "source.txt"), "base source\n")
    Commands.git!(["add", "source.txt"], workspace)
    Commands.git!(["commit", "-m", "initial"], workspace)
    Commands.git!(["branch", "-M", "main"], workspace)
    Commands.git!(["remote", "add", "origin", remote], workspace)
    Commands.git!(["push", "--set-upstream", "origin", "main"], workspace)
    Commands.git!(["--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/main"], root)

    issue = %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Add a candidate file",
      description: "Create candidate.txt with a short note.",
      native_ref: %{"repo" => "owner/repo", "number" => 42},
      state: "open",
      labels: ["ready"],
      dispatchable: true
    }

    state_dir = Path.join(root, "state")
    {:ok, receipt} = Receipt.claim(%{state_dir: state_dir}, issue)

    %{
      root: root,
      workspace: workspace,
      repository: %{repo: "owner/repo", base: "main", url: remote},
      issue: issue,
      receipt: receipt
    }
  end

  defp add_snapshot_edge_entries!(context) do
    workspace = context.workspace
    nested = Path.join(workspace, "nested")
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "baseline.txt"), "nested baseline\n")
    File.ln_s!("source.txt", Path.join(workspace, "source-link.txt"))
    Commands.git!(["add", "nested/baseline.txt", "source-link.txt"], workspace)
    Commands.git!(["commit", "-m", "add baseline symlink and nested path"], workspace)
    Commands.git!(["push", "origin", "main"], workspace)
  end

  defp executor_opts(context, overrides) do
    Keyword.merge(
      [
        repository: fn _issue, _opts -> {:ok, context.repository} end,
        tracker_settings: github_tracker_settings()
      ],
      overrides
    )
  end

  defp agent_stub(test_pid, opts \\ []) do
    Process.put(:mvp_executor_test_agent_call, 0)

    fn workspace, prompt, issue, agent_opts ->
      call_number = Process.get(:mvp_executor_test_agent_call, 0) + 1
      Process.put(:mvp_executor_test_agent_call, call_number)
      role = if call_number == 1, do: :coder, else: :reviewer

      send(
        test_pid,
        {:mvp_agent_call, call_number, role, workspace, prompt, issue.identifier, agent_opts}
      )

      if role == :coder do
        File.write!(Path.join(workspace, "candidate.txt"), "candidate change\n")
        tamper_git!(Keyword.get(opts, :tamper), workspace)
        {:ok, %{result: :turn_completed}}
      else
        review = Keyword.get(opts, :review_result, %{"approved" => true, "summary" => "Ready for human review."})
        {:ok, %{output_text: Jason.encode!(review)}}
      end
    end
  end

  defp tamper_git!(:head, workspace) do
    Commands.git!(["add", "candidate.txt"], workspace)
    Commands.git!(["commit", "-m", "agent-created-an-unapproved-commit"], workspace)
  end

  defp tamper_git!(:metadata, workspace) do
    File.write!(Path.join(workspace, ".git/config"), "\n[agent]\nchanged = true\n", [:append])
  end

  defp tamper_git!(_tamper, _workspace), do: :ok

  defp recording_publish(test_pid) do
    fn workspace, issue, repository, branch, sha, receipt, opts ->
      send(test_pid, {:mvp_publish_call, workspace, issue.identifier, repository, branch, sha, receipt, opts})
      {:ok, "https://github.com/owner/repo/pull/42"}
    end
  end

  defp check_settings(checks), do: %{checks: checks, check_timeout_ms: 10_000}
  defp models, do: %{coder: "coder-model", reviewer: "reviewer-model"}
  defp github_tracker_settings, do: %{provider: %{"repo" => "owner/repo", "token" => "fake-token"}}

  defp candidate_commit!(context) do
    File.write!(Path.join(context.workspace, "candidate.txt"), "delivery candidate\n")
    Commands.git!(["add", "candidate.txt"], context.workspace)
    Commands.git!(["commit", "-m", "candidate"], context.workspace)
    Commands.git!(["rev-parse", "HEAD"], context.workspace)
  end

  defp delivery_opts(request_fun, tracker_settings \\ github_tracker_settings()) do
    [request_fun: request_fun, tracker_settings: tracker_settings, ready_label: "ready"]
  end

  defp publish_request(test_pid, opts) do
    fn method, path, params, body, github_settings ->
      send(test_pid, {:mvp_delivery_request, method, path, params, body})
      assert github_settings.repo == "owner/repo"

      case {method, path} do
        {"GET", "/repos/owner/repo/issues/42"} ->
          labels = ready_labels(opts)

          {:ok,
           %{
             status: 200,
             body: %{"state" => "open", "labels" => labels}
           }}

        {"GET", "/repos/owner/repo/pulls"} ->
          {:ok, %{status: 200, body: Keyword.get(opts, :existing_pulls, [])}}

        {"POST", "/repos/owner/repo/pulls"} ->
          post_response(body, opts)
      end
    end
  end

  defp post_response(body, opts) do
    case Keyword.get(opts, :post_response) do
      nil ->
        sha = Keyword.get(opts, :pull_sha, Keyword.fetch!(opts, :sha))
        pull = pull("owner/repo", body["head"], sha)
        {:ok, %{status: 201, body: Map.put(pull, "base", %{"repo" => %{"full_name" => "owner/repo"}, "ref" => body["base"]})}}

      response ->
        response
    end
  end

  defp ready_labels(opts) do
    if Keyword.get(opts, :ready, true), do: [%{"name" => "ready"}], else: []
  end

  defp remote_ref_sha(context, branch) do
    Commands.git!(["--git-dir", context.repository.url, "rev-parse", "refs/heads/#{branch}"], context.root)
  end

  defp remote_refs(context, branch) do
    Commands.git!(
      ["--git-dir", context.repository.url, "for-each-ref", "--format=%(refname:short)", "refs/heads/#{branch}"],
      context.root
    )
  end

  defp push_competing_branch!(context, branch) do
    competitor = Path.join(context.root, "competitor")

    Commands.git!(
      ["clone", context.repository.url, competitor],
      context.root
    )

    File.write!(Path.join(competitor, "competing.txt"), "remote competitor\n")
    Commands.git!(["add", "competing.txt"], competitor)
    Commands.git!(["commit", "-m", "competing branch"], competitor)
    Commands.git!(["push", "origin", "HEAD:refs/heads/#{branch}"], competitor)
    Commands.git!(["--git-dir", context.repository.url, "rev-parse", "refs/heads/#{branch}"], context.root)
  end

  defp delivery_fields(branch, sha) do
    %{"repository" => "owner/repo", "branch" => branch, "candidate_sha" => sha, "base" => "main"}
  end

  defp pull(repo, branch, sha) do
    %{
      "head" => %{"repo" => %{"full_name" => repo}, "ref" => branch, "sha" => sha},
      "base" => %{"repo" => %{"full_name" => repo}, "ref" => "main"},
      "html_url" => "https://github.com/owner/repo/pull/42"
    }
  end

  defp reconcile_request(test_pid, pull) do
    fn "GET", path, params, nil, github_settings ->
      send(test_pid, {:mvp_reconcile_request, "GET", path, params})
      assert github_settings.repo == "owner/repo"
      assert github_settings.token == "fake-token"
      {:ok, %{status: 200, body: [pull]}}
    end
  end
end

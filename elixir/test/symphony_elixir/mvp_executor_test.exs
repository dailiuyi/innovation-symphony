defmodule SymphonyElixir.Mvp.ExecutorTest do
  use SymphonyElixir.TestSupport

  alias Mix.Tasks.PrBody.Check, as: PrBodyCheck
  alias SymphonyElixir.Mvp.{Commands, Delivery, Executor, Feedback, Intake, Receipt}

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

  test "A2 A4 A5 A8 A9 A10 rejection is posted before rework and only the final checked SHA is published" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    rejected = test_review(false)
    opts = rework_opts(context, [rejected, test_review(true)])

    assert {:ok, _} = execute_rework(context, 2, opts)
    data = Receipt.read(context.receipt)
    assert data["rework_count"] == 1
    assert [first, second] = data["rounds"]
    assert first["review"] == rejected
    assert second["review"]["approved"]
    assert first["candidate_sha"] != second["candidate_sha"]
    assert data["candidate_sha"] == second["candidate_sha"]
    assert first["base_sha"] == second["base_sha"]
    assert first["base_sha"] == data["base_sha"]
    assert first["comment"]["id"] == 101
    assert first["comment"]["candidate_sha"] == first["candidate_sha"]
    assert first["comment"]["round"] == 1
    assert first["comment"]["body"] =~ "＠alice"
    refute first["comment"]["body"] =~ "@"
    assert first["comment"]["body"] =~ "&lt;/pre&gt;"

    for round <- data["rounds"] do
      assert round["models"] == %{"coder" => "coder-model", "reviewer" => "reviewer-model"}
      assert File.read!(Path.join(round["evidence"], "check-1.log")) =~ round["candidate_sha"]
      assert Jason.decode!(File.read!(Path.join(round["evidence"], "review.json"))) == round["review"]
      assert round["usage"]["coder"]["input_tokens"] == 10
      assert round["usage"]["reviewer"]["input_tokens"] == 10
      assert round["usage"]["coder"]["cost"] == nil
    end

    assert data["usage"]["input_tokens"] == %{"observed" => 40, "complete" => true}
    assert data["usage"]["output_tokens"] == %{"observed" => nil, "complete" => false}
    assert data["usage"]["cost"] == nil
    assert_receive {:rework_call, 1, :coder, _, _}
    assert_receive {:rework_call, 1, :reviewer, _, _}
    assert_receive {:comment_post, 1}
    assert_receive {:rework_call, 2, :coder, prompt, _}
    assert prompt =~ rejected["summary"]
    assert prompt =~ "not new authorization"
    assert_receive {:rework_call, 2, :reviewer, _, _}
    assert_receive {:mvp_publish_call, _, _, _, _, sha, _, _}
    assert sha == second["candidate_sha"]
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
    refute_receive {:comment_post, _}
  end

  test "A4 rework approval delivers exactly one draft PR from the final verified commit" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    opts = rework_opts(context, [test_review(false), test_review(true)])
    comment_request = opts[:request_fun]

    request = fn method, path, params, body, settings ->
      if String.ends_with?(path, "/comments") do
        comment_request.(method, path, params, body, settings)
      else
        sha = Receipt.read(context.receipt)["candidate_sha"]
        publish_request(self(), sha: sha).(method, path, params, body, settings)
      end
    end

    opts = Keyword.merge(opts, publish: &Delivery.publish/7, request_fun: request, ready_label: "ready")
    assert {:ok, "https://github.com/owner/repo/pull/42"} = execute_rework(context, 1, opts)
    data = Receipt.read(context.receipt)
    assert data["status"] == "awaiting_human"
    assert remote_ref_sha(context, data["branch"]) == List.last(data["rounds"])["candidate_sha"]
    assert_receive {:mvp_delivery_request, "POST", "/repos/owner/repo/pulls", _, body}
    assert body["draft"] == true
    assert body["head"] == data["branch"]
    refute_receive {:mvp_delivery_request, "POST", "/repos/owner/repo/pulls", _, _}
    assert {:error, :mvp_execution_already_started} = execute_rework(context, 1, opts)
  end

  test "A1 legacy malformed review remains a non-rework failure" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    opts = executor_opts(context, agent: agent_stub(self(), review_result: %{}), publish: recording_publish(self()))
    assert {:error, :mvp_review_not_approved} = execute_rework(context, 0, opts)
    refute Map.has_key?(Receipt.read(context.receipt), "rounds")
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
  end

  test "A10 model comments arriving after claim cannot replace frozen models during rework" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    settings = %{
      coder_model: "coder-model",
      reviewer_model: "reviewer-model",
      allowed_models: ["coder-model", "reviewer-model", "new-model"],
      allowed_actors: ["alice"],
      ready_label: "ready"
    }

    assert {:ok, frozen} = Intake.resolve_comments([], settings)
    opts = rework_opts(context, [test_review(false), test_review(true)])
    request = opts[:request_fun]
    agent = opts[:agent]
    new_comment = %{"id" => 2, "user" => %{"login" => "alice", "type" => "User"}, "body" => "/symphony models coder=new-model reviewer=new-model"}

    options =
      Keyword.merge(opts,
        request_fun: fn method, path, params, body, tracker ->
          Process.put(:runtime_model_comments, [new_comment])
          request.(method, path, params, body, tracker)
        end,
        agent: fn workspace, prompt, issue, agent_opts ->
          if length(Receipt.read(context.receipt)["rounds"]) == 2 do
            assert {:ok, %{coder: "new-model", reviewer: "new-model"}} =
                     Intake.resolve_comments(Process.get(:runtime_model_comments), settings)

            assert agent_opts[:model] in Map.values(frozen)
          end

          agent.(workspace, prompt, issue, agent_opts)
        end
      )

    assert {:ok, _} = execute_rework(context, 1, options)
    assert Receipt.read(context.receipt)["models"] == %{"coder" => frozen.coder, "reviewer" => frozen.reviewer}
  end

  test "A3 continuous rejection posts the final reason and exhausts exactly the configured budget" do
    for limit <- [1, 2] do
      context = execution_context!()
      on_exit(fn -> File.rm_rf(context.root) end)
      opts = rework_opts(context, List.duplicate(test_review(false), 3))
      assert {:error, :mvp_rework_exhausted} = execute_rework(context, limit, opts)
      data = Receipt.read(context.receipt)
      assert data["status"] == "blocked"
      assert data["rework_count"] == limit
      assert length(data["rounds"]) == limit + 1
      assert Enum.map(data["rounds"], & &1["comment"]["id"]) == Enum.to_list(101..(101 + limit))
      assert Enum.all?(data["rounds"], &(&1["review"]["approved"] == false))
      refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
    end
  end

  test "A6 comment failures retain intent and restart cannot resend or reset the budget" do
    for response <- [{:error, :timeout}, {:ok, %{status: 403}}, {:ok, %{status: 201, body: %{}}}] do
      context = execution_context!()
      on_exit(fn -> File.rm_rf(context.root) end)
      opts = rework_opts(context, [test_review(false)], comment_response: response)
      assert {:error, :mvp_comment_uncertain} = execute_rework(context, 2, opts)
      before = Receipt.read(context.receipt)
      assert before["status"] == "comment_pending"
      assert before["rework_count"] == 0
      assert [round] = before["rounds"]
      assert round["comment"]["id"] == nil
      assert {:error, :mvp_execution_already_started} = execute_rework(context, 2, opts)
      assert {:error, :mvp_receipt_exists} = Receipt.claim(%{state_dir: Path.dirname(context.receipt)}, context.issue)
      assert {:error, :mvp_comment_already_attempted} = Feedback.post(context.receipt, test_review(false), opts)
      assert Receipt.read(context.receipt) == before
      assert_receive {:comment_post, 1}
      refute_receive {:comment_post, _}
      refute_receive {:rework_call, 2, _, _, _}
      refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
    end
  end

  test "A6 interrupted rework persists its count before invoking coder and cannot automatically resume" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    opts = rework_opts(context, [test_review(false)], interrupt: true)
    assert catch_throw(execute_rework(context, 2, opts)) == :interrupted
    data = Receipt.read(context.receipt)
    assert data["status"] == "coding"
    assert data["rework_count"] == 1
    assert length(data["rounds"]) == 2
    assert List.last(data["rounds"])["candidate_sha"] == nil
    assert {:error, :mvp_execution_already_started} = execute_rework(context, 2, opts)
    assert Receipt.read(context.receipt) == data
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
  end

  test "A9 interruption before any second coder message retains observed totals but marks usage incomplete" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)
    opts = rework_opts(context, [test_review(false)])
    original_agent = opts[:agent]
    original_request = opts[:request_fun]
    observed = %{"input_tokens" => 20, "output_tokens" => 5, "total_tokens" => 25}

    agent = fn workspace, prompt, issue, agent_opts ->
      data = Receipt.read(context.receipt)

      if length(data["rounds"]) == 2 do
        refute agent_opts[:read_only]
        assert hd(data["rounds"])["comment"]["id"] == 101
        throw(:before_second_coder_message)
      end

      output = if agent_opts[:read_only], do: 3, else: 2
      agent_opts[:on_message].(%{usage: %{input_tokens: 10, output_tokens: output, total_tokens: 10 + output}})
      original_agent.(workspace, prompt, issue, agent_opts)
    end

    request = fn method, path, params, body, settings ->
      data = Receipt.read(context.receipt)
      assert data["usage"] == Map.new(observed, fn {key, value} -> {key, %{"observed" => value, "complete" => true}} end) |> Map.put("cost", nil)
      original_request.(method, path, params, body, settings)
    end

    opts = Keyword.merge(opts, agent: agent, request_fun: request)
    assert catch_throw(execute_rework(context, 2, opts)) == :before_second_coder_message
    data = Receipt.read(context.receipt)
    assert data["status"] == "coding"
    assert data["rework_count"] == 1
    assert [first, second] = data["rounds"]
    assert first["review"]["approved"] == false
    assert first["comment"]["id"] == 101
    assert first["usage"]["coder"] == %{"input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12, "cost" => nil}
    assert first["usage"]["reviewer"] == %{"input_tokens" => 10, "output_tokens" => 3, "total_tokens" => 13, "cost" => nil}
    unknown = %{"input_tokens" => nil, "output_tokens" => nil, "total_tokens" => nil, "cost" => nil}
    assert second["usage"] == %{"coder" => unknown, "reviewer" => unknown}
    assert second["candidate_sha"] == nil
    refute Map.has_key?(second, "review")
    assert data["usage"] == Map.new(observed, fn {key, value} -> {key, %{"observed" => value, "complete" => false}} end) |> Map.put("cost", nil)
    assert {:error, :mvp_execution_already_started} = execute_rework(context, 2, opts)
    assert Receipt.read(context.receipt) == data
    assert_receive {:rework_call, 1, :coder, _, _}
    assert_receive {:rework_call, 1, :reviewer, _, _}
    assert_receive {:comment_post, 1}
    refute_receive {:rework_call, _, _, _, _}
    refute_receive {:comment_post, _}
    refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
  end

  test "A9 initial interruption before telemetry persists unknown usage only in rework mode" do
    for limit <- [0, 1, 2] do
      context = execution_context!()
      on_exit(fn -> File.rm_rf(context.root) end)
      agent = fn _, _, _, _ -> throw(:before_first_coder_message) end
      opts = executor_opts(context, agent: agent, publish: recording_publish(self()))
      assert catch_throw(execute_rework(context, limit, opts)) == :before_first_coder_message
      data = Receipt.read(context.receipt)
      assert data["status"] == "coding"
      assert data["rework_count"] == 0

      if limit == 0 do
        refute Map.has_key?(data, "rounds")
        refute Map.has_key?(data, "usage")
      else
        assert [round] = data["rounds"]
        unknown = %{"input_tokens" => nil, "output_tokens" => nil, "total_tokens" => nil, "cost" => nil}
        assert round["usage"] == %{"coder" => unknown, "reviewer" => unknown}

        assert data["usage"] == %{
                 "input_tokens" => %{"observed" => nil, "complete" => false},
                 "output_tokens" => %{"observed" => nil, "complete" => false},
                 "total_tokens" => %{"observed" => nil, "complete" => false},
                 "cost" => nil
               }
      end

      refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
    end
  end

  test "A7 failed checks, model failures and malformed reviews never post or rework" do
    for failure <- [:check, :coder, :reviewer, :invalid] do
      context = execution_context!()
      on_exit(fn -> File.rm_rf(context.root) end)
      opts = rework_opts(context, [test_review(false)], failure: failure)
      checks = if failure == :check, do: [["false"]], else: [["true"]]
      assert {:error, _} = execute_rework(context, 2, opts, checks)
      data = Receipt.read(context.receipt)
      assert data["status"] == "blocked"
      assert data["rework_count"] == 0
      assert length(data["rounds"]) == 1
      refute_receive {:comment_post, _}
      refute_receive {:rework_call, 2, _, _, _}
      refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
    end
  end

  test "A7 rework mode still rejects changed metadata, HEAD, candidate and baseline" do
    for tamper <- [:metadata, :head, :candidate, :baseline, :review_candidate, :review_baseline, :review_metadata] do
      context = execution_context!()
      on_exit(fn -> File.rm_rf(context.root) end)
      opts = rework_opts(context, [test_review(false)], tamper: tamper)

      checks =
        case tamper do
          :candidate -> [["touch", "{workspace}/changed.txt"]]
          :baseline -> [["touch", "{baseline}/changed.txt"]]
          _ -> [["true"]]
        end

      assert {:error, _} = execute_rework(context, 2, opts, checks)
      assert Receipt.read(context.receipt)["status"] == "blocked"
      refute_receive {:comment_post, _}
      refute_receive {:mvp_publish_call, _, _, _, _, _, _, _}
    end
  end

  test "A1 executor rejects out of range settings before invoking any adapter" do
    context = execution_context!()
    on_exit(fn -> File.rm_rf(context.root) end)

    for value <- [3, -1, 1.0, "1"] do
      assert {:error, :mvp_rework_not_supported} = execute_rework(context, value, [])
    end

    assert Receipt.read(context.receipt)["status"] == "claimed"
  end

  defp execute_rework(context, limit, opts, checks \\ [["git", "rev-parse", "HEAD"]]) do
    Executor.run(context.workspace, context.issue, Map.put(check_settings(checks), :max_rework, limit), models(), context.receipt, opts)
  end

  defp test_review(approved) do
    %{
      "approved" => approved,
      "summary" => if(approved, do: "Ready", else: "@alice </pre> missing meaningful tests"),
      "criteria" => [
        %{
          "acceptance" => "A1 candidate behavior",
          "tests" => if(approved, do: ["test/candidate_test.exs: asserts output"], else: []),
          "assertion_strength" => "Assert the exact candidate output",
          "failure_sensitivity" => "Removing the output must fail this assertion",
          "adequate" => approved
        }
      ]
    }
  end

  defp rework_opts(context, reviews, options \\ []) do
    agent = fn workspace, prompt, _issue, opts ->
      data = Receipt.read(context.receipt)
      number = length(data["rounds"])
      role = if opts[:read_only], do: :reviewer, else: :coder
      assert opts[:model] == Map.fetch!(models(), role)
      assert opts[:tools] == false
      assert data["rework_count"] == number - 1

      if number > 1 do
        assert Enum.at(data["rounds"], number - 2)["comment"]["id"] == 100 + number - 1
      end

      send(self(), {:rework_call, number, role, prompt, opts})
      opts[:on_message].(%{payload: %{"params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => 10}}}}})
      if number == 2 and options[:interrupt], do: throw(:interrupted)

      cond do
        options[:failure] == role ->
          {:error, :model_failed}

        role == :coder ->
          File.write!(Path.join(workspace, "candidate.txt"), "round #{number}\n")
          tamper_git!(options[:tamper], workspace)
          {:ok, %{usage: %{input_tokens: 10}}}

        true ->
          assert prompt =~ "EVERY acceptance requirement"
          assert opts[:output_schema]["required"] == ["approved", "summary", "criteria"]
          rework_review_tamper(context, options[:tamper])
          review = rework_review(reviews, number, options[:failure])
          {:ok, %{output_text: Jason.encode!(review)}}
      end
    end

    request = fn "POST", "/repos/owner/repo/issues/42/comments", %{}, body, _settings ->
      data = Receipt.read(context.receipt)
      round = List.last(data["rounds"])
      assert data["status"] == "comment_pending"
      assert round["comment"]["body"] == body["body"]
      assert File.exists?(Path.join(round["evidence"], "review.json"))
      send(self(), {:comment_post, round["round"]})
      Keyword.get(options, :comment_response, {:ok, %{status: 201, body: %{"id" => 100 + round["round"], "body" => body["body"]}}})
    end

    executor_opts(context, agent: agent, request_fun: request, publish: recording_publish(self()))
  end

  defp rework_review(_reviews, _number, :invalid), do: %{"approved" => false}
  defp rework_review(reviews, number, _failure), do: Enum.at(reviews, number - 1)

  defp rework_review_tamper(context, :review_candidate), do: File.write!(Path.join(context.workspace, "candidate.txt"), "tampered")
  defp rework_review_tamper(context, :review_baseline), do: File.write!(context.receipt <> ".evidence/baseline/source.txt", "tampered")
  defp rework_review_tamper(context, :review_metadata), do: tamper_git!(:metadata, context.workspace)
  defp rework_review_tamper(_, _), do: :ok

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

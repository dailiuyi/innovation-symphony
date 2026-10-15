defmodule SymphonyElixir.MvpGitLabDeliveryTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Mvp.{Commands, Delivery, Feedback, Forge, Receipt}

  @repo "group/nested/luca"
  @api "https://gitlab.example:8443/api/v4"
  @project "/projects/group%2Fnested%2Fluca"
  @url "https://gitlab.example:8443/group/nested/luca/-/merge_requests/9"
  @branch "codex/gitlab-test"

  test "publishes a checked commit once to a local Git remote and verifies a Draft MR" do
    c = context!()
    opts = opts(request(c.sha))
    assert {:ok, @url} = publish(c, opts)
    assert Commands.git!(["--git-dir", c.repository.url, "rev-parse", "refs/heads/#{@branch}"], c.root) == c.sha
    assert Receipt.read(c.receipt)["status"] == "awaiting_human"
    assert_received {:api, "POST", @project <> "/merge_requests", body}
    assert body["title"] == "Draft: GL-7: Synthetic change"
    assert body["source_branch"] == @branch
    assert body["target_branch"] == "main"
    assert body["description"] =~ c.sha
    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} = publish(c, opts)
    refute_received {:api, "POST", @project <> "/merge_requests", _}
  end

  test "uncertain POST retains the receipt and read-only reconciliation adopts exactly one matching MR" do
    c = context!()
    uncertain = opts(request(c.sha, timeout: true))
    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} = publish(c, uncertain)
    assert Receipt.read(c.receipt)["status"] == "publish_pending"
    assert_received {:api, "POST", @project <> "/merge_requests", _}
    assert {:ok, @url} = reconcile(c, opts(request(c.sha, existing: [mr(c.sha)])))
    refute_received {:api, "POST", _, _}
    assert Receipt.read(c.receipt)["status"] == "awaiting_human"
  end

  test "closed, non-draft, wrong candidate, foreign project and foreign URL are never adopted" do
    for fields <- [
          %{"state" => "merged"},
          %{"draft" => false},
          %{"sha" => "wrong"},
          %{"source_project_id" => 99},
          %{"target_project_id" => 99},
          %{"web_url" => "https://other.example/group/nested/luca/-/merge_requests/9"},
          %{"source_branch" => "foreign"},
          %{"target_branch" => "other"},
          %{"iid" => 0}
        ] do
      c = context!()
      Receipt.update(c.receipt, "publish_pending", %{"candidate_sha" => c.sha, "branch" => @branch, "base" => "main"})
      wrong = opts(request(c.sha, existing: [Map.merge(mr(c.sha), fields)]))
      assert {:error, :mvp_no_unique_matching_pr} = reconcile(c, wrong)
      assert Receipt.read(c.receipt)["status"] == "publish_pending"
    end

    refute_received {:api, "POST", _, _}
  end

  test "duplicate MRs and tracker instance changes fail before any write" do
    c = context!()
    Receipt.update(c.receipt, "publish_pending", %{"candidate_sha" => c.sha, "branch" => @branch, "base" => "main"})
    assert {:error, :mvp_no_unique_matching_pr} = reconcile(c, opts(request(c.sha, existing: [mr(c.sha), mr(c.sha)])))
    tracker = put_in(tracker(), [:provider, "api_url"], "https://other.example/api/v4")
    cross_instance = fn _, _, _, _, _ -> flunk("cross-instance read") end

    assert {:error, :mvp_no_unique_matching_pr} =
             Delivery.reconcile(c.receipt, tracker_settings: tracker, request_fun: cross_instance)

    github = %{kind: "github", provider: %{}}
    assert {:error, :mvp_tracker_scope_mismatch} = Forge.receipt_scope(Receipt.read(c.receipt), tracker_settings: github)
    refute_received {:api, "POST", _, _}
  end

  test "ready revocation and existing branch stop publication" do
    for extra <- [[ready: false], [existing: [mr("other")]]] do
      c = context!()
      assert {:error, :mvp_publish_uncertain_reconcile_before_retry} = publish(c, opts(request(c.sha, extra)))
      assert Commands.git!(["--git-dir", c.repository.url, "for-each-ref", "--format=%(refname)", "refs/heads/#{@branch}"], c.root) == ""
    end

    refute_received {:api, "POST", _, _}
  end

  test "rejection notes preserve intent and reconcile without resending" do
    c = context!()
    Receipt.update(c.receipt, "reviewing", %{"rounds" => [%{"round" => 1, "candidate_sha" => c.sha}]})

    timeout = fn "POST", @project <> "/issues/7/notes", %{}, body, _ ->
      send(self(), {:note, body})
      {:error, :timeout}
    end

    assert {:error, :mvp_comment_uncertain} = Feedback.post(c.receipt, %{"approved" => false, "summary" => "fix"}, opts(timeout))
    assert_received {:note, body}
    assert {:error, :mvp_comment_already_attempted} = Feedback.post(c.receipt, %{}, opts(timeout))
    lookup = fn "GET", @project <> "/issues/7/notes", %{"page" => 1}, _, _ -> {:ok, %{status: 200, body: [Map.put(body, "id", 12)]}} end
    assert {:ok, _} = Feedback.reconcile(c.receipt, opts(lookup))
    assert Receipt.read(c.receipt)["status"] == "blocked"
    refute_received {:note, _}
  end

  test "repository scope and HTTPS credentials are tied to the configured instance" do
    c = context!()
    assert {:ok, repo} = Forge.repository(c.issue, opts(request(c.sha)))
    assert repo == %{repo: @repo, base: "main", url: "https://gitlab.example:8443/group/nested/luca.git"}
    wrong = %{c.issue | native_ref: Map.put(c.issue.native_ref, "repo", "other/luca")}
    assert {:error, :mvp_repository_lookup_failed} = Forge.repository(wrong, opts(request(c.sha)))
    assert {:error, :mvp_tracker_scope_mismatch} = Forge.pulls("other/luca", @branch, opts(request(c.sha)))
    assert {:ok, env} = Forge.git_env(opts(request(c.sha)))
    assert {"GIT_CONFIG_KEY_0", "http.https://gitlab.example:8443/.extraheader"} in env
    assert {"GIT_CONFIG_VALUE_1", "false"} in env
    missing = put_in(tracker(), [:provider, "api_key"], "$SYMPHONY_MISSING_SYNTHETIC_GITLAB_KEY")
    assert {:error, :mvp_requires_gitlab_https_token} = Forge.git_env(tracker_settings: missing)
    assert Forge.pull_url(@repo, 9, tracker_settings: missing) == ""
  end

  test "description update uses PUT and preserves returned MR identity" do
    fun = fn
      "PUT", @project <> "/merge_requests/9", %{}, %{"description" => "updated"}, _ -> {:ok, %{status: 200, body: Map.put(mr("sha"), "description", "updated")}}
      "GET", @project, %{}, nil, _ -> {:ok, %{status: 200, body: project()}}
    end

    assert {:ok, %{body: %{"body" => "updated", "number" => 9}}} = Forge.update_pull(@repo, 9, "updated", opts(fun))
  end

  test "merge request lookup failures and malformed pages are never treated as an empty queue" do
    for {response, error} <- [
          {{:ok, %{status: 500, body: %{}}}, :mvp_pull_lookup_failed},
          {{:error, :timeout}, :mvp_pull_lookup_failed},
          {{:ok, %{status: 200, body: %{"unexpected" => true}}}, :mvp_pull_lookup_failed},
          {{:ok, %{status: 200, body: [nil]}}, :mvp_pr_identity_mismatch}
        ] do
      lookup = fn
        "GET", @project, %{}, nil, _ -> {:ok, %{status: 200, body: project()}}
        _method, _path, _query, _body, _ -> response
      end

      assert {:error, ^error} = Forge.pulls(@repo, @branch, opts(lookup))
    end
  end

  test "merge request pagination stops at the page bound instead of trusting an endless queue" do
    sha = String.duplicate("a", 40)

    lookup = fn
      "GET", @project, %{}, nil, _ ->
        {:ok, %{status: 200, body: project()}}

      "GET", @project <> "/merge_requests", %{"page" => page}, nil, _ ->
        send(self(), {:mr_page, page})
        {:ok, %{status: 200, body: Enum.map(1..100, &mr(sha, page * 1000 + &1))}}
    end

    assert {:error, :mvp_pull_lookup_failed} = Forge.pulls(@repo, @branch, opts(lookup))
    assert_received {:mr_page, 1}
    assert_received {:mr_page, 100}
    refute_received {:mr_page, 101}
  end

  test "frozen issue lookup runs through the configured forge only" do
    assert {:error, :invalid_gitlab_issue_id} = Forge.fetch_issues_by_ids("not-a-number", tracker(), nil)

    request = fn "GET", @project <> "/issues/7", %{}, nil, _ -> {:ok, %{status: 200, body: gitlab_issue()}} end
    assert {:ok, [issue]} = Forge.fetch_issues_by_ids("7", tracker(), request)
    assert issue.identifier == "GL-7"
    assert issue.native_ref["repo"] == @repo

    unauthorized = fn _, _, _, _, _ -> {:error, :not_authorized} end
    assert {:error, :not_authorized} = Forge.fetch_issues_by_ids("7", tracker(), unauthorized)
  end

  test "a project that does not answer to the configured path resolves neither repository nor merge requests" do
    c = context!()

    for project_body <- [
          %{"id" => 3, "path_with_namespace" => "other/project", "default_branch" => "main"},
          %{"path_with_namespace" => @repo},
          %{"id" => 0, "path_with_namespace" => @repo}
        ] do
      fun = fn "GET", @project, %{}, nil, _ -> {:ok, %{status: 200, body: project_body}} end
      assert {:error, :mvp_repository_lookup_failed} = Forge.repository(c.issue, opts(fun))
      assert {:error, :mvp_project_lookup_failed} = Forge.pulls(@repo, @branch, opts(fun))
    end
  end

  defp publish(c, opts), do: Delivery.publish(c.workspace, c.issue, c.repository, @branch, c.sha, c.receipt, opts)
  defp reconcile(c, opts), do: Delivery.reconcile(c.receipt, opts)

  defp tracker, do: %{kind: "gitlab", provider: %{"api_url" => @api, "api_key" => "synthetic-token", "project_path" => @repo}}
  defp opts(fun), do: [tracker_settings: tracker(), request_fun: fun, ready_label: "ready"]
  defp project, do: %{"id" => 3, "path_with_namespace" => @repo, "default_branch" => "main"}

  defp gitlab_issue,
    do: %{"id" => 42, "iid" => 7, "project_id" => 3, "title" => "Synthetic change", "state" => "opened", "labels" => ["ready"], "web_url" => "https://gitlab.example:8443/group/nested/luca/-/issues/7"}

  defp mr(sha, iid \\ 9),
    do: %{
      "iid" => iid,
      "source_project_id" => 3,
      "target_project_id" => 3,
      "source_branch" => @branch,
      "target_branch" => "main",
      "sha" => sha,
      "state" => "opened",
      "draft" => true,
      "web_url" => "https://gitlab.example:8443/#{@repo}/-/merge_requests/#{iid}",
      "description" => "checked"
    }

  defp request(sha, extra \\ []) do
    fn method, path, _query, body, _ ->
      send(self(), {:api, method, path, body})

      case {method, path} do
        {"GET", @project} ->
          {:ok, %{status: 200, body: project()}}

        {"GET", @project <> "/issues/7"} ->
          {:ok, %{status: 200, body: %{"state" => "opened", "labels" => if(Keyword.get(extra, :ready, true), do: ["ready"], else: [])}}}

        {"GET", @project <> "/merge_requests"} ->
          {:ok, %{status: 200, body: Keyword.get(extra, :existing, created(sha))}}

        {"POST", @project <> "/merge_requests"} ->
          post_merge_request(sha, extra)
      end
    end
  end

  defp post_merge_request(sha, extra) do
    if Keyword.get(extra, :timeout, false) do
      {:error, :timeout}
    else
      Process.put({:created_merge_requests, sha}, [mr(sha)])
      {:ok, %{status: 201, body: mr(sha)}}
    end
  end

  defp created(sha), do: Process.get({:created_merge_requests, sha}, [])

  defp context! do
    root = Path.join(System.tmp_dir!(), "gitlab-delivery-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    Commands.git!(["init", "--bare", remote], root)
    Commands.git!(["init"], workspace)
    File.write!(Path.join(workspace, "file"), "synthetic")
    Commands.git!(["add", "file"], workspace)
    Commands.git!(["commit", "-m", "synthetic"], workspace)
    Commands.git!(["branch", "-M", "main"], workspace)
    sha = Commands.git!(["rev-parse", "HEAD"], workspace)

    issue = %Issue{
      id: "7",
      identifier: "GL-7",
      title: "Synthetic change",
      description: "Synthetic task",
      state: "opened",
      labels: ["ready"],
      native_ref: %{
        "kind" => "gitlab",
        "repo" => @repo,
        "project_path" => @repo,
        "iid" => 7,
        "api_url" => @api
      }
    }

    {:ok, receipt} = Receipt.claim(%{state_dir: Path.join(root, "state")}, issue)

    %{
      root: root,
      workspace: workspace,
      issue: issue,
      receipt: receipt,
      sha: sha,
      repository: %{repo: @repo, base: "main", url: remote}
    }
  end
end

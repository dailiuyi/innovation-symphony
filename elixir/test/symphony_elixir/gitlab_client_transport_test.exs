defmodule SymphonyElixir.GitLab.ClientTransportTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.GitLab.Client
  alias SymphonyElixir.Mvp.Preflight

  setup do
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)
    :ok
  end

  test "default GitLab preflight performs only a scoped GET and leaves runtime and files unchanged" do
    root = Path.join(System.tmp_dir!(), "gitlab-preflight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "WORKFLOW.md")

    config = %{
      "tracker" => %{
        "kind" => "gitlab",
        "provider" => %{"project_path" => "company/team/luca", "api_url" => "https://forge.test/api/v4", "api_key" => "fixture"},
        "active_states" => ["opened"],
        "terminal_states" => ["closed"],
        "required_labels" => ["ready"]
      },
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "hooks" => %{"after_create" => "exit 99", "before_run" => "exit 99"},
      "agent" => %{"max_concurrent_agents" => 1},
      "codex" => %{"command" => "exit 99"},
      "mvp" => %{
        "enabled" => true,
        "coder_model" => "coder",
        "reviewer_model" => "reviewer",
        "allowed_models" => ["coder", "reviewer"],
        "allowed_actors" => ["alice"],
        "checks" => [["false"]],
        "state_dir" => Path.join(root, "state")
      }
    }

    File.write!(path, "---\n#{Jason.encode!(config)}\n---\nFixture\n")
    previous_workflow = SymphonyElixir.Workflow.workflow_file_path()
    previous_runtime = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)
    owner = self()

    Req.default_options(
      plug: fn conn ->
        send(owner, {:preflight_request, conn.method, conn.request_path})
        body = [%{"iid" => 42, "title" => "Ready", "state" => "opened", "labels" => ["ready"]}]
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    )

    assert {:ok, %{status: "passed", issue_count: 1}} = Preflight.run(path)
    assert_received {:preflight_request, "GET", "/api/v4/projects/company%2Fteam%2Fluca/issues"}
    refute_received {:preflight_request, _, _}
    assert File.ls!(root) == ["WORKFLOW.md"]
    assert SymphonyElixir.Workflow.workflow_file_path() == previous_workflow
    assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == previous_runtime
  end

  test "custom CA keeps peer verification and writes never redirect or retry" do
    owner = self()

    Req.default_options(
      adapter: fn request ->
        send(owner, {:transport, request.options})
        {request, %Req.Response{status: 503, body: %{}}}
      end
    )

    tracker = %{provider: %{"project_path" => "company/luca", "api_url" => "https://forge.test/api/v4", "api_key" => "fixture", "ca_file" => "/etc/ssl/certs/ca-certificates.crt"}}

    assert {:ok, %{status: 503}} = Client.request("POST", "/projects/company%2Fluca/issues/42/notes", %{}, %{"body" => "fixture"}, tracker_settings: tracker)
    assert_received {:transport, options}
    assert options.retry == false
    assert options.redirect == false
    assert options.connect_options[:transport_opts][:verify] == :verify_peer
    assert is_list(options.connect_options[:transport_opts][:cacerts])
    assert is_nil(options.connect_options[:transport_opts][:cacertfile])
    assert is_tuple(options.connect_options[:transport_opts][:verify_fun])
    refute_received {:transport, _}
  end
end

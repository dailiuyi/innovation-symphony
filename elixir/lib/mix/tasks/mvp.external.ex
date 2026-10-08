defmodule Mix.Tasks.Mvp.External do
  @moduledoc "Read an external-wait receipt or resume it with bound evidence."
  use Mix.Task

  alias SymphonyElixir.{Config, Tracker, Workflow, WorkflowStore}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Mvp.Config, as: MvpConfig
  alias SymphonyElixir.Mvp.{Executor, ExternalHandoff, Intake, ModelServiceMigration, ModelServices, Recovery}

  @shortdoc "Inspect or resume one external-condition handoff"
  @receipt_statuses ~w(awaiting_external awaiting_human blocked claimed preparing coding checking reviewing recovering publish_pending comment_pending)
  @scope_keys ~w(id identifier title description)
  @metadata_paths [".git/config", ".git/info/attributes", ".git/info/exclude"]
  @record_pointer_keys ["record_path", "record_sha256"]
  @record_receipt_mirrors ~w(candidate_sha base_sha issue_scope workspace branch max_rework execution_sandbox)
  @authorization_keys ~w(id authorization runtime_version command diagnostic predecessor legacy_closures external_evidence)
  @evidence_keys ~w(acceptance path sha256)
  @max_input_bytes 32 * 1_024 * 1_024
  @max_wall_budget_extension_ms 86_400_000
  @max_recovery_extension_events 10_000
  @recovery_policy_fields [
    {"enabled", :enabled},
    {"max_rework", :max_rework},
    {"diagnose_every", :diagnose_every},
    {"stage_attempts", :stage_attempts},
    {"max_elapsed_ms", :max_elapsed_ms},
    {"max_agent_attempts", :max_agent_attempts}
  ]
  @recovery_max_elapsed_key "max_elapsed_ms"

  @impl Mix.Task
  def run(arguments), do: run(arguments, [])

  @doc false
  @spec run([String.t()], keyword()) :: :ok
  def run(["status", receipt], _opts) do
    case status(receipt) do
      {:ok, summary} -> Mix.shell().info(Jason.encode!(summary, pretty: true))
      {:error, _reason} -> Mix.raise("Cannot read a valid local receipt. No network request was made.")
    end
  end

  def run(["resume", workflow, receipt, request], opts) do
    case resume(workflow, receipt, request, opts) do
      {:ok, url} when is_binary(url) ->
        Mix.shell().info(Jason.encode!(%{"status" => "submitted_for_human_review", "pull_request" => url}, pretty: true))

      {:error, {:mvp_awaiting_external, _handoff_id}} ->
        Mix.shell().info(Jason.encode!(%{"status" => "awaiting_external", "message" => "Additional external evidence is still required."}, pretty: true))

      {:error, _reason} ->
        Mix.raise("External resume refused. Receipt retained; no command from REQUEST was executed.")
    end
  rescue
    _exception -> Mix.raise("External resume refused. Receipt retained; no command from REQUEST was executed.")
  end

  def run(_, _opts), do: Mix.raise("Usage: mix mvp.external status RECEIPT.json | mix mvp.external resume WORKFLOW.md RECEIPT.json REQUEST.json")

  @doc false
  @spec status(Path.t()) :: {:ok, map()} | {:error, term()}
  def status(receipt_path) do
    with {:ok, _absolute, raw} <- read_regular_file(receipt_path),
         {:ok, receipt} when is_map(receipt) <- Jason.decode(raw) do
      handoff = if is_map(receipt["external_handoff"]), do: receipt["external_handoff"], else: %{}

      {:ok,
       %{
         "status" => safe_status(receipt["status"]),
         "candidate_sha" => safe_sha(receipt["candidate_sha"] || handoff["candidate_sha"], 40),
         "reason" => safe_text(receipt["reason"]),
         "external_conditions" => safe_conditions(handoff["conditions"])
       }}
    else
      _ -> {:error, :invalid_receipt}
    end
  end

  @doc false
  @spec resume(Path.t(), Path.t(), Path.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def resume(workflow_path, receipt_path, request_path, opts \\ []) do
    with {:ok, workflow_file, workflow} <- load_workflow(workflow_path),
         {:ok, app_settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(app_settings),
         :ok <- runtime_valid?(app_settings, opts),
         {:ok, settings} <- execution_mvp_settings(workflow, workflow_file),
         {:ok, receipt_file, receipt_raw, receipt} <- read_json_file(receipt_path),
         {:ok, _request_file, request_raw, request} <- read_json_file(request_path),
         {:ok, authorization, expected_digest} <- validate_request(request, request_raw, receipt_raw),
         {:ok, handoff} <- immutable_handoff(receipt_file, receipt),
         :ok <- receipt_models_match(receipt, handoff),
         :ok <- frozen_checks_match(settings, handoff),
         :ok <- validate_bound_external_evidence(handoff, receipt, authorization),
         :ok <- ensure_request_runtime(opts),
         {:ok, issue} <- fetch_frozen_issue(handoff, app_settings.tracker, opts),
         :ok <- current_scope_ready(issue, handoff, settings.ready_label),
         :ok <- validate_service_binding(receipt_path, receipt, handoff, issue, settings, app_settings.tracker, opts),
         {:ok, tracker_settings} <- bound_tracker_settings(workflow_file, app_settings.tracker, opts),
         {:ok, context} <- frozen_context(receipt_file, receipt, handoff, issue, settings, tracker_settings, opts) do
      delegate_resume(context, expected_digest, authorization, opts)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_external_resume}
    end
  rescue
    _exception -> {:error, :invalid_external_resume}
  end

  defp load_workflow(path) when is_binary(path) do
    absolute = Path.expand(path)

    case Workflow.load(absolute) do
      {:ok, workflow} -> {:ok, absolute, workflow}
      {:error, _reason} -> {:error, :invalid_workflow}
    end
  end

  defp load_workflow(_path), do: {:error, :invalid_workflow}

  defp execution_mvp_settings(workflow, workflow_path) do
    case MvpConfig.execution_settings(workflow, Path.dirname(workflow_path)) do
      {:ok, settings} -> {:ok, settings}
      {:error, _reason} -> {:error, :invalid_mvp_settings}
    end
  end

  defp runtime_valid?(app_settings, opts) do
    validator = Keyword.get(opts, :runtime_validator, &SymphonyElixir.Mvp.validate_runtime/1)
    validator.(app_settings)
  end

  defp read_json_file(path) do
    with {:ok, absolute, raw} <- read_regular_file(path),
         {:ok, value} when is_map(value) <- Jason.decode(raw) do
      {:ok, absolute, raw, value}
    else
      _ -> {:error, :invalid_input_file}
    end
  end

  defp read_regular_file(path) when is_binary(path) do
    absolute = Path.expand(path)

    with {:ok, %{type: :regular, size: size}} when size <= @max_input_bytes <- File.lstat(absolute),
         {:ok, raw} <- File.read(absolute) do
      {:ok, absolute, raw}
    else
      _ -> {:error, :invalid_input_file}
    end
  end

  defp read_regular_file(_path), do: {:error, :invalid_input_file}

  defp validate_request(request, _request_raw, receipt_raw) when is_map(request) do
    expected_keys = ["receipt_sha256", "authorization"]
    digest = request["receipt_sha256"]
    authorization = request["authorization"]
    actual = digest_bytes(receipt_raw)

    with true <- Enum.sort(Map.keys(request)) == Enum.sort(expected_keys),
         true <- is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         true <- digest == actual,
         :ok <- valid_authorization(authorization) do
      {:ok, authorization, digest}
    else
      _ -> {:error, :invalid_request_binding}
    end
  end

  defp valid_authorization(authorization) when is_map(authorization) do
    required = @authorization_keys -- ["diagnostic"]

    with true <- Enum.sort(Map.keys(authorization)) in [Enum.sort(required), Enum.sort(@authorization_keys)],
         true <- valid_id?(authorization["id"]),
         true <- nonempty_string?(authorization["authorization"]),
         true <- is_binary(authorization["runtime_version"]) and Regex.match?(~r/\A[0-9a-f]{40}\z/, authorization["runtime_version"]),
         true <- valid_command?(authorization["command"]),
         true <- is_nil(authorization["diagnostic"]) or nonempty_string?(authorization["diagnostic"]),
         true <- is_nil(authorization["predecessor"]) or valid_id?(authorization["predecessor"]),
         true <- valid_legacy_closures?(authorization["legacy_closures"]),
         true <- valid_external_evidence_shape?(authorization["external_evidence"]) do
      :ok
    else
      _ -> {:error, :invalid_authorization}
    end
  end

  defp valid_authorization(_authorization), do: {:error, :invalid_authorization}

  defp valid_command?(command) when is_list(command) and command != [],
    do: Enum.all?(command, &nonempty_string?/1)

  defp valid_command?(_command), do: false

  defp valid_legacy_closures?(closures) when is_list(closures),
    do: Enum.all?(closures, &is_map/1)

  defp valid_legacy_closures?(_closures), do: false

  defp valid_external_evidence_shape?(evidence) when is_list(evidence) and evidence != [] do
    Enum.all?(evidence, fn item ->
      is_map(item) and Enum.sort(Map.keys(item)) == Enum.sort(@evidence_keys) and
        nonempty_string?(item["acceptance"]) and is_binary(item["path"]) and
        Path.type(item["path"]) == :absolute and is_binary(item["sha256"]) and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, item["sha256"])
    end)
  end

  defp valid_external_evidence_shape?(_evidence), do: false

  defp validate_bound_external_evidence(handoff, receipt, authorization) do
    case ExternalHandoff.validate_evidence(
           handoff["conditions"],
           authorization["external_evidence"],
           receipt["external_evidence_history"] || []
         ) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_external_evidence}
    end
  end

  defp delegate_resume(context, digest, authorization, opts) do
    case Keyword.fetch(opts, :resume_external) do
      {:ok, delegate} -> delegate.(context, digest, authorization)
      :error -> Executor.resume_external(context, digest, authorization)
    end
  end

  defp immutable_handoff(receipt_path, receipt) do
    pointer = receipt["external_handoff"]

    with true <- receipt["status"] == "awaiting_external",
         true <- is_map(pointer),
         id when is_binary(id) <- pointer["id"],
         true <- valid_id?(id),
         expected_path = Path.join([receipt_path <> ".evidence", "external-handoffs", id <> ".json"]),
         true <- pointer["record_path"] == expected_path,
         {:ok, %{type: :regular, size: record_size}} when record_size <= @max_input_bytes <- File.lstat(expected_path),
         {:ok, raw} <- File.read(expected_path),
         sha when is_binary(sha) <- pointer["record_sha256"],
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) and digest_bytes(raw) == sha,
         {:ok, record} when is_map(record) <- Jason.decode(raw),
         true <- Map.drop(pointer, @record_pointer_keys ++ ["provided_evidence"]) == record,
         :ok <- receipt_record_mirrors(receipt, record),
         true <- record["id"] == id and record["status"] == "pending",
         :ok <- valid_frozen_record(record) do
      {:ok, record}
    else
      _ -> {:error, :invalid_handoff_record}
    end
  end

  defp receipt_record_mirrors(receipt, record) do
    if Enum.all?(@record_receipt_mirrors, fn key ->
         not Map.has_key?(receipt, key) or receipt[key] == record[key]
       end) do
      :ok
    else
      {:error, :receipt_handoff_mismatch}
    end
  end

  defp valid_frozen_record(record) do
    with :ok <- valid_frozen_scope(record["issue_scope"], record["issue_native_ref"]),
         :ok <- valid_frozen_repository(record["repository"]),
         :ok <- valid_frozen_models(record["models"]),
         :ok <- valid_frozen_workspace(record),
         :ok <- valid_frozen_metadata(record["git_metadata"]),
         :ok <- valid_frozen_review_evidence(record) do
      :ok
    else
      _ -> {:error, :invalid_handoff_record}
    end
  end

  defp valid_frozen_scope(scope, native_ref) do
    with true <- is_map(scope) and Enum.sort(Map.keys(scope)) == Enum.sort(@scope_keys),
         true <- is_binary(scope["id"]) and scope["id"] != "",
         true <- is_binary(scope["identifier"]) and scope["identifier"] != "",
         true <- is_binary(scope["title"]),
         true <- is_nil(scope["description"]) or is_binary(scope["description"]),
         true <- is_map(native_ref) and is_binary(native_ref["repo"]) and is_integer(native_ref["number"]),
         true <- native_ref["number"] > 0 do
      :ok
    else
      _ -> {:error, :invalid_issue_scope}
    end
  end

  defp valid_frozen_repository(repository) do
    if is_map(repository) and Enum.sort(Map.keys(repository)) == Enum.sort(~w(repo base url)) and
         Enum.all?(Map.values(repository), &nonempty_string?/1),
       do: :ok,
       else: {:error, :invalid_repository}
  end

  defp valid_frozen_models(models) do
    if is_map(models) and Enum.sort(Map.keys(models)) == Enum.sort(~w(coder reviewer)) and
         nonempty_string?(models["coder"]) and nonempty_string?(models["reviewer"]),
       do: :ok,
       else: {:error, :invalid_frozen_models}
  end

  defp valid_frozen_workspace(record) do
    if valid_sha?(record["candidate_sha"]) and valid_sha?(record["base_sha"]) and
         is_binary(record["workspace"]) and Path.type(record["workspace"]) == :absolute and
         is_binary(record["branch"]) and record["branch"] != "",
       do: :ok,
       else: {:error, :invalid_frozen_workspace}
  end

  defp valid_frozen_metadata(metadata) do
    with true <- is_map(metadata),
         true <- Enum.sort(Map.keys(metadata)) == Enum.sort(@metadata_paths),
         {:ok, _restored} <- restore_git_metadata(metadata) do
      :ok
    else
      _ -> {:error, :invalid_git_metadata}
    end
  end

  defp valid_frozen_review_evidence(record) do
    if is_binary(record["baseline_sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, record["baseline_sha256"]) and
         is_list(record["checks"]) and is_list(record["conditions"]) and record["conditions"] != [],
       do: :ok,
       else: {:error, :invalid_frozen_evidence}
  end

  defp receipt_models_match(receipt, handoff) do
    if receipt["models"] == handoff["models"], do: :ok, else: {:error, :frozen_models_mismatch}
  end

  defp frozen_checks_match(settings, handoff) do
    if settings.checks == handoff["checks"], do: :ok, else: {:error, :frozen_checks_mismatch}
  end

  defp fetch_frozen_issue(handoff, tracker_settings, opts) do
    fetch_issue =
      Keyword.get(opts, :fetch_issue, fn issue_id, tracker, request_fun ->
        case request_fun do
          nil -> Client.fetch_issues_by_ids([issue_id], tracker)
          fun -> Client.fetch_issues_by_ids([issue_id], tracker, fun)
        end
      end)

    scope = handoff["issue_scope"]
    native_ref = handoff["issue_native_ref"]
    request_fun = Keyword.get(opts, :request_fun)

    with {:ok, issues} <- fetch_issue.(scope["id"], tracker_settings, request_fun),
         [%SymphonyElixir.Tracker.Issue{} = issue] <- issues,
         true <- issue.id == scope["id"],
         true <- issue.native_ref == native_ref,
         true <- is_binary(issue.state) do
      {:ok, issue}
    else
      _ -> {:error, :issue_unavailable_or_changed}
    end
  rescue
    _exception -> {:error, :issue_unavailable_or_changed}
  end

  defp current_scope_ready(issue, handoff, ready_label) do
    current_scope =
      Map.new(
        Map.take(issue, [:id, :identifier, :title, :description]),
        fn {key, value} -> {Atom.to_string(key), value} end
      )

    cond do
      issue.state != "open" -> {:error, :issue_not_open}
      current_scope != handoff["issue_scope"] -> {:error, :issue_scope_changed}
      not Intake.ready?(issue, ready_label) -> {:error, :issue_not_ready}
      true -> :ok
    end
  end

  defp validate_service_binding(receipt_path, receipt, handoff, issue, settings, tracker, opts) do
    if is_map(receipt["services"]) do
      with {:ok, services} <- ModelServiceMigration.services(receipt, handoff, receipt_path),
           true <- Enum.sort(Map.keys(services)) == ~w(coder reviewer) or {:error, :invalid_frozen_services} do
        validate_frozen_services(Map.put(handoff, "services", services), settings)
      end
    else
      # Historical receipts have no connection or capability evidence to restore.
      # Retain the old audit gate; the managed adapter refuses inference until an
      # explicit migration supplies evidence, rather than fabricating a snapshot.
      with {:ok, current} <- resolve_current_models(issue, settings, tracker, opts),
           do: current_models_match(current, handoff["models"])
    end
  end

  defp validate_frozen_services(handoff, settings) do
    Enum.reduce_while(handoff["services"], :ok, fn {role, service}, :ok ->
      result = frozen_service_options(handoff, settings, role, service)

      case result do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp frozen_service_options(handoff, settings, role, service) do
    context = %{settings: settings, services: handoff["services"]}

    if is_map(service) and service["role"] == role and service["model"] == handoff["models"][role],
      do: ModelServices.options(context, String.to_existing_atom(role)),
      else: {:error, :invalid_frozen_services}
  end

  defp resolve_current_models(issue, mvp_settings, tracker_settings, opts) do
    resolve = Keyword.get(opts, :resolve_models, &Intake.resolve_claimed/3)
    request_fun = Keyword.get(opts, :request_fun)
    intake_opts = [tracker_settings: tracker_settings] |> maybe_put(:request_fun, request_fun)

    case resolve.(issue, mvp_settings, intake_opts) do
      {:ok, %{coder: coder, reviewer: reviewer}} when is_binary(coder) and is_binary(reviewer) ->
        {:ok, %{"coder" => coder, "reviewer" => reviewer}}

      _ ->
        {:error, :current_models_unavailable}
    end
  rescue
    _exception -> {:error, :current_models_unavailable}
  end

  defp current_models_match(current, frozen) do
    if current == frozen, do: :ok, else: {:error, :current_models_changed}
  end

  defp bound_tracker_settings(workflow_path, expected, opts) do
    case Keyword.fetch(opts, :tracker_binding) do
      {:ok, binding} ->
        validate_tracker_binding(binding, expected)

      :error ->
        bind_current_workflow(workflow_path, expected)
    end
  end

  defp bind_current_workflow(_workflow_path, expected) do
    if Process.whereis(WorkflowStore) do
      Tracker.bind_agent_tools()
      |> Map.fetch!(:tracker_settings)
      |> validate_tracker_binding(expected)
    else
      {:ok, expected}
    end
  end

  defp validate_tracker_binding(%{tracker_settings: tracker_settings}, expected),
    do: validate_tracker_binding(tracker_settings, expected)

  defp validate_tracker_binding(tracker_settings, expected) when is_map(tracker_settings) do
    if tracker_settings == expected, do: {:ok, tracker_settings}, else: {:error, :tracker_binding_mismatch}
  end

  defp validate_tracker_binding(_binding, _expected), do: {:error, :tracker_binding_failed}

  defp ensure_request_runtime(opts) do
    case Keyword.get(opts, :ensure_request_runtime, fn -> Application.ensure_all_started(:req) end).() do
      {:ok, _started} -> :ok
      {:error, _reason} -> {:error, :request_runtime_unavailable}
      _ -> {:error, :request_runtime_unavailable}
    end
  end

  defp frozen_context(receipt_path, receipt, handoff, issue, settings, tracker_settings, opts) do
    record = handoff
    workspace = record["workspace"]

    with {:ok, recovery_policy} <- frozen_recovery_policy(settings, receipt_path, receipt, record["recovery_policy"]),
         true <- File.dir?(workspace),
         {:ok, baseline_digest} <- Base.decode16(record["baseline_sha256"], case: :lower),
         {:ok, metadata} <- restore_git_metadata(record["git_metadata"]),
         {:ok, models} <- frozen_models(record["models"]),
         {:ok, repository} <- frozen_repository(record["repository"]),
         {:ok, services} <- ModelServiceMigration.services(receipt, record, receipt_path) do
      evidence = receipt_path <> ".evidence"
      settings = Map.put(settings, :recovery, recovery_policy)

      context = %{
        workspace: workspace,
        issue: issue,
        settings: settings,
        models: models,
        services: services,
        receipt: receipt_path,
        opts:
          [tracker_settings: tracker_settings, ready_label: settings.ready_label]
          |> maybe_put(:request_fun, Keyword.get(opts, :request_fun)),
        repository: repository,
        branch: record["branch"],
        evidence: evidence,
        base: record["base_sha"],
        metadata: metadata,
        baseline_digest: baseline_digest,
        limit: Recovery.limit(settings)
      }

      {:ok, context}
    else
      _ -> {:error, :invalid_frozen_context}
    end
  end

  defp frozen_recovery_policy(settings, receipt_path, receipt, record_policy) do
    current_policy = json_map(settings.recovery)
    recovery = receipt["recovery"]
    receipt_policy = if is_map(recovery), do: recovery["policy"], else: nil

    with true <- valid_recovery_policy_json?(current_policy),
         true <- valid_recovery_policy_json?(record_policy),
         true <- record_policy == receipt_policy,
         true <- drop_recovery_wall_budget(record_policy) == drop_recovery_wall_budget(current_policy),
         {:ok, effective_policy} <-
           verify_recovery_extension_chain(receipt_path, recovery, current_policy, record_policy) do
      {:ok, recovery_policy_atoms(effective_policy)}
    else
      _ -> {:error, :invalid_frozen_recovery_policy}
    end
  end

  defp verify_recovery_extension_chain(receipt_path, recovery, current_policy, record_policy)
       when is_binary(receipt_path) and is_map(recovery) and is_map(current_policy) and is_map(record_policy) do
    events = recovery["events"]

    cond do
      current_policy[@recovery_max_elapsed_key] == record_policy[@recovery_max_elapsed_key] ->
        {:ok, record_policy}

      not is_list(events) or length(events) > @max_recovery_extension_events or not Enum.all?(events, &is_map/1) ->
        {:error, :invalid_recovery_extension_events}

      true ->
        events
        |> Enum.filter(&extension_event?/1)
        |> verify_recovery_extension_events(receipt_path, current_policy, record_policy)
    end
  end

  defp read_recovery_extension_audit(receipt_path, id) do
    evidence = receipt_path <> ".evidence"
    rechecks = Path.join(evidence, "operator-rechecks")
    operation = Path.join(rechecks, id)

    with :ok <- require_real_directory(evidence),
         :ok <- require_real_directory(rechecks),
         :ok <- require_real_directory(operation),
         {:ok, _audit_path, _audit_raw, audit} <- read_json_file(Path.join(operation, "authorization.json")),
         {:ok, _completion_path, _completion_raw, completion} <- read_json_file(Path.join(operation, "completion.json")) do
      {:ok, audit, completion}
    else
      _ -> {:error, :invalid_recovery_extension_audit}
    end
  end

  defp require_real_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      _ -> {:error, :invalid_recovery_extension_audit}
    end
  end

  defp verify_recovery_extension_events(events, receipt_path, current_policy, record_policy) do
    events
    |> Enum.reduce_while({:ok, current_policy, MapSet.new()}, fn event, {:ok, policy, seen_ids} ->
      case verified_extension_event(receipt_path, event, policy, seen_ids) do
        {:ok, effective, next_seen_ids} -> {:cont, {:ok, effective, next_seen_ids}}
        {:error, _reason} -> {:halt, {:error, :invalid_recovery_extension_audit}}
      end
    end)
    |> case do
      {:ok, ^record_policy, _seen_ids} -> {:ok, record_policy}
      _ -> {:error, :recovery_extension_chain_mismatch}
    end
  end

  defp verified_extension_event(receipt_path, event, policy, seen_ids) do
    with {:ok, id, extension} <- extension_identity(event, seen_ids),
         {:ok, audit, completion} <- read_recovery_extension_audit(receipt_path, id),
         effective = Map.put(policy, @recovery_max_elapsed_key, policy[@recovery_max_elapsed_key] + extension),
         true <- extension_audit_matches?(audit, completion, id, extension, policy, effective) do
      {:ok, effective, MapSet.put(seen_ids, id)}
    else
      _ -> {:error, :invalid_recovery_extension_audit}
    end
  end

  defp extension_identity(event, seen_ids) do
    id = event["operation_id"]
    extension = event["extension_ms"]

    if valid_id?(id) and not MapSet.member?(seen_ids, id) and is_integer(extension) and
         extension in 1..@max_wall_budget_extension_ms do
      {:ok, id, extension}
    else
      {:error, :invalid_recovery_extension_event}
    end
  end

  defp extension_audit_matches?(audit, completion, id, extension, original_policy, effective_policy) do
    audit["id"] == id and audit["wall_budget_extension_ms"] == extension and
      audit["original_recovery_policy"] == original_policy and
      audit["effective_recovery_policy"] == effective_policy and completion["id"] == id
  end

  defp extension_event?(%{"kind" => "operator_wall_budget_extension"}), do: true
  defp extension_event?(_event), do: false

  defp valid_recovery_policy_json?(policy) when is_map(policy) do
    Enum.sort(Map.keys(policy)) == Enum.sort(Enum.map(@recovery_policy_fields, &elem(&1, 0))) and
      is_boolean(policy["enabled"]) and
      Enum.all?(~w(max_rework diagnose_every stage_attempts max_elapsed_ms max_agent_attempts), fn key ->
        is_integer(policy[key]) and policy[key] > 0
      end)
  end

  defp valid_recovery_policy_json?(_policy), do: false

  defp drop_recovery_wall_budget(policy), do: Map.delete(policy, @recovery_max_elapsed_key)

  defp recovery_policy_atoms(policy) do
    Map.new(@recovery_policy_fields, fn {json_key, atom_key} -> {atom_key, Map.fetch!(policy, json_key)} end)
  end

  defp json_map(value) do
    value |> Jason.encode!() |> Jason.decode!()
  end

  defp frozen_models(%{"coder" => coder, "reviewer" => reviewer}) when is_binary(coder) and is_binary(reviewer),
    do: {:ok, %{coder: coder, reviewer: reviewer}}

  defp frozen_repository(%{"repo" => repo, "base" => base, "url" => url})
       when is_binary(repo) and is_binary(base) and is_binary(url),
       do: {:ok, %{repo: repo, base: base, url: url}}

  defp restore_git_metadata(metadata) when is_map(metadata) do
    Enum.reduce_while(@metadata_paths, {:ok, %{}}, fn path, {:ok, result} ->
      restore_git_metadata_entry(metadata, path, result)
    end)
  end

  defp restore_git_metadata_entry(metadata, path, result) do
    case Map.fetch(metadata, path) do
      {:ok, nil} ->
        {:cont, {:ok, Map.put(result, path, {:error, :enoent})}}

      {:ok, encoded} when is_binary(encoded) ->
        case decode_git_metadata(encoded) do
          {:ok, binary} -> {:cont, {:ok, Map.put(result, path, {:ok, binary})}}
          {:error, _reason} -> {:halt, {:error, :invalid_git_metadata}}
        end

      _ ->
        {:halt, {:error, :invalid_git_metadata}}
    end
  end

  defp decode_git_metadata(encoded) do
    with {:ok, binary} <- Base.decode64(encoded),
         true <- Base.encode64(binary) == encoded do
      {:ok, binary}
    else
      _ -> {:error, :invalid_git_metadata}
    end
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp valid_id?(value), do: is_binary(value) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}\z/, value)
  defp valid_sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)
  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp safe_status(value) when value in @receipt_statuses, do: value
  defp safe_status(_value), do: "unknown"

  defp safe_sha(value, length) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]+\z/, value) and byte_size(value) == length, do: value, else: nil
  end

  defp safe_sha(_value, _length), do: nil

  defp safe_conditions(conditions) when is_list(conditions) do
    conditions
    |> Enum.filter(&is_map/1)
    |> Enum.take(100)
    |> Enum.map(fn condition ->
      %{
        "acceptance" => safe_text(condition["acceptance"]),
        "kind" => if(condition["kind"] == "external_condition", do: "external_condition", else: nil),
        "reason" => safe_text(condition["reason"]),
        "required_evidence" => safe_text(condition["required_evidence"]),
        "handoff" => safe_text(condition["handoff"])
      }
    end)
  end

  defp safe_conditions(_conditions), do: []

  defp safe_text(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, " ")
    |> String.replace(~r/(?i)\bBearer\s+\S+/, "Bearer [redacted]")
    |> String.replace(~r/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/, "[redacted]")
    |> String.replace(~r/(?i)\b(?:github|gh|codex|openai)_?(?:token|key)\b\s*[:=]\s*("[^"]*"|'[^']*'|\S+)/, "[redacted]")
    |> String.replace(~r/(?i)\b(token|authorization|password|secret|api[_-]?key)\b\s*[:=]\s*("[^"]*"|'[^']*'|\S+)/, "\\1=[redacted]")
    |> String.slice(0, 1_000)
  end

  defp safe_text(_value), do: nil

  defp digest_bytes(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end

defmodule SymphonyElixir.Mvp.AttemptsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Mvp.{Attempts, Receipt, Recovery, Review}

  setup do
    root = Path.join(System.tmp_dir!(), "mvp-attempts-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, policy} = Recovery.settings(%{"enabled" => true})
    receipt = Path.join(root, "receipt.json")

    File.write!(
      receipt,
      Jason.encode!(%{
        "status" => "coding",
        "rounds" => [%{"evidence" => root, "usage" => %{}}],
        "recovery" => %{"policy" => policy, "started_at" => DateTime.to_iso8601(DateTime.utc_now()), "agent_attempts" => 0, "events" => []}
      })
    )

    context = %{
      workspace: root,
      receipt: receipt,
      models: %{coder: "coder", reviewer: "reviewer"},
      issue: %{},
      settings: %{recovery: policy},
      limit: 0,
      opts: []
    }

    %{context: context}
  end

  test "invalid review retries retain raw output and separate usage", %{context: context} do
    invalid = "Here is JSON: {\"approved\":true,\"summary\":\"ok\"}"
    valid = Jason.encode!(%{approved: true, summary: "confirmed"})
    owner = self()

    agent = fn _, prompt, _, opts ->
      count = Receipt.read(context.receipt)["recovery"]["agent_attempts"]
      assert opts[:read_only] == true
      assert opts[:tools] == false
      assert opts[:model] == "reviewer"
      assert opts[:output_schema] == Review.schema(0)
      assert File.exists?(Path.join(context.workspace, "agent-attempt-#{count}/prompt.txt"))

      if count == 2 do
        assert prompt =~ invalid
        assert prompt =~ ":mvp_invalid_review"
        assert prompt =~ "do not extract JSON from prose"
      end

      opts[:on_message].(%{usage: %{input_tokens: count, output_tokens: 2, total_tokens: count + 2}})
      {:ok, %{output_text: if(count == 1, do: invalid, else: valid), usage: %{total_tokens: count + 3}}}
    end

    context = %{context | opts: [agent: agent, on_message: fn message -> send(owner, {:forwarded, message}) end]}
    assert {:ok, %{output_text: ^valid}} = Attempts.run(context, :reviewer, "review", fn -> :ok end)
    data = Receipt.read(context.receipt)
    assert data["recovery"]["agent_attempts"] == 2
    assert data["usage"]["total_tokens"] == %{"observed" => 9, "complete" => true}
    assert data["usage"]["input_tokens"]["observed"] == 3
    assert data["rounds"] |> List.last() |> get_in(["usage", "reviewer_attempt_1", "total_tokens"]) == 4
    assert File.read!(Path.join(context.workspace, "agent-attempt-1/output.txt")) == invalid
    assert File.read!(Path.join(context.workspace, "agent-attempt-2/output.txt")) == valid
    assert File.read!(Path.join(context.workspace, "agent-attempt-1/messages.log")) =~ "total_tokens: 3"
    assert File.read!(Path.join(context.workspace, "agent-attempt-1/outcome.json")) =~ "mvp_invalid_review"
    assert_receive {:forwarded, _}
    assert_receive {:forwarded, _}
  end

  test "valid rejected review is final and is never sampled again", %{context: context} do
    text = Jason.encode!(%{approved: false, summary: "missing requirement"})
    context = with_agent(context, fn _, _, _, _ -> {:ok, %{output_text: text}} end)
    assert {:ok, %{output_text: ^text}} = Attempts.run(context, :reviewer, "review", fn -> :ok end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 1
  end

  test "review retries report exact linkage errors and preserve the invalid raw output", %{context: context} do
    criterion = %{
      "acceptance" => "WD-3: prevent duplicate starts",
      "tests" => [],
      "assertion_strength" => "Missing ordinary CLI assertion",
      "failure_sensitivity" => "Duplicate start could pass",
      "adequate" => false
    }

    blocker = %{"acceptance" => "WD-3, WD-7: concurrency", "kind" => "code_defect", "reason" => "Ordinary CLI bypasses the lock", "required_evidence" => "", "handoff" => "coder"}
    invalid = Jason.encode!(%{"approved" => false, "summary" => "Repair code", "criteria" => [criterion], "blockers" => [blocker]})
    valid = Jason.encode!(%{"approved" => false, "summary" => "Repair code", "criteria" => [criterion], "blockers" => [%{blocker | "acceptance" => criterion["acceptance"]}]})

    agent = fn _, prompt, _, _ ->
      count = Receipt.read(context.receipt)["recovery"]["agent_attempts"]

      if count == 2 do
        assert prompt =~ "blockers[0].acceptance"
        assert prompt =~ "unmatched_acceptance"
        assert prompt =~ "missing_blocker"
        assert prompt =~ "WD-3: prevent duplicate starts"
        assert prompt =~ "ENTIRE"
        assert prompt =~ invalid
      end

      {:ok, %{output_text: if(count == 1, do: invalid, else: valid)}}
    end

    context = %{context | limit: 20, opts: [agent: agent]}
    assert {:ok, %{output_text: ^valid}} = Attempts.run(context, :reviewer, "review", fn -> :ok end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 2
    assert File.read!(Path.join(context.workspace, "agent-attempt-1/output.txt")) == invalid
    errors = Path.join(context.workspace, "agent-attempt-1/validation-errors.json") |> File.read!() |> Jason.decode!()
    assert hd(errors)["code"] == "unmatched_acceptance"
    assert File.read!(Path.join(context.workspace, "agent-attempt-2/validation-errors.json")) == "[]"
  end

  test "transient coder retries preserve partial work and raw protocol messages", %{context: context} do
    file = Path.join(context.workspace, "partial.txt")

    context =
      with_agent(context, fn _, prompt, _, opts ->
        refute opts[:read_only]
        assert opts[:model] == "coder"
        count = Receipt.read(context.receipt)["recovery"]["agent_attempts"]

        if count == 1 do
          File.write!(file, "partial work")
          opts[:on_message].(%{partial_output: "working"})
          {:error, :turn_timeout}
        else
          assert File.read!(file) == "partial work"
          assert prompt =~ "Continue from the existing partial work"
          {:ok, %{output_text: "finished"}}
        end
      end)

    assert {:ok, _} = Attempts.run(context, :coder, "implement", fn -> :ok end)
    assert File.read!(Path.join(context.workspace, "agent-attempt-1/messages.log")) =~ "working"
    assert File.read!(Path.join(context.workspace, "agent-attempt-1/outcome.json")) =~ "turn_timeout"
  end

  test "diagnosis uses the coder model read-only and repairs malformed structured output", %{context: context} do
    valid = Jason.encode!(%{action: "stop", summary: "needs environment repair", steps: ["restore toolchain"]})

    context =
      with_agent(context, fn _, prompt, _, opts ->
        assert opts[:model] == "coder"
        assert opts[:read_only]
        assert opts[:output_schema] == Recovery.schema()

        case Receipt.read(context.receipt)["recovery"]["agent_attempts"] do
          1 ->
            {:ok, %{output_text: "not JSON"}}

          2 ->
            assert prompt =~ "mvp_invalid_diagnosis"
            {:ok, %{output_text: valid}}
        end
      end)

    assert {:ok, %{output_text: ^valid}} = Attempts.run(context, :diagnosis, "diagnose", fn -> :ok end)
  end

  for error <- [:approval_required, :input_required, :unknown_failure] do
    test "#{error} stops without another model call", %{context: context} do
      error = unquote(error)
      context = with_agent(context, fn _, _, _, _ -> {:error, error} end)
      assert {:error, ^error} = Attempts.run(context, :reviewer, "review", fn -> :ok end)
      assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 1
    end
  end

  for error <- [:response_timeout, {:port_exit, 1}, :turn_timeout] do
    test "#{inspect(error)} stops with the actual final error at the stage cap", %{context: context} do
      error = unquote(Macro.escape(error))
      context = with_agent(context, fn _, _, _, _ -> {:error, error} end)
      assert {:error, ^error} = Attempts.run(context, :coder, "implement", fn -> :ok end)
      assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 3
    end
  end

  test "stage exhaustion retains the last invalid review", %{context: context} do
    context = with_agent(context, fn _, _, _, _ -> {:ok, %{output_text: "bad"}} end)
    assert {:error, :mvp_invalid_review} = Attempts.run(context, :reviewer, "review", fn -> :ok end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 3
  end

  test "verification blocks both before invocation and after a transient failure", %{context: context} do
    assert {:error, :tampered} = Attempts.run(context, :coder, "implement", fn -> {:error, :tampered} end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 0
    flag = Path.join(context.workspace, "tampered")

    context =
      with_agent(context, fn _, _, _, _ ->
        File.write!(flag, "changed")
        {:error, :turn_timeout}
      end)

    verify = fn -> if File.exists?(flag), do: {:error, :tampered}, else: :ok end
    assert {:error, :tampered} = Attempts.run(context, :coder, "implement", verify)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 1
    assert File.read!(Path.join(context.workspace, "agent-attempt-1/outcome.json")) =~ "tampered"
  end

  test "global session cap stops before launching an excess call", %{context: context} do
    context = put_in(context.settings.recovery.max_agent_attempts, 1)
    context = with_agent(context, fn _, _, _, _ -> {:error, :response_timeout} end)
    assert {:error, :mvp_recovery_resource_exhausted} = Attempts.run(context, :coder, "implement", fn -> :ok end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 1
  end

  test "elapsed cap blocks before invocation and after a successful result", %{context: context} do
    {:ok, start, _} = DateTime.from_iso8601(Receipt.read(context.receipt)["recovery"]["started_at"])
    start_ms = DateTime.to_unix(start, :millisecond)
    expired = start_ms + context.settings.recovery.max_elapsed_ms
    context = %{context | opts: [now_ms: fn -> expired end]}
    assert {:error, :mvp_recovery_resource_exhausted} = Attempts.run(context, :coder, "implement", fn -> :ok end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 0
    completed = make_ref()

    context =
      with_agent(context, fn _, _, _, _ ->
        Process.put(completed, true)
        {:ok, %{}}
      end)

    now = fn -> if Process.get(completed), do: expired, else: start_ms end
    context = %{context | opts: Keyword.put(context.opts, :now_ms, now)}
    assert {:error, :mvp_recovery_resource_exhausted} = Attempts.run(context, :coder, "implement", fn -> :ok end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 1
    assert Process.get(completed)
  end

  test "budget exhausted after reservation preserves unknown usage without launching an agent", %{context: context} do
    {:ok, started, _} = DateTime.from_iso8601(Receipt.read(context.receipt)["recovery"]["started_at"])
    start_ms = DateTime.to_unix(started, :millisecond)
    expired = start_ms + context.settings.recovery.max_elapsed_ms
    now = fn -> if Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 0, do: start_ms, else: expired end
    context = with_agent(context, fn _, _, _, _ -> flunk("expired reservation must not launch a model") end)
    context = %{context | opts: Keyword.put(context.opts, :now_ms, now)}

    assert {:error, :mvp_recovery_resource_exhausted} = Attempts.run(context, :coder, "reserved prompt", fn -> :ok end)
    data = Receipt.read(context.receipt)
    assert data["recovery"]["agent_attempts"] == 1
    assert data["usage"]["total_tokens"] == %{"observed" => nil, "complete" => false}
    assert List.last(data["rounds"])["usage"]["coder_attempt_1"]["total_tokens"] == nil
    assert List.last(data["recovery"]["events"])["status"] == "finished"
    evidence = Path.join(context.workspace, "agent-attempt-1")
    assert File.read!(Path.join(evidence, "prompt.txt")) == "reserved prompt"
    assert File.read!(Path.join(evidence, "output.txt")) == ""
    assert File.read!(Path.join(evidence, "messages.log")) == ""
    outcome = evidence |> Path.join("outcome.json") |> File.read!() |> Jason.decode!()
    assert outcome["result"] =~ "wall_timeout"
    assert outcome["outcome"] =~ "mvp_recovery_resource_exhausted"
  end

  test "existing evidence is not overwritten or consumed as a fresh session", %{context: context} do
    evidence = Path.join(context.workspace, "agent-attempt-1")
    File.mkdir!(evidence)
    File.write!(Path.join(evidence, "output.txt"), "original")
    assert {:error, {:mvp_attempt_evidence, :eexist}} = Attempts.run(context, :coder, "implement", fn -> :ok end)
    assert File.read!(Path.join(evidence, "output.txt")) == "original"
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 0
  end

  test "remaining elapsed budget is passed to the agent and wall expiry never retries", %{context: context} do
    {:ok, started, _} = DateTime.from_iso8601(Receipt.read(context.receipt)["recovery"]["started_at"])
    elapsed = 25
    now = DateTime.to_unix(started, :millisecond) + elapsed

    context =
      with_agent(context, fn _, _, _, options ->
        assert options[:wall_timeout_ms] == context.settings.recovery.max_elapsed_ms - elapsed
        {:error, :wall_timeout}
      end)

    context = %{context | opts: Keyword.put(context.opts, :now_ms, fn -> now end)}
    assert {:error, :mvp_recovery_resource_exhausted} = Attempts.run(context, :coder, "implement", fn -> :ok end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 1
  end

  test "credited external waiting preserves only the original remaining activity budget", %{context: context} do
    recovery = Receipt.read(context.receipt)["recovery"]
    {:ok, started, _} = DateTime.from_iso8601(recovery["started_at"])
    started_ms = DateTime.to_unix(started, :millisecond)
    wait_ms = context.settings.recovery.max_elapsed_ms * 2
    elapsed_activity_ms = 25
    now = started_ms + wait_ms + elapsed_activity_ms
    :ok = Receipt.update(context.receipt, "coding", %{"recovery" => Map.put(recovery, "external_wait_ms", wait_ms)})

    context =
      with_agent(context, fn _, _, _, options ->
        assert options[:wall_timeout_ms] == context.settings.recovery.max_elapsed_ms - elapsed_activity_ms
        {:ok, %{}}
      end)

    context = %{context | opts: Keyword.put(context.opts, :now_ms, fn -> now end)}
    assert {:ok, %{}} = Attempts.run(context, :coder, "continue", fn -> :ok end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 1

    expired = started_ms + wait_ms + context.settings.recovery.max_elapsed_ms
    context = %{context | opts: Keyword.put(context.opts, :now_ms, fn -> expired end)}
    assert {:error, :mvp_recovery_resource_exhausted} = Attempts.run(context, :coder, "expired", fn -> :ok end)
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 1
  end

  defp with_agent(context, agent), do: %{context | opts: Keyword.put(context.opts, :agent, agent)}
end

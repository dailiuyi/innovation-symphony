defmodule SymphonyElixir.MvpFailureTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Mvp.{AutomaticAcceptance, Failure}

  test "trusted classifications forbid infrastructure or unknown failures from becoming code repair" do
    binding = %{"candidate_sha" => String.duplicate("a", 40), "evidence_ref" => "check.log"}

    for {result, category, action} <- [
          {{:ok, 0}, "passed", :diagnose},
          {{:ok, 10}, "code_defect", :repair_code},
          {{:ok, 124}, "environment", :retry_stage},
          {{:ok, 137}, "environment", :retry_stage},
          {{:ok, 127}, "environment", :retry_stage},
          {{:error, {:sandbox_environment_failure, 1}}, "environment", :retry_stage},
          {{:error, :sandbox_export_incomplete}, "export", :stop},
          {{:error, :sandbox_cleanup_incomplete}, "integrity", :stop},
          {{:error, :sandbox_check_exit_mismatch}, "integrity", :stop},
          {{:error, :sandbox_workspace_changed}, "integrity", :stop},
          {{:ok, 1}, "unknown", :diagnose}
        ] do
      failure = Failure.check(result, binding)
      assert failure["category"] == category
      assert Failure.action(failure) == action
      assert failure["candidate_sha"] == binding["candidate_sha"]
      assert Failure.permits_code_repair?(failure) == (category == "code_defect")
    end

    assert Failure.permits_code_repair?(%{})
    assert Failure.action(%{"category" => "budget"}) == :stop
  end

  test "automatic acceptance registers only fixed versioned probes, never text commands" do
    profile = %{"kind" => "linux", "timeout_ms" => 1000, "runner_sha256" => String.duplicate("a", 64)}
    assert AutomaticAcceptance.valid_profiles?(%{})
    assert AutomaticAcceptance.valid_profiles?(%{"Linux" => profile})

    for invalid <- [
          nil,
          [],
          %{"Linux" => Map.put(profile, "command", "echo pass")},
          %{"Linux" => Map.put(profile, "kind", "shell")},
          %{"Linux" => Map.put(profile, "timeout_ms", 0)},
          %{"Linux" => Map.put(profile, "runner_sha256", "latest")}
        ] do
      refute AutomaticAcceptance.valid_profiles?(invalid)
    end

    assert {:error, :unregistered_acceptance_probe} = AutomaticAcceptance.runner_digest(%{}, "shell")
    assert {:ok, digest} = AutomaticAcceptance.runner_digest(%{}, "gpt_coder")
    assert byte_size(digest) == 64
  end
end

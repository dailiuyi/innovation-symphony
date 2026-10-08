defmodule SymphonyElixir.Mvp.Failure do
  @moduledoc "Trusted stage outcomes; diagnostic advice cannot override a known infrastructure failure."

  @spec check(term(), map()) :: map()
  def check(result, binding) do
    {category, reason, retryable} = classify(result)
    Map.merge(binding, %{"stage" => "check", "category" => category, "reason" => reason, "retryable" => retryable})
  end

  defp classify({:ok, 0}), do: {"passed", "completed", false}
  defp classify({:ok, 10}), do: {"code_defect", "trusted_repairable_check", false}
  defp classify({:ok, status}) when status in [124, 137, 127], do: {"environment", "process_exit_#{status}", true}
  defp classify({:error, {:sandbox_environment_failure, status}}), do: {"environment", "process_exit_#{status}", true}
  defp classify({:error, :sandbox_export_incomplete}), do: {"export", "sandbox_export_incomplete", false}

  defp classify({:error, reason}) when reason in [:sandbox_cleanup_incomplete, :sandbox_check_exit_mismatch, :sandbox_workspace_changed],
    do: {"integrity", Atom.to_string(reason), false}

  defp classify(_), do: {"unknown", "unclassified_check_failure", false}

  @spec action(map()) :: :repair_code | :retry_stage | :stop | :diagnose
  def action(%{"category" => "code_defect"}), do: :repair_code
  def action(%{"category" => "environment", "retryable" => true}), do: :retry_stage
  def action(%{"category" => category}) when category in ["integrity", "export", "budget"], do: :stop
  def action(_), do: :diagnose

  @spec permits_code_repair?(map()) :: boolean()
  def permits_code_repair?(failure), do: failure["category"] in [nil, "code_defect"]
end

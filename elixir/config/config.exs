import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :test do
  # Mix starts the application before loading test_helper.exs. Redirect its
  # rotating log here so even startup/test failures cannot dirty the checkout.
  logs_root =
    Path.join(System.tmp_dir!(), "symphony-test-logs-#{System.pid()}-#{System.unique_integer([:positive])}")

  config :symphony_elixir,
    workflow_file_path: Path.expand("../test/fixtures/startup_workflow.md", __DIR__),
    log_file: Path.join(logs_root, "symphony.log")

  System.at_exit(fn _status ->
    # Release disk_log's file handles before deleting this invocation's files.
    :logger.remove_handler(:symphony_disk_log)
    File.rm_rf!(logs_root)
  end)
end

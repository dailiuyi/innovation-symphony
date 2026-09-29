---
tracker:
  kind: github
  provider:
    repo: $GITHUB_REPO
    token: $GITHUB_TOKEN
  required_labels: [ready]
  active_states: [open]
  terminal_states: [closed]
polling:
  interval_ms: 30000
workspace:
  root: /var/tmp/innovation-symphony/workspaces
hooks:
  after_create: git init
agent:
  max_concurrent_agents: 1
  max_turns: 1
codex:
  command: codex app-server
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: workspace-write
  turn_timeout_ms: 900000
  stall_timeout_ms: 1200000
mvp:
  enabled: false
  # Placeholder IDs, not availability claims. Replace before enabling.
  coder_model: YOUR_CODER_MODEL
  reviewer_model: YOUR_REVIEWER_MODEL
  allowed_models: [YOUR_CODER_MODEL, YOUR_REVIEWER_MODEL]
  allowed_actors: [YOUR_GITHUB_LOGIN]
  ready_label: ready
  # Keep state/workspaces outside the real escript directory (symlinks resolved).
  # Invalid MVP settings stop dispatch and are reported in the service log.
  state_dir: /var/tmp/innovation-symphony/state
  check_timeout_ms: 900000
  # Integer 0..2; 0 preserves V0. 1/2 enable rejection comments and bounded rework.
  # See ../docs/REVIEW_REWORK.md; interrupted/uncertain attempts never auto-resume.
  max_rework: 0
  checks:
    - [python3, "{baseline}/scripts/check_candidate.py", "{workspace}"]
    - [python3, "{baseline}/scripts/check_baseline.py", "{workspace}"]
---

GitHub MVP: the controller builds a finite coding/check/review/PR pipeline.
Work only in the supplied issue workspace. Never merge or upgrade the runner.
This template is disabled. It is not proof of repository access or model availability.
See ../docs/IMPLEMENTATION_V0.md and ../docs/OPERATIONS.md before configuring a real repository.

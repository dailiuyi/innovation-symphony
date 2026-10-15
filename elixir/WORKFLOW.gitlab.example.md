---
tracker:
  kind: gitlab
  provider:
    # Instance API root; must be an https URL ending in /api/v4.
    api_url: $GITLAB_API_URL
    # Group/subgroup/project path, for example innovation/luca.
    project_path: $GITLAB_PROJECT_PATH
    # Restricted personal access token. Never commit a literal value.
    api_key: $GITLAB_PAT
    # Omit this key entirely unless the operator installed a PEM bundle for a
    # private-CA instance; an unusable path stops MVP configuration.
    # ca_file: /etc/ssl/certs/innovation-gitlab.pem
  required_labels: [ready]
  active_states: [opened]
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
  allowed_actors: [YOUR_GITLAB_USERNAME]
  ready_label: ready
  # Keep state/workspaces outside the real escript directory (symlinks resolved).
  # Invalid MVP settings stop dispatch and are reported in the service log.
  state_dir: /var/tmp/innovation-symphony/state
  check_timeout_ms: 900000
  # Integer 0..5; 0 preserves V0. Checks and Review share this rework budget.
  # Fixed runners: exit 0 passes, exit 10 is repairable, other failures stop.
  max_rework: 0
  # Opt in only after preparing Linux isolation and trusted offline dependencies.
  # Full path/resource configuration: ../docs/CODER_EXECUTION_RULES.md
  sandbox:
    enabled: false
  checks:
    - [python3, "{baseline}/scripts/check_candidate.py", "{workspace}", --evidence-root, "{evidence}"]
    - [python3, "{baseline}/scripts/check_baseline.py", "{workspace}", "--baseline", "{baseline}", "--evidence-root", "{evidence}"]
---

GitLab MVP: the controller builds a finite coding/check/review/merge-request pipeline.
Work only in the supplied issue workspace. Never merge or upgrade the runner.
The controller pushes and reads the instance over https with the configured token,
and verifies the Draft MR by project, branch, base and candidate SHA.
This template is disabled. It is not proof of repository access, CA trust or model availability.
See ../docs/GITLAB_INTEGRATION.md and ../docs/OPERATIONS.md before configuring a real project.

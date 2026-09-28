"""Keep the controller's GitHub configuration out of project checks."""

import os


def isolated_environment() -> dict[str, str]:
    return {
        name: value
        for name, value in os.environ.items()
        if name not in {"GITHUB_REPO", "GITHUB_TOKEN", "GH_TOKEN"}
    }

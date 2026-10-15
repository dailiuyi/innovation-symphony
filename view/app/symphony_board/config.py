# -*- coding: utf-8 -*-
"""Board configuration: app/config.toml (tomllib) with app/config.json fallback.

Missing config file means defaults, which reproduce the watcher's behaviour:
watch /var/tmp/innovation-symphony-v0*, show every repo found in receipts.
"""
import json
import os
from dataclasses import dataclass, field

from .wslpull import DEFAULT_GLOB

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_TOML = os.path.join(APP_DIR, "config.toml")
CONFIG_JSON = os.path.join(APP_DIR, "config.json")


@dataclass
class RepoCfg:
    name: str
    alias: str = ""
    glob: str = ""
    enabled: bool = True

    def display(self):
        return self.alias or self.name


@dataclass
class CostCfg:
    """Token 单价（每 1M token）。价格全为 0 视为未配置，前端只展示 token 数。"""
    currency: str = "¥"
    input_per_m: float = 0.0
    cached_input_per_m: float = 0.0
    output_per_m: float = 0.0

    @property
    def enabled(self):
        return any(p > 0 for p in (self.input_per_m, self.cached_input_per_m, self.output_per_m))


@dataclass
class BoardConfig:
    title: str = "innovation-view"
    interval: int = 5
    runtime_glob: str = DEFAULT_GLOB
    port: int = 8613
    repos: list = field(default_factory=list)
    path: str = ""
    exists: bool = False
    stall_hours: float = 24.0
    cost: CostCfg = field(default_factory=CostCfg)
    transport: str = "auto"
    model_settings_url: str = ""
    model_settings_origin: str = ""

    def has_repo_entries(self):
        return bool(self.repos)

    def alias_of(self, repo):
        for entry in self.repos:
            if entry.name == repo and entry.alias:
                return entry.alias
        return repo

    def enabled_names(self):
        return {entry.name for entry in self.repos if entry.enabled}

    def globs(self):
        out = [self.runtime_glob] if self.runtime_glob else []
        for entry in self.repos:
            if entry.enabled and entry.glob and entry.glob not in out:
                out.append(entry.glob)
        return out or [DEFAULT_GLOB]

    def pending(self, snapshot):
        """Runtimes/repos discovered in WSL but not covered by config entries."""
        if not self.has_repo_entries():
            return []
        known = self.enabled_names()
        seen, rows = set(), []
        from .common import repo_raw, short_runtime
        for runtime in snapshot.get("runtimes", []):
            name = short_runtime(runtime["root"])
            for receipt in runtime.get("receipts", []):
                repo = repo_raw(receipt)
                if repo and repo not in known and (name, repo) not in seen:
                    seen.add((name, repo))
                    rows.append({"runtime": name, "repo": repo})
        return rows


def _from_dicts(data, path, exists):
    board = data.get("board") or {}
    cost_data = data.get("cost") or board.get("cost") or {}
    cost = CostCfg(
        currency=str(cost_data.get("currency") or "¥"),
        input_per_m=float(cost_data.get("input_per_m") or 0.0),
        cached_input_per_m=float(cost_data.get("cached_input_per_m") or 0.0),
        output_per_m=float(cost_data.get("output_per_m") or 0.0),
    )
    repos = []
    for item in board.get("repos") or data.get("repos") or []:
        if not isinstance(item, dict) or not str(item.get("name") or "").strip():
            continue
        repos.append(RepoCfg(
            name=str(item["name"]).strip(),
            alias=str(item.get("alias") or "").strip(),
            glob=str(item.get("glob") or item.get("runtime_glob") or "").strip(),
            enabled=item.get("enabled", True) is not False,
        ))
    from .runtime_source import resolve_transport
    transport = board.get("transport", "auto")
    resolve_transport(transport)
    stall_raw = board.get("stall_hours")
    from .model_settings import validate_management
    validate_management(board.get("model_settings_url", ""), board.get("model_settings_origin", ""))
    return BoardConfig(
        title=str(board.get("title") or "innovation-view"),
        interval=int(board.get("interval") or 5),
        runtime_glob=str(board.get("runtime_glob") or DEFAULT_GLOB),
        port=int(board.get("port") or 8613),
        repos=repos,
        path=path,
        exists=exists,
        stall_hours=24.0 if stall_raw is None else float(stall_raw),
        cost=cost,
        transport=transport,
        model_settings_url=board.get("model_settings_url", ""),
        model_settings_origin=board.get("model_settings_origin", ""),
    )


def load_config(path=None):
    toml_path = path or CONFIG_TOML
    if os.path.exists(toml_path):
        if toml_path.endswith(".json"):
            with open(toml_path, encoding="utf-8") as handle:
                return _from_dicts(json.load(handle), toml_path, True)
        try:
            import tomllib
        except ImportError:
            raise RuntimeError(f"读取 {toml_path} 需要 Python 3.11+（tomllib），或改用 config.json")
        with open(toml_path, "rb") as handle:
            return _from_dicts(tomllib.load(handle), toml_path, True)
    if path is None and os.path.exists(CONFIG_JSON):
        with open(CONFIG_JSON, encoding="utf-8") as handle:
            return _from_dicts(json.load(handle), CONFIG_JSON, True)
    return _from_dicts({}, toml_path, False)

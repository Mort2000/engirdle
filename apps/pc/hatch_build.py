from __future__ import annotations

from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    """Embed the canonical root schemas without keeping a source copy."""

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        del version
        project_root = Path(self.root)
        if self.target_name == "sdist":
            contracts_root = project_root.parents[1] / "contracts"
            destination_root = "embedded_contracts"
        elif self.target_name == "wheel":
            repository_contracts = project_root.parents[1] / "contracts"
            contracts_root = (
                repository_contracts
                if repository_contracts.is_dir()
                else project_root / "embedded_contracts"
            )
            destination_root = "engirdle_pc/contracts"
        else:
            return

        schemas = (
            ("readpack/v1/schema", "readpack/v1/schema"),
            ("catalog/v1/schema", "catalog/v1/schema"),
        )
        for source_suffix, destination_suffix in schemas:
            source = contracts_root / source_suffix
            if not source.is_dir():
                raise RuntimeError(f"canonical contract schema directory not found: {source}")
            build_data["force_include"][str(source)] = (
                f"{destination_root}/{destination_suffix}"
            )

"""Smoke tests that run without Docker or a Snakemake workflow."""
from pathlib import Path


def test_required_files_exist():
    root = Path(__file__).resolve().parent.parent
    for rel in (
        "workflow/Snakefile",
        "workflow/rules/common.smk",
        "workflow/rules/hello.smk",
        "workflow/config/test_config.yaml",
        "workflow/config/test_samples.tsv",
        "workflow/profiles/sge/config.yaml",
        "workflow/profiles/sge/status.sh",
        "workflow/pipeline.sh",
    ):
        assert (root / rel).exists(), f"missing: {rel}"


def test_test_samples_has_rows():
    root = Path(__file__).resolve().parent.parent
    rows = (root / "workflow/config/test_samples.tsv").read_text().strip().splitlines()
    assert len(rows) >= 2  # header + at least one sample


def _config_paths():
    import importlib
    import sys

    root = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(root / "workflow" / "scripts"))
    return importlib.import_module("config_paths")


def test_project_root_resolves_relative_paths():
    resolve = _config_paths().resolve
    cfg = {"project_root": "/mnt/proj/", "output_dir": "results",
           "containers": {"dir": "containers", "bind_paths": []}}
    resolve(cfg)
    assert cfg["project_root"] == "/mnt/proj"
    assert cfg["output_dir"] == "/mnt/proj/results"
    assert cfg["containers"]["dir"] == "/mnt/proj/containers"


def test_project_root_leaves_absolute_and_empty_alone():
    resolve = _config_paths().resolve
    cfg = {"project_root": "/mnt/proj", "output_dir": "/elsewhere/out",
           "containers": {"dir": ""}}
    resolve(cfg)
    assert cfg["output_dir"] == "/elsewhere/out"
    assert cfg["containers"]["dir"] == ""


def test_without_project_root_nothing_changes():
    resolve = _config_paths().resolve
    cfg = {"output_dir": "results", "containers": {"dir": ".snakemake/containers"}}
    assert resolve(cfg) == {"output_dir": "results",
                            "containers": {"dir": ".snakemake/containers"}}


def test_project_root_must_be_absolute():
    import pytest

    resolve = _config_paths().resolve
    with pytest.raises(ValueError):
        resolve({"project_root": "relative/path", "output_dir": "results"})

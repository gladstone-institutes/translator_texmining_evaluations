"""Resolve storage paths in the merged config: the ONE implementation of the
project_root rule. common.smk, resolve_sifs.py and launch.sh all go through it.

    python workflow/scripts/config_paths.py --key output_dir <config>...

Rule: `project_root` (optional; must be absolute) is the single path a cluster
config sets. `output_dir` and `containers.dir` resolve under it when they are
relative. Absolute values, empty values, and configs without project_root are
left untouched, so local configs behave exactly as before.
"""

import argparse

import yaml

BASE = "workflow/config/config.yaml"


def merge(a, b):
    """Deep-merge b into a, like snakemake's multi --configfile merge."""
    for k, v in b.items():
        a[k] = merge(a[k], v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
    return a


def load(configs):
    """config.yaml, then each layer merged in argument order."""
    cfg = yaml.safe_load(open(BASE)) or {}
    for path in configs:
        if path != BASE:
            cfg = merge(cfg, yaml.safe_load(open(path)) or {})
    return cfg


def _under(root, value):
    if isinstance(value, str) and value and not value.startswith("/"):
        return f"{root}/{value}"
    return value


def resolve(cfg):
    """Rewrite output_dir and containers.dir under project_root, in place."""
    root = cfg.get("project_root")
    if root is None:
        return cfg
    if not isinstance(root, str) or not root.startswith("/"):
        raise ValueError(f"project_root must be an absolute path, got {root!r}")
    root = root.rstrip("/") or "/"
    cfg["project_root"] = root
    cfg["output_dir"] = _under(root, cfg.get("output_dir"))
    containers = cfg.get("containers")
    if isinstance(containers, dict):
        containers["dir"] = _under(root, containers.get("dir"))
    return cfg


def get(cfg, dotted):
    """Dotted lookup: 'containers.dir' -> cfg['containers']['dir']."""
    node = cfg
    for part in dotted.split("."):
        node = (node or {}).get(part)
    return node


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("configs", nargs="*", help="config layers, merged in order")
    ap.add_argument("--key", required=True, help="dotted key to print, e.g. output_dir")
    args = ap.parse_args()
    value = get(resolve(load(args.configs)), args.key)
    print("" if value is None else value)


if __name__ == "__main__":
    main()

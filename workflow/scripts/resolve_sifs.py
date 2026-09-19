"""Print the .sif path of every image in the merged config, one per line.

    python workflow/scripts/resolve_sifs.py <config>...
    python workflow/scripts/resolve_sifs.py --images hello,mytool <config>...

Config layers merge in argument order, like multiple --configfile arguments.
--images takes the KEYS under containers.images and errors on an unknown one.
Mirrors common.smk:get_apptainer_path -- keep the two in sync. Path resolution
(project_root) comes from config_paths.py, the same code common.smk uses.
"""

import argparse

from config_paths import load, resolve


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("configs", nargs="*", help="config layers, merged in order")
    ap.add_argument("--images", default="", help="comma-separated image keys to include")
    args = ap.parse_args()

    cfg = resolve(load(args.configs))

    containers = cfg["containers"]
    images = containers["images"]
    keys = [k for k in args.images.split(",") if k] or list(images)
    unknown = [k for k in keys if k not in images]
    if unknown:
        raise SystemExit(
            f"unknown image key(s) {unknown}; configured: {sorted(images)}"
        )
    for key in keys:
        img = images[key]
        print(f'{containers["dir"]}/{img["name"]}_{img["tag"]}.sif')


if __name__ == "__main__":
    main()

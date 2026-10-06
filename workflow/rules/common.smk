# common.smk - Shared helpers for estimate_semmedb_predicate_frequencies.
#
# Main pieces:
#   - PIPELINE_VERSION: read from pyproject.toml; injected into notifications.
#   - SHADOW_MODE: 'shallow' on HPC (Apptainer), None under local Docker.
#   - USE_APPTAINER: true on HPC, drives the onstart SIF auto-pull.
#   - load_samples: generic TSV loader; required columns sample_id, description.
#   - docker_run / apptainer_run: dual-mode container entry points. Every rule
#     prepends BOTH to its shell; exactly one expands to a prefix per run mode
#     (the other is ""). Snakemake's `container:` directive is NOT used.
#   - script_path: path to a script under workflow/scripts. Every rule declares
#     its script as an input so editing the script reruns the rule.
#   - sif_to_docker_uri: reverse lookup used by the pull_container rule.
#   - _resources / _threads: translate the standard config["resources"][rule]
#     (mem_gb / runtime_min / threads) to scheduler-specific keys per profile.
#   - _resources_sized / _runtime_min_scaled: optional size-aware runtime for
#     rules whose wall time scales with a per-sample column.
#   - gpu_sampler_prefix: optional nvidia-smi utilization logger for GPU rules.
#   - PROJECT_ROOT: optional single storage path. output_dir / containers.dir
#     resolve under it (scripts/config_paths.py, shared with resolve_sifs.py
#     and launch.sh) and it is bound into both container runtimes.
#   - write_status: terminal-state file under {output_dir}/logs/status.
#   - send_notification: optional email via mail/sendmail when configured.

import os as _os
import sys
import tomllib
from pathlib import Path

import pandas as pd

with open(Path(workflow.basedir).parent / "pyproject.toml", "rb") as _f:
    PIPELINE_VERSION = tomllib.load(_f)["project"]["version"]

# Must run before anything reads output_dir / containers.dir: the Snakefile
# includes this file first, ahead of wildcard_constraints and rule all.
sys.path.insert(0, str(Path(workflow.basedir) / "scripts"))
from config_paths import resolve as _resolve_paths

_resolve_paths(config)
PROJECT_ROOT = config.get("project_root")

SHADOW_MODE = None if config.get("execution", {}).get("use_docker", False) else "shallow"
USE_APPTAINER = config.get("execution", {}).get("use_apptainer", False)
NOTIFICATION_EMAIL = config.get("notification", {}).get("email", None)

# Bind extra paths into Apptainer containers (shared filesystems outside $PWD).
# project_root is bound automatically so users list only other filesystems.
_bind_paths = list(config.get("containers", {}).get("bind_paths", []))
if PROJECT_ROOT and PROJECT_ROOT not in _bind_paths:
    _bind_paths.append(PROJECT_ROOT)
if _bind_paths:
    _extra = ",".join(_bind_paths)
    _existing = _os.environ.get("APPTAINER_BIND", "")
    _os.environ["APPTAINER_BIND"] = f"{_existing},{_extra}" if _existing else _extra
    _os.environ["SINGULARITY_BIND"] = _os.environ["APPTAINER_BIND"]


def write_status(state, body=""):
    """Write {output_dir}/logs/status/<stamp>_<state>.txt + latest.txt.

    The completion signal that works on CoreHPC, which has no mail program. Never raises.
    """
    from datetime import datetime, timezone

    try:
        status_dir = Path(config["output_dir"]) / "logs" / "status"
        status_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        text = f"{state}\n{stamp}\n\n{body}\n"
        (status_dir / f"{stamp}_{state}.txt").write_text(text)
        (status_dir / "latest.txt").write_text(text)
        print(f"Status written to {status_dir}/latest.txt", file=sys.stderr)
    except Exception as e:
        print(f"Warning: could not write status file: {e}", file=sys.stderr)


def send_notification(subject, body=""):
    """Email if configured and mail/sendmail exists. No-op on CoreHPC; see the
    notifications section of workflow/profiles/slurm/README.md."""
    if not NOTIFICATION_EMAIL:
        return
    import shutil, subprocess
    mail_cmd = shutil.which("mail") or shutil.which("sendmail")
    if not mail_cmd:
        print(
            "Note: no mail command on this host (expected on CoreHPC); "
            "status file written instead.",
            file=sys.stderr,
        )
        return
    try:
        if "sendmail" in mail_cmd:
            msg = f"Subject: {subject}\nTo: {NOTIFICATION_EMAIL}\n\n{body}"
            proc = subprocess.run(
                [mail_cmd, "-t", NOTIFICATION_EMAIL],
                input=msg, text=True, timeout=30,
            )
        else:
            proc = subprocess.run(
                [mail_cmd, "-s", subject, NOTIFICATION_EMAIL],
                input=body or " ", text=True, timeout=30,
            )
        if proc.returncode != 0:
            print(f"Warning: mail command exited with code {proc.returncode}", file=sys.stderr)
    except Exception as e:
        print(f"Warning: failed to send notification email: {e}", file=sys.stderr)


def load_samples(samples_file):
    """Load sample metadata from TSV. Requires columns: sample_id, description."""
    df = pd.read_csv(samples_file, sep="\t", comment="#")
    for required in ("sample_id", "description"):
        if required not in df.columns:
            raise ValueError(f"samples TSV is missing required column: {required!r}")
    dup = df["sample_id"][df["sample_id"].duplicated()].tolist()
    if dup:
        raise ValueError(f"Duplicate sample_id rows in samples TSV: {dup}")
    return df.set_index("sample_id", drop=False)


def get_docker_image(image_name):
    """Return the fully-qualified Docker URI for an image by config key."""
    image_config = config["containers"]["images"][image_name]
    user = image_config["user"]
    name = image_config["name"]
    tag = image_config["tag"]
    return f"docker://{user}/{name}:{tag}"


def get_apptainer_path(image_name):
    """Return the local .sif path for an image (used on HPC with Apptainer).
    Mirrored by scripts/resolve_sifs.py; containers.dir is already resolved."""
    container_dir = config["containers"]["dir"]
    image_config = config["containers"]["images"][image_name]
    name = image_config["name"]
    tag = image_config["tag"]
    return f"{container_dir}/{name}_{tag}.sif"


def sif_to_docker_uri(sif_basename):
    """Inverse of get_apptainer_path, for the pull_container rule."""
    for img in config["containers"]["images"].values():
        if f'{img["name"]}_{img["tag"]}.sif' == sif_basename:
            return f'docker://{img["user"]}/{img["name"]}:{img["tag"]}'
    raise ValueError(
        f"no configured image matches sif {sif_basename!r}; "
        f"check containers.images in your config"
    )


def script_path(name):
    """Path to a script under workflow/scripts, relative so it resolves inside
    both containers. Declare it as a rule input or script edits won't rerun."""
    return f"workflow/scripts/{name}"


def get_container_path(image_name, use_apptainer=False):
    """Route to Apptainer .sif or Docker URI depending on execution mode."""
    if use_apptainer:
        return get_apptainer_path(image_name)
    return get_docker_image(image_name)


def docker_run(image_name, extra_args=""):
    """Return a 'docker run' command prefix when running in local Docker mode.

    Returns an empty string when not in Docker mode so the same rule shell
    string works in any of the three execution modes (Docker, Apptainer, host).
    `apptainer_run` is the symmetric helper for Apptainer mode.

    By default (execution.docker_run_as_user) the container runs as the
    invoking user so outputs are not root-owned on Linux hosts, with HOME set
    to the mounted checkout: an arbitrary uid has no passwd entry in the image,
    and this mirrors apptainer_run's `--home $(pwd)`.
    """
    execution = config.get("execution", {})
    if execution.get("use_docker", False):
        image_path = get_docker_image(image_name).replace("docker://", "")
        extra = f" {extra_args}" if extra_args else ""
        if execution.get("docker_run_as_user", True):
            extra += " --user $(id -u):$(id -g) -e HOME=/workspace"
        mounts = list(config.get("execution", {}).get("docker_bind_mounts", []))
        if PROJECT_ROOT and PROJECT_ROOT not in mounts:
            mounts.append(PROJECT_ROOT)
        bind_mounts = " ".join(f"-v '{m}:{m}'" for m in mounts)
        if bind_mounts:
            bind_mounts = f" {bind_mounts}"
        # --entrypoint='' clears any image ENTRYPOINT so the rule's shell
        # command runs verbatim.
        return f"docker run --rm{extra} --entrypoint='' -v \"$(pwd)\":/workspace{bind_mounts} -w /workspace {image_path}"
    return ""


def apptainer_run(image_name, gpu=False):
    """Return an 'apptainer exec ... <sif>' prefix when in apptainer mode, else ''.

    Mirrors `docker_run`: when use_apptainer is true the rule shell starts with
    this prefix, so per-rule flags (--nv for GPU rules, custom binds) are
    explicit and config-driven. Snakemake's `container:` directive is NOT used
    in either mode -- both Docker and Apptainer go through these helpers.

    `$(pwd)` is bash-expanded at rule-execution time; mirrors what snakemake's
    `--home` injection used to do when we relied on `container:`.
    """
    if not USE_APPTAINER:
        return ""
    sif = get_apptainer_path(image_name)
    args = ['--home "$(pwd)"']
    for p in _bind_paths:
        args.append(f"--bind {p}")
    if gpu:
        args.append("--nv")
        # GPU device routing depends on the scheduler. The active profile sets
        # config["scheduler"]; we branch:
        #   - sge (DEPRECATED, unmaintained): SGE assigns one GPU per gpu.q
        #     job and only sets $SGE_GPU.
        #     Map it manually to CUDA_VISIBLE_DEVICES. The :? form makes bash
        #     exit if $SGE_GPU is unset (e.g. running outside SGE without
        #     a manual override) instead of silently grabbing device 0.
        #   - slurm: Slurm sets CUDA_VISIBLE_DEVICES itself for the job when
        #     --gres=gpu:N is requested. Apptainer inherits the caller's env
        #     (we do NOT use --cleanenv) so torch picks it up automatically.
        #     Adding our own --env would override Slurm's value, which is wrong.
        #   - other / unset: no override; rely on the caller's env. Useful for
        #     ad-hoc runs where the user has set CUDA_VISIBLE_DEVICES themselves.
        scheduler = config.get("scheduler")
        if scheduler == "sge":
            args.append(
                '--env CUDA_VISIBLE_DEVICES=${SGE_GPU:?must_be_set_for_GPU_runs_'
                'submit_on_gpu.q_or_set_manually}'
            )
    return "apptainer exec " + " ".join(args) + f" {sif}"


def gpu_sampler_prefix(out_dir, rule_name, gpu):
    """Shell prefix that background-samples nvidia-smi for the life of the rule,
    killing it on shell exit. Empty string unless `gpu` (CPU rules/hosts untouched).

    Mirrors docker_run/apptainer_run: prepended to the rule shell so the same shell
    string works in any execution mode. Writes
    {out_dir}/gpu_usage_{rule_name}_<jobid>.csv, where <jobid> is the scheduler job
    id resolved at runtime (Slurm, then SGE, then 'local'), so resubmissions never
    clobber prior samples and each file ties back to a job for sacct/log lookups.

    nvidia-smi runs on the host (placed before the container prefix); on Slurm it
    sees only the job's allocated GPU. Guarded by `command -v` so a node
    without nvidia-smi degrades to no-CSV rather than failing the rule. The EXIT
    trap preserves the rule's exit code, so the sampler can't mask a failure.
    """
    if not gpu:
        return ""
    interval = int(config.get("gpu", {}).get("sampler_interval_s", 5))
    fields = (
        "timestamp,index,utilization.gpu,utilization.memory,"
        "memory.used,memory.total"
    )
    logfile = (
        f"{out_dir}/gpu_usage_{rule_name}_"
        "${SLURM_JOB_ID:-${JOB_ID:-local}}.csv"
    )
    return (
        f"mkdir -p {out_dir}; "
        f"if command -v nvidia-smi >/dev/null 2>&1; then "
        f"nvidia-smi --query-gpu={fields} --format=csv -l {interval} -f {logfile} & "
        f"_GPU_SMI_PID=$!; trap 'kill $_GPU_SMI_PID 2>/dev/null || true' EXIT; fi; "
    )


def get_all_samples():
    """List of sample IDs."""
    return list(samples.index)


def _threads(rule_name):
    """Per-rule thread count from config['resources'][rule]."""
    return int(config["resources"][rule_name]["threads"])


def _mem_mb_for_attempt(mem_gb):
    """mem_mb callable that doubles per retry, capped at max_node_mem_gb.

    A no-op without --retries. The cap matters because an unsatisfiable request
    waits in the queue forever as (Resources) rather than failing.
    """
    base_mb = int(mem_gb * 1024)
    cap_mb = int(config.get("max_node_mem_gb", 1500) * 1024)

    def mem_mb(wildcards, attempt):
        return min(base_mb * int(attempt), cap_mb)

    return mem_mb


def _resources(rule_name, gpu=False):
    """Translate the standard resource fields to scheduler-specific keys.

    Reads ``config["resources"][rule_name]``:
      - threads:     int
      - mem_gb:      total host RAM in GB (helper handles per-slot conversion
                     for SGE; passed through as total mem_mb for Slurm)
      - scratch_gb:  optional int (SGE only; Slurm has no portable equivalent)
      - runtime_min: total runtime in minutes

    Active scheduler from ``config["scheduler"]`` (set by the profile):
      - "slurm": mem_mb (total), runtime (minutes), gres for --gres (GPU)
      - "sge":   mem_free (per-slot), scratch, h_rt (HH:MM:SS), gpu (0/1).
                 DEPRECATED -- Wynton/SGE is unmaintained; the branch is kept
                 because it works, but Slurm is the supported path.
      - else:    no scheduler keys emitted (host/local mode, etc.)
    """
    spec = config["resources"][rule_name]
    threads = int(spec["threads"])
    mem_gb = float(spec["mem_gb"])
    runtime_min = int(spec["runtime_min"])
    scratch_gb = spec.get("scratch_gb")

    scheduler = config.get("scheduler")
    out = {}
    if scheduler == "sge":
        per_slot = mem_gb / max(threads, 1)
        out["mem_free"] = f"{per_slot:g}G"
        if scratch_gb is not None:
            out["scratch"] = f"{int(scratch_gb)}G"
        h, m = divmod(runtime_min, 60)
        out["h_rt"] = f"{h:02d}:{m:02d}:00"
        out["gpu"] = 1 if gpu else 0
    elif scheduler == "slurm":
        out["mem_mb"] = _mem_mb_for_attempt(mem_gb)
        out["runtime"] = runtime_min
        # snakemake-slurm auto-maps the rule's `threads:` directive to
        # --cpus-per-task; no need to emit cpus_per_task here.
        if gpu:
            gpu_partition = config.get("gpu", {}).get("slurm_partition", "small_gpu")
            gpu_gres = config.get("gpu", {}).get("slurm_gres", "gpu:nvidia_l40s:1")
            out["slurm_partition"] = gpu_partition
            # Use the plugin's native `gres` resource, NOT slurm_extra. Recent
            # snakemake-executor-plugin-slurm versions forbid `--gres` inside
            # slurm_extra (validation.py forbidden-options list); the resulting
            # WorkflowError is raised in run_job on a submission worker thread,
            # where it is swallowed by the ThreadPoolExecutor future -- the job
            # never submits, its max_concurrent_gpu_jobs slot is never released,
            # and the scheduler hangs forever on "Waiting for running jobs". The
            # `gres` resource is rendered to `--gres=<value>` by set_gres_string.
            out["gres"] = gpu_gres
            # Custom resource counter; the Slurm profile sets a global
            # `max_concurrent_gpu_jobs` cap matching the cluster's per-user
            # GPU limit (CoreHPC small_gpu = 1 running GPU job). Snakemake
            # will only submit this many GPU jobs concurrently. Override at
            # the CLI with `--resources max_concurrent_gpu_jobs=N` if you
            # have a higher allowance.
            out["max_concurrent_gpu_jobs"] = 1
    # else: host/local mode / unknown scheduler -- let snakemake's defaults apply.
    return out


def _runtime_min_scaled(rule_name, sample, column="size"):
    """Optional size-aware runtime: runtime_base_min + runtime_per_size_min * n,
    clamped to runtime_min (set that to the partition MaxTime). Rules without
    runtime_per_size_min get the flat value. Recipe in AGENTS.md.
    """
    spec = config["resources"][rule_name]
    if "runtime_per_size_min" not in spec:
        return int(spec["runtime_min"])
    n = float(samples.loc[sample, column])
    base = int(spec.get("runtime_base_min", 0))
    slope = float(spec["runtime_per_size_min"])
    return min(int(base + slope * n), int(spec["runtime_min"]))


def _resources_sized(rule_name, gpu=False):
    """_resources() minus Slurm's `runtime`, so a rule can pass its own runtime
    callable without a duplicate-kwarg clash."""
    out = _resources(rule_name, gpu=gpu)
    out.pop("runtime", None)
    return out


# Load samples at module initialization.
samples = load_samples(config["samples"])

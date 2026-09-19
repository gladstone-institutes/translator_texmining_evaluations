# Slurm profile (UCSF CoreHPC)

Targets UCSF CoreHPC (Gladstone), **validated end-to-end** with CPU and GPU jobs.
Uses `snakemake-executor-plugin-slurm`, which handles submission, polling, and
cancellation itself (no custom `status.sh`). This file is the single home for
the driver job (below), notifications, and every CoreHPC pitfall; the user-facing
overview is in [`../../../docs/PIPELINE.md`](../../../docs/PIPELINE.md).

## Setup

```bash
uv sync   # installs snakemake-executor-plugin-slurm (a pyproject.toml dep)
```

## Running

```bash
# The small test dataset (the hello example):
uv run ./workflow/pipeline.sh dry-run-slurm   # check the job graph and config
uv run ./workflow/pipeline.sh run-slurm       # run on the cluster (needs sbatch)

# Real samples, via a per-cluster config (copy config_corehpc.yaml.example).
# Prefer ../../launch.sh for anything long; the plain command is:
snakemake --snakefile workflow/Snakefile \
    --configfile workflow/config/config_corehpc.yaml \
    --profile workflow/profiles/slurm --dry-run     # drop --dry-run to run live
```

The Slurm account/partition defaults (`hpc_core` / `cpu`) live in this
directory's `config.yaml`. Change them for other Slurm sites.

## Resources

Per-rule resources are **not** set here; they live in `config["resources"]`
(`workflow/config/config.yaml`) in standard units (`threads` / `mem_gb` /
`runtime_min`), and `common.smk:_resources()` translates them to Slurm keys when
the workflow is parsed:

| SGE | Slurm |
|---|---|
| `mem_free` (per-slot) | `mem_mb` (total) |
| `scratch` | (not used; Slurm manages tmp via `$TMPDIR`) |
| `h_rt` (HH:MM:SS) | `runtime` (minutes) |
| `-pe smp {threads}` | `cpus_per_task` (auto-mapped from the rule's `threads:`) |
| `-q gpu.q -l gpu_mem=...` | `--partition=<gpu> --gres=<gres>` |

Use this profile's commented `set-resources:` block only for on-cluster tuning
that must differ from the config defaults.

## GPU routing

A rule requests a GPU by passing `gpu=True` to `apptainer_run()` **and**
`_resources()` (see the example in `workflow/rules/hello.smk`). When it does,
`_resources()` adds, for Slurm:

- `slurm_partition`, switched from the default `cpu` to the GPU partition
- `gres`, rendered to `--gres=gpu:<model>:<count>`
- `max_concurrent_gpu_jobs: 1`, counted against this profile's global cap

Both partition and gres come from the config `gpu:` block (defaults target
CoreHPC L40s nodes):

```yaml
gpu:
  slurm_partition: "small_gpu"
  slurm_gres: "gpu:nvidia_l40s:1"
```

Things this profile gets right (each cost real debugging on CoreHPC):

- **`gres`, not `slurm_extra`.** Recent plugin versions forbid `--gres` inside
  `slurm_extra`; using it makes the job silently fail to submit and **deadlocks**
  the scheduler (the `max_concurrent_gpu_jobs` slot never releases). We emit the
  plugin's native `gres` resource instead.
- **`scheduler: greedy`.** The default ILP scheduler stalls at "Selecting jobs
  to execute..." when the custom `max_concurrent_gpu_jobs` resource is present.
- **`max_concurrent_gpu_jobs=1`** matches CoreHPC's per-user GPU limit; raise it
  with `--resources max_concurrent_gpu_jobs=N` if you have a higher allowance.
- **`--nv` and GPU visibility.** `apptainer_run(gpu=True)` adds `--nv`. Slurm sets
  `CUDA_VISIBLE_DEVICES` itself, and apptainer inherits the caller's environment
  (no `--cleanenv`), so torch picks it up automatically. We do **not** inject a
  `--env` override (unlike the SGE path, which maps `$SGE_GPU`).
- **Bind `/mnt/scratch`.** GPU jobs need it for tempfiles, the matplotlib font
  cache, and pyarrow spill (set in `containers.bind_paths`). It is *shared*
  scratch, the same filesystem on login and compute nodes. Node-local space is
  `/tmp` inside a job: Slurm mounts `/mnt/lscratch` there for the job's
  lifetime, Apptainer binds `/tmp` by default, and it is gone when the job
  ends. Use `$TMPDIR` for per-job temp files and `/mnt/scratch` for anything
  another job or the login node must see.

GPU utilization can be logged per job with `gpu_sampler_prefix()` (writes
`gpu_usage_<rule>_<jobid>.csv`); see the commented example in `hello.smk`.

## Long runs: submit snakemake itself as a driver job

**Do not run a multi-hour snakemake from a CoreHPC login shell.** The login node
sets `KillUserProcesses=yes` with `Linger=no`, so systemd-logind ends every
process you own when the SSH session drops, tmux included. `launch.sh` instead
submits snakemake as its own Slurm job, called the driver because it submits
the step jobs:

```bash
./workflow/launch.sh all check     # dry-run locally, submit nothing
./workflow/launch.sh all           # download images, then submit the driver
```

`workflow/launch.sh` writes an sbatch script, submits it, and returns. The
driver submits the step jobs with `sbatch` from inside its own job, which
CoreHPC allows. A *scope* is a named way of running the pipeline: which rules,
which images, and the time limit. Edit the `scope_setup` table in `launch.sh`
to add one per way you actually run the pipeline.

Cancel a driver **gracefully** so snakemake cleans up instead of leaving a stale
lock and incomplete outputs:

```bash
scancel --signal=TERM <jobid>     # then wait; SIGKILL only if it hangs
# after a hard kill:
uv run snakemake --snakefile workflow/Snakefile --configfile <cfg> --unlock
```

## Cluster pitfalls beyond GPU

Each of these cost real debugging time on CoreHPC:

- **A job over the partition time limit waits forever, it does not fail.** A job
  asking for more time than the partition allows is accepted and then sits in
  the queue (`PD`) with reason `(PartitionTimeLimit)`, indistinguishable from an
  ordinary queue wait. Check the limit and cap your requests:
  `scontrol show partition cpu | tr ' ' '\n' | grep -i maxtime` (CoreHPC `cpu`
  is `7-00:00:00`). Memory behaves the same way: a request larger than any node
  waits as `(Resources)`, hence `max_node_mem_gb` in `config.yaml`.
- **Compute nodes have no outbound internet.** Download `.sif` files ahead of
  time on the login node (`./workflow/launch.sh <scope> prepull`, or
  `uv run ./workflow/pipeline.sh prepull <config>`) and set
  `containers.auto_pull: false` in the cluster config. Anything else that
  fetches at runtime (an R annotation hub, a model download) needs the same
  treatment: fetch to a cache on the login node and read the cache in the rule.
- **Caches must not live in `$HOME`.** CoreHPC home has a small quota, and
  `apptainer pull` fills it with image data, after which `uv run` dies with
  `Failed to initialize cache ... Disk quota exceeded (os error 122)` before
  snakemake even starts. `launch.sh` puts `UV_CACHE_DIR` and
  `APPTAINER_CACHEDIR` under `<project_root>/.cache`, and `APPTAINER_TMPDIR` on
  `/mnt/scratch/user/$USER`. The two want opposite filesystems: TMPDIR is
  throwaway build space where pull speed is set, and the caches are persistent.
- **`--rerun-triggers mtime` is worth setting for read-only scopes**, so an
  edited script or a touched config does not invalidate finished expensive
  outputs. But it only affects *change* detection, by file modification time: it
  will not stop Snakemake from rebuilding a **missing** intermediate, and it does
  not clear a `Forced execution` flag left behind by a killed job. That is what
  the `guard_dag` check in `launch.sh` is for: dry-run a cheap scope and refuse
  to submit if the job graph (Snakemake's DAG) grew beyond it.
- **`--configfile` takes any number of values**, so any flag or target after it
  is swallowed. Put extra flags *before* `--configfile`, and prefer limiting a
  run with `--until <rule>` over trailing target paths (with
  `--resources max_concurrent_gpu_jobs=1` active, trailing targets are dropped
  as "unrecognized arguments" and `--` is not honoured).
- **Submit a driver via a written job-script file, not piped into `sbatch`.**
  The piped route has reached snakemake with a stray empty argument that the
  identical interactive command never had. `launch.sh` writes the script and
  prints the exact command before running.
- **`max_rss` in a `benchmark:` file sums the process tree**, so a rule that
  forks (R `future`/`mclapply`, python multiprocessing) reports well above its
  true peak. Treat it as an upper bound when calibrating.

## Notifications (no `mail` on CoreHPC)

`common.smk:send_notification()` shells out to `mail` / `sendmail`. **No CoreHPC
node has either**, and compute nodes have no outbound internet to reach a mail
relay. With the driver job, snakemake itself runs on a compute node. So the
config's `notification.email` alone will never deliver anything there. Three
things that do work:

**1. Let the Slurm controller send the mail.** `slurmctld` runs on the
controller, which has a mail program set up by the admins, so mail requested
with `--mail-type` is delivered even though your job could not have sent it
itself. `launch.sh` does this automatically for the driver job, using
`notification.email` from the config:

```bash
./workflow/launch.sh all                       # --mail-type=END,FAIL --mail-user=<config email>
NOTIFY_EMAIL=me@example.org ./workflow/launch.sh all
MAIL_TYPE=NONE ./workflow/launch.sh all        # opt out
```

The driver's mail reports snakemake's final state, which is the one you want:
it arrives when the whole run ends, not per step job. Confirm your site has it set
up:

```bash
scontrol show config | grep -i mailprog        # expect a real binary, not (null)
sbatch --mail-type=END --mail-user=you@example.org --wrap 'sleep 5'   # then check inbox/spam
```

For a single long rule you can also add
`slurm_extra="'--mail-type=FAIL --mail-user=you@example.org'"` to its
`resources:`. Don't do it pipeline-wide: one mail per job gets loud fast.

**2. The status file, which always works.** Every run writes
`{output_dir}/logs/status/latest.txt` (plus a timestamped copy) from `onsuccess`
/ `onerror`, holding `SUCCESS` or `FAILED`, a UTC timestamp, and the same body
the email would have carried. No mail program, no network, no scheduler
involved:

```bash
cat  $OUT/logs/status/latest.txt
ls -t $OUT/logs/status/ | head        # history across runs
```

**3. Poll from somewhere with internet.** For a push notification (Slack,
ntfy, a phone), poll the status file over SSH from a machine with network
access, such as your laptop or a login node. Don't put an
HTTPS call inside a rule: compute nodes cannot make it, and the failure lands in
the middle of your pipeline.

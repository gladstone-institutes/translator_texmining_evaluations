#!/bin/bash
# Submit snakemake itself as a Slurm job, the driver (it submits the step jobs).
# CoreHPC login nodes end your processes when SSH drops, so snakemake has to run
# on a compute node. Rationale and cluster pitfalls: workflow/profiles/slurm/README.md.
#
# Usage (from the repo root on a login node):
#   ./workflow/launch.sh <scope>            # download images, then submit driver
#   ./workflow/launch.sh <scope> check      # dry-run locally, submit nothing
#   ./workflow/launch.sh <scope> prepull    # fetch images only, submit nothing
#   DRIVER_TIME=2-00:00:00 ./workflow/launch.sh all
#
# Images are downloaded here on the login node (compute nodes have no internet).
# Completion mail is requested from the Slurm controller, and every run writes
# {output_dir}/logs/status/latest.txt.
#
# Cancel gracefully with `scancel --signal=TERM <jobid>`; after a hard kill,
# clear the lock with `snakemake ... --unlock` before relaunching.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

CONFIG="workflow/config/config_corehpc.yaml"
PROFILE="workflow/profiles/slurm"

# ---------------------------------------------------------------------------
# Scopes: a scope is a named way of running this pipeline (which rules, which
# images, how long). One entry per way you actually run it.
#
#   SCOPE_CONFIGS  extra --configfile files, merged after $CONFIG
#   SCOPE_UNTIL    --until rule names (empty = default target). Names every final
#                  rule you want; the run stops at a named rule, so an in-scope
#                  upstream rule goes in SCOPE_ALLOW instead.
#   SCOPE_ALLOW    extra rule names guard_dag tolerates
#   SCOPE_IMAGES   image keys to pre-pull (empty = none)
#   SCOPE_FLAGS    extra snakemake flags; placed BEFORE --configfile, which
#                  takes any number of values and would swallow them
#   SCOPE_TIME     default driver time limit; must be <= the partition MaxTime or
#                  the job waits in the queue forever as (PartitionTimeLimit)
#   SCOPE_GUARD    1 = read-only scope: dry-run first, refuse to submit if the
#                  job graph grew beyond SCOPE_UNTIL + SCOPE_ALLOW
# ---------------------------------------------------------------------------
scope_setup() {
  case "$1" in
    all)
      # Not checked: building everything IS the scope. Run `check` first.
      SCOPE_CONFIGS=()
      SCOPE_UNTIL=()
      SCOPE_ALLOW=()
      SCOPE_IMAGES=(hello)
      SCOPE_FLAGS=()
      SCOPE_TIME="7-00:00:00"
      SCOPE_GUARD=0
      SCOPE_DESC="the whole pipeline (rule all)"
      ;;
    # A cheap leaf rule over finished output wants SCOPE_GUARD=1 and mtime:
    #
    # plots)
    #   SCOPE_CONFIGS=()
    #   SCOPE_UNTIL=(plot_summary)
    #   SCOPE_ALLOW=()
    #   SCOPE_IMAGES=(mytool)
    #   SCOPE_FLAGS=(--rerun-triggers mtime)
    #   SCOPE_TIME="04:00:00"
    #   SCOPE_GUARD=1
    #   SCOPE_DESC="re-plot from finished results"
    #   ;;
    *)
      echo "Error: unknown scope '$1'." >&2
      usage
      exit 1
      ;;
  esac
}

usage() {
  cat >&2 <<'EOF'
Usage: ./workflow/launch.sh <scope> [check|prepull]

Scopes (a named way of running the pipeline: which rules, images, time limit):
  all      the whole pipeline (rule all)
           (add your own in scope_setup() -- see the commented example)

Subcommands:
  (none)   download images, then submit snakemake as a Slurm job (the driver)
  check    dry-run locally, submit nothing
  prepull  fetch images only, submit nothing

Env overrides: ACCOUNT, PARTITION, DRIVER_TIME, DRIVER_MEM,
               CACHE_ROOT (uv + apptainer caches; default <project_root>/.cache),
               SCRATCH_TMP (apptainer build temp; defaults to
               /mnt/scratch/user/$USER, which is what makes pulls fast),
               NOTIFY_EMAIL (defaults to notification.email in the config),
               MAIL_TYPE (default END,FAIL; NONE disables the driver's mail)
EOF
}

SCOPE="${1:-}"
ACTION="${2:-run}"
if [[ -z "$SCOPE" ]]; then
  usage
  exit 1
fi
scope_setup "$SCOPE"

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: $CONFIG not found." >&2
  echo "       cp ${CONFIG}.example $CONFIG   # then edit the paths" >&2
  exit 1
fi

# Overridable knobs. Keep in sync with workflow/profiles/slurm/config.yaml.
ACCOUNT="${ACCOUNT:-hpc_core}"
PARTITION="${PARTITION:-cpu}"
DRIVER_TIME="${DRIVER_TIME:-$SCOPE_TIME}"  # must outlast the whole run
DRIVER_MEM="${DRIVER_MEM:-4G}"             # orchestrator only polls; stays light

require() { command -v "$1" &>/dev/null || { echo "Error: $1 not found." >&2; exit 1; }; }

# Caches must not live in $HOME: the quota fills with image data and uv then
# dies with "Failed to initialize cache ... Disk quota exceeded". Parsed with
# sed, not uv, because uv is exactly what breaks in that state.
if [[ -z "${CACHE_ROOT:-}" ]]; then
  _root="$(sed -n 's/^project_root:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG")"
  if [[ -n "$_root" && "$_root" == /* ]]; then
    CACHE_ROOT="${_root%/}/.cache"
  else
    # No project_root: fall back to the parent of an absolute output_dir.
    _out_dir="$(sed -n 's/^output_dir:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG")"
    # Absolute, or a failed parse ("" -> dirname ".") puts caches in the checkout.
    if [[ -z "$_out_dir" || "$_out_dir" != /* ]]; then
      echo "Error: $CONFIG sets neither an absolute project_root nor an absolute output_dir." >&2
      echo "       Set project_root in the config, or CACHE_ROOT=/path/on/shared/fs." >&2
      exit 1
    fi
    CACHE_ROOT="$(dirname "$_out_dir")/.cache"
  fi
fi
export UV_CACHE_DIR="${UV_CACHE_DIR:-$CACHE_ROOT/uv}"
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$CACHE_ROOT/apptainer}"

# TMPDIR wants the opposite filesystem from the caches: `apptainer pull`
# assembles the .sif here, so scratch is much faster than the shared project fs.
SCRATCH_TMP="${SCRATCH_TMP:-/mnt/scratch/user/$USER}"
if [[ -z "${APPTAINER_TMPDIR:-}" ]]; then
  if mkdir -p "$SCRATCH_TMP/apptainer" 2>/dev/null; then
    APPTAINER_TMPDIR="$SCRATCH_TMP/apptainer"
  else
    APPTAINER_TMPDIR="$CACHE_ROOT/apptainer/tmp"
    echo "Note: $SCRATCH_TMP unavailable; APPTAINER_TMPDIR falls back to" >&2
    echo "      $APPTAINER_TMPDIR, which makes image pulls noticeably slower." >&2
  fi
fi
export APPTAINER_TMPDIR
mkdir -p "$UV_CACHE_DIR" "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

require uv

# Merge order. The ${arr[@]+"${arr[@]}"} form is required under `set -u` on
# bash 3.2 (macOS), which treats an empty array's [@] as unbound.
CONFIGS=("$CONFIG" ${SCOPE_CONFIGS[@]+"${SCOPE_CONFIGS[@]}"})

# Download this scope's .sif files here (login node) via the pull_container
# rule. Safe to rerun (existing files are skipped); limited to this scope so an
# unrelated image's missing tag can't block.
prepull_images() {
  [[ -n "${SCOPE_IMAGES[*]:-}" ]] || { echo "Scope '$SCOPE' declares no images to pre-pull."; return 0; }
  require apptainer
  local targets=() line images
  images="$(IFS=,; echo "${SCOPE_IMAGES[*]:-}")"
  while IFS= read -r line; do
    [[ -n "$line" ]] && targets+=("$line")
  done < <(uv run python workflow/scripts/resolve_sifs.py --images "$images" "${CONFIGS[@]}")
  # Emptiness test on [*] rather than a length test on [@]: bash's array-length
  # syntax opens with the same two characters as a Jinja comment, so it cannot
  # appear in a cookiecutter template (this file was generated from one).
  [[ -n "${targets[*]:-}" ]] || { echo "No images to pre-pull for scope '$SCOPE'."; return 0; }
  uv run snakemake --snakefile workflow/Snakefile --configfile "${CONFIGS[@]}" \
    --cores 1 "${targets[@]}"
}

# Rule names a dry-run would execute. Parses "Job stats"; snakemake logs to stderr.
dag_rules() {
  local out
  if ! out="$(uv run snakemake --snakefile workflow/Snakefile \
      ${SCOPE_FLAGS[@]+"${SCOPE_FLAGS[@]}"} \
      --configfile "${CONFIGS[@]}" --profile "$PROFILE" --dry-run \
      ${SCOPE_UNTIL[@]+--until "${SCOPE_UNTIL[@]}"} 2>&1)"; then
    echo "$out" >&2
    echo "Error: dry-run failed; refusing to submit." >&2
    exit 1
  fi
  awk '
    /^Job stats:/                       { inblock = 1; next }
    inblock && /^job[[:space:]]+count$/ { next }
    inblock && /^-+[[:space:]]+-+$/     { next }
    inblock && /^total[[:space:]]/      { inblock = 0; next }
    inblock && NF == 0                  { inblock = 0; next }
    inblock                             { print $1 }
  ' <<<"$out" | sort -u
}

# Refuse to submit a read-only scope whose job graph grew beyond its own rules: that
# means broken upstream state, and the expensive case looks exactly like the
# cheap one until you read the job table. Not skippable by a flag, on purpose.
guard_dag() {
  [[ "$SCOPE_GUARD" == "1" ]] || return 0
  local expected=(${SCOPE_UNTIL[@]+"${SCOPE_UNTIL[@]}"} ${SCOPE_ALLOW[@]+"${SCOPE_ALLOW[@]}"})
  echo "Checking the DAG for scope '$SCOPE' (expecting only: ${expected[*]}) ..."
  local rules unexpected
  rules="$(dag_rules)"
  if [[ -z "$rules" ]]; then
    echo "Nothing to do: this scope's outputs are already up to date."
    exit 0
  fi
  unexpected="$(comm -23 <(printf '%s\n' "$rules") \
                         <(printf '%s\n' "${expected[@]}" | sort -u))"
  if [[ -n "$unexpected" ]]; then
    {
      echo "Error: refusing to submit scope '$SCOPE'. The DAG would also run:"
      sed 's/^/    /' <<<"$unexpected"
      echo ""
      echo "'$SCOPE' is read-only: it should only run ${expected[*]} over"
      echo "already-finished upstream output. Extra rules mean either the"
      echo "upstream has never been built, or its state is broken (missing"
      echo "intermediates, or a forced flag left behind by a killed job)."
      echo ""
      echo "Inspect with:  ./workflow/launch.sh $SCOPE check"
    } >&2
    exit 1
  fi
  echo "DAG is clean: $(wc -l <<<"$rules") rule(s), all expected."
}

# Resolved output_dir (project_root applied) so the driver log lands beside
# the results. Merges every config file, like snakemake will.
OUT=$(uv run python workflow/scripts/config_paths.py --key output_dir "${CONFIGS[@]}")

# Sent by slurmctld, not the job, so no mail program is needed on the node.
NOTIFY_EMAIL="${NOTIFY_EMAIL:-$(uv run python -c "import yaml;print((yaml.safe_load(open('$CONFIG')).get('notification') or {}).get('email') or '')")}"
MAIL_TYPE="${MAIL_TYPE:-END,FAIL}"
MAIL_ARGS=()
if [[ -n "$NOTIFY_EMAIL" && "$MAIL_TYPE" != "NONE" ]]; then
  MAIL_ARGS=(--mail-type="$MAIL_TYPE" --mail-user="$NOTIFY_EMAIL")
fi

case "$ACTION" in
  check)
    echo "Dry-run (local): $SCOPE -- $SCOPE_DESC"
    uv run snakemake --snakefile workflow/Snakefile \
      ${SCOPE_FLAGS[@]+"${SCOPE_FLAGS[@]}"} \
      --configfile "${CONFIGS[@]}" --profile "$PROFILE" --dry-run --printshellcmds \
      ${SCOPE_UNTIL[@]+--until "${SCOPE_UNTIL[@]}"}
    exit 0
    ;;
  prepull)
    prepull_images
    exit 0
    ;;
  run) ;;
  *)
    echo "Error: unknown subcommand '$ACTION'." >&2
    usage
    exit 1
    ;;
esac

require sbatch

# Read-only scopes check the job graph before anything is submitted or pulled, so a
# broken upstream fails here in seconds rather than as a queued multi-day job.
guard_dag
prepull_images

STAMP=$(date +%Y%m%d_%H%M%S)
DRIVERDIR="$OUT/logs/driver"
mkdir -p "$DRIVERDIR"
JOBSCRIPT="$DRIVERDIR/${SCOPE}_${STAMP}.sbatch"
LOG="$DRIVERDIR/${SCOPE}_${STAMP}_%j.log"

# Written to a file, not piped into sbatch, and the exact command is printed:
# the piped route once reached snakemake with a stray empty argument.
cat > "$JOBSCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
cd "$PROJECT_DIR"
echo "driver \$SLURM_JOB_ID on \$(hostname), started \$(date)"
echo "scope: $SCOPE ($SCOPE_DESC)"

# Re-exported (not via --export=ALL) so submitted step jobs inherit them.
export UV_CACHE_DIR="$UV_CACHE_DIR"
export APPTAINER_CACHEDIR="$APPTAINER_CACHEDIR"
export APPTAINER_TMPDIR="$APPTAINER_TMPDIR"
mkdir -p "\$UV_CACHE_DIR" "\$APPTAINER_CACHEDIR" "\$APPTAINER_TMPDIR"

SMK=(uv run snakemake --snakefile workflow/Snakefile ${SCOPE_FLAGS[*]:-} --configfile ${CONFIGS[*]} --profile "$PROFILE")

echo "snakemake command:"
printf '  <%s>\n' "\${SMK[@]}" ${SCOPE_UNTIL[*]:+--until ${SCOPE_UNTIL[*]}}

# Clear any stale lock from a previously killed driver, then run.
"\${SMK[@]}" --unlock
"\${SMK[@]}" ${SCOPE_UNTIL[*]:+--until ${SCOPE_UNTIL[*]}}

echo "driver finished \$(date)"
EOF

JOBID=$(sbatch --parsable \
  --job-name="estimate-semmedb-predicate-frequencies_${SCOPE}" \
  --account="$ACCOUNT" \
  --partition="$PARTITION" \
  --time="$DRIVER_TIME" \
  --mem="$DRIVER_MEM" \
  --cpus-per-task=1 \
  --chdir="$PROJECT_DIR" \
  --output="$LOG" \
  ${MAIL_ARGS[@]+"${MAIL_ARGS[@]}"} \
  "$JOBSCRIPT")

RESOLVED_LOG="$DRIVERDIR/${SCOPE}_${STAMP}_${JOBID}.log"
echo "Submitted driver job $JOBID"
echo "  scope:   $SCOPE -- $SCOPE_DESC"
echo "  driver:  ${DRIVER_TIME} time limit, ${DRIVER_MEM}, 1 cpu, partition $PARTITION"
echo "  script:  $JOBSCRIPT"
echo "  log:     $RESOLVED_LOG"
if [[ -n "${MAIL_ARGS[*]:-}" ]]; then
  echo "  mail:    $MAIL_TYPE -> $NOTIFY_EMAIL (sent by slurmctld)"
else
  echo "  mail:    off; watch $OUT/logs/status/latest.txt"
fi
echo ""
echo "Watch:"
echo "  squeue --me"
echo "  tail -f $RESOLVED_LOG"
echo ""
echo "If it shows PD (PartitionTimeLimit), DRIVER_TIME exceeds the partition MaxTime."
echo "Stop it gracefully with:  scancel --signal=TERM $JOBID"

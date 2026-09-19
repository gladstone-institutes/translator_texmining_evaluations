#!/bin/bash
# Command-line helper for running estimate_semmedb_predicate_frequencies: dry-run, run,
# build images, download images, lint.
#
# Requires snakemake on $PATH. Recommended: prefix with `uv run` so the
# project's .venv is used without a separate `source .venv/bin/activate`:
#
#   uv sync                                      # once, after a fresh clone
#   uv run ./workflow/pipeline.sh dry-run
#
# Usage:
#   ./workflow/pipeline.sh [command] [extra snakemake args...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_CONFIG="workflow/config/test_config.yaml"
LOCAL_PROFILE="workflow/profiles/local"
APPTAINER_CONFIG="workflow/config/test_config_apptainer.yaml"
APPTAINER_DEV_PROFILE="workflow/profiles/apptainer-dev"
SGE_PROFILE="workflow/profiles/sge"
SLURM_CONFIG="workflow/config/test_config_apptainer_slurm.yaml"
SLURM_PROFILE="workflow/profiles/slurm"
CONTAINERS_DIR="workflow/containers"

cd "$PROJECT_DIR"

sm() {
    snakemake --snakefile workflow/Snakefile "$@"
}

banner() {
    echo "  snakemake $(snakemake --version)"
    echo "  config:  $1"
    echo "  profile: $2"
    echo ""
}

# Wynton / SGE is unmaintained. The commands still work; they just say so once.
deprecated_sge() {
    echo "WARNING: Wynton / SGE support is DEPRECATED and unmaintained." >&2
    echo "         CoreHPC Slurm (dry-run-slurm / run-slurm, workflow/launch.sh) is" >&2
    echo "         the supported cluster path. This still runs, but gets no updates." >&2
    echo "" >&2
}

require() {
    command -v "$1" &>/dev/null && return
    echo "Error: $1 not found." >&2
    [[ $# -ge 2 ]] && echo "$2" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./workflow/pipeline.sh [command] [extra snakemake args...]

Commands:
  dry-run              Snakemake dry-run (default)
  run                  Execute the pipeline (local Docker)
  run-apptainer        Execute the pipeline (local Apptainer)
  dry-run-slurm        Dry-run with Slurm (CoreHPC) cluster profile
  run-slurm            Execute the pipeline (Slurm / CoreHPC cluster)
  dry-run-sge          Dry-run with SGE cluster profile      [DEPRECATED]
  run-sge              Execute the pipeline (SGE cluster)    [DEPRECATED]
  prepull [cfg...]     Download every configured image as a .sif on THIS host
                          (run it on a login node: cluster compute nodes have no
                          outbound internet). Defaults to the Apptainer test
                          configs; pass config paths for a real cluster run.
  build [image] [flags] Build every Dockerfile under workflow/containers/
                          (optionally only <image>); flags forward to each
                          build.sh: --push, --no-cache, --yes (overwrite an
                          existing tag without prompting; required when
                          stdin is not a terminal, e.g. from a coding agent).
  dag                  Draw the job graph (DAG) as a PNG
  lint                 Lint Snakemake files
  pytest               Run Python unit tests (tests/)
  list-samples         List configured samples
  clean                Remove test output directory

Extra arguments are forwarded to snakemake.
Example: ./workflow/pipeline.sh run --forceall
EOF
}

cmd="${1:-dry-run}"
shift || true

case "$cmd" in
    dry-run|run|run-apptainer|dry-run-sge|run-sge|dry-run-slurm|run-slurm|dag|lint|list-samples|prepull)
        require snakemake "Run 'uv sync && source .venv/bin/activate' first."
        ;;
esac

case "$cmd" in
    dry-run)
        echo "Running Snakemake dry-run with test config..."
        sm --configfile "$TEST_CONFIG" --dry-run --printshellcmds "$@"
        ;;

    run)
        echo "Running pipeline with test config..."
        banner "$TEST_CONFIG" "$LOCAL_PROFILE"
        sm --configfile "$TEST_CONFIG" --profile "$LOCAL_PROFILE" "$@"
        ;;

    run-apptainer)
        require apptainer
        echo "Running pipeline with Apptainer containers..."
        banner "$TEST_CONFIG + $APPTAINER_CONFIG" "$APPTAINER_DEV_PROFILE"
        sm --configfile "$TEST_CONFIG" "$APPTAINER_CONFIG" \
            --profile "$APPTAINER_DEV_PROFILE" "$@"
        ;;

    dry-run-sge)
        deprecated_sge
        echo "Dry-run with SGE profile (validates DAG + cluster config)..."
        sm --configfile "$TEST_CONFIG" "$APPTAINER_CONFIG" \
            --profile "$SGE_PROFILE" --dry-run --printshellcmds "$@"
        ;;

    run-sge)
        deprecated_sge
        require qsub "Must run on an SGE cluster."
        echo "Running pipeline on SGE cluster..."
        banner "$TEST_CONFIG + $APPTAINER_CONFIG" "$SGE_PROFILE"
        # Log directories are created per-rule by the profile's submit-cmd.
        mkdir -p logs
        sm --configfile "$TEST_CONFIG" "$APPTAINER_CONFIG" \
            --profile "$SGE_PROFILE" "$@"
        ;;

    dry-run-slurm)
        echo "Dry-run with Slurm profile (validates DAG + cluster config)..."
        sm --configfile "$TEST_CONFIG" "$SLURM_CONFIG" \
            --profile "$SLURM_PROFILE" --dry-run --printshellcmds "$@"
        ;;

    run-slurm)
        require sbatch "Must run on a Slurm cluster (e.g. UCSF CoreHPC)."
        echo "Running pipeline on Slurm cluster..."
        banner "$TEST_CONFIG + $SLURM_CONFIG" "$SLURM_PROFILE"
        sm --configfile "$TEST_CONFIG" "$SLURM_CONFIG" \
            --profile "$SLURM_PROFILE" "$@"
        ;;

    prepull)
        # Download .sif files via the pull_container rule, on whatever host this
        # runs from. Cluster compute nodes typically have no outbound internet,
        # so the Snakefile's onstart auto-pull cannot reach a registry from a
        # submitted job, and with workflow/launch.sh snakemake itself runs on a
        # compute node. Safe to rerun: images whose .sif exists are skipped.
        require apptainer
        if [[ $# -gt 0 ]]; then
            PREPULL_CONFIGS=("$@")
        else
            PREPULL_CONFIGS=("$TEST_CONFIG" "$APPTAINER_CONFIG")
        fi
        SIFS=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && SIFS+=("$line")
        done < <(python "$SCRIPT_DIR/scripts/resolve_sifs.py" "${PREPULL_CONFIGS[@]}")
        echo "Pulling on $(hostname): ${SIFS[*]}"
        sm --configfile "${PREPULL_CONFIGS[@]}" --cores 1 "${SIFS[@]}"
        ;;

    build)
        filter=""
        if [[ $# -gt 0 && ! "${1:-}" =~ ^-- ]]; then
            filter="$1"
            shift
        fi
        if ! compgen -G "$CONTAINERS_DIR/*/" >/dev/null; then
            echo "No subdirectories found under $CONTAINERS_DIR/." >&2
            exit 1
        fi
        any_built=false
        any_found=false
        for dir in "$CONTAINERS_DIR"/*/; do
            name=$(basename "$dir")
            [[ -n "$filter" && "$name" != "$filter" ]] && continue
            any_found=true
            if [[ -x "$dir/build.sh" ]]; then
                echo "=== Building $name ==="
                ( cd "$dir" && ./build.sh "$@" )
                any_built=true
            else
                echo "Skipping $name (no executable build.sh)" >&2
            fi
        done
        if [[ -n "$filter" && $any_found == false ]]; then
            echo "No container matched filter: $filter" >&2
            exit 1
        fi
        if [[ $any_built == false ]]; then
            echo "No containers built." >&2
            exit 1
        fi
        ;;

    dag)
        mkdir -p workflow/test
        echo "Generating rule-level graph..."
        sm --configfile "$TEST_CONFIG" --rulegraph | dot -Tpng > workflow/test/dag.png
        echo "Rule graph saved to workflow/test/dag.png"
        ;;

    lint)
        echo "Linting Snakemake files..."
        sm --configfile "$TEST_CONFIG" --lint "$@"
        ;;

    pytest)
        echo "Running unit tests..."
        python -m pytest tests/ "$@"
        ;;

    list-samples)
        echo "Listing configured samples..."
        sm --configfile "$TEST_CONFIG" list_samples
        ;;

    clean)
        OUTPUT_DIR=$(python -c "import yaml; print(yaml.safe_load(open('$TEST_CONFIG'))['output_dir'])")
        echo "Removing test output directory: $OUTPUT_DIR"
        read -rp "Continue? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$OUTPUT_DIR"
            echo "Cleaned."
        else
            echo "Aborted."
        fi
        ;;

    *)
        usage
        exit 1
        ;;
esac

echo "Done!"

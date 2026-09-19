# estimate_semmedb_predicate_frequencies

A Snakemake pipeline generated from
[snakemake-hpc-template](https://github.com/gladstone-institutes/snakemake-hpc-template).
Each rule runs inside a container, on a laptop with Docker or on the cluster with
Apptainer. [`docs/PIPELINE.md`](docs/PIPELINE.md) explains that model from scratch and
covers setup, CoreHPC Slurm with GPU, building images, and troubleshooting.

## Quickstart

```bash
uv sync
uv run ./workflow/pipeline.sh dry-run    # check the job graph (the DAG)
uv run ./workflow/pipeline.sh run        # run the hello-world example in Docker
```

`uv run` keeps deps in sync with `pyproject.toml` and runs each command with the project's
`.venv` on `$PATH`, so there is no `activate` step.

On CoreHPC, first prove the untouched template runs there (the checklist in
[`docs/PIPELINE.md`](docs/PIPELINE.md)), then submit snakemake itself as a job:

```bash
uv run ./workflow/pipeline.sh prepull <config>   # login node: fetch .sif files
./workflow/launch.sh all check                        # dry-run, submit nothing
./workflow/launch.sh all                              # submit snakemake as a job (the driver)
```

## Wiring in your own scripts

To replace the hello-world example with your real pipeline, see [`AGENTS.md`](AGENTS.md).
It turns existing R / Python / bash scripts into rules, with the questions to answer
first. Written for coding agents, readable by humans.

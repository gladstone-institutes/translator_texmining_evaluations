# estimate_semmedb_predicate_frequencies

A Snakemake pipeline that first downloads the semmeddb database from https://github.com/Translator-CATRAX/SemMedDB-KGX/. It then uses the normalized_edges.jsonl and the normalized_nodes.jsonl files to estimate the frequencies of the triples of different subject, predicate and object biolink categories.

## Quickstart

```bash
uv sync
uv run ./workflow/pipeline.sh dry-run    # check the job graph (the DAG)
uv run ./workflow/pipeline.sh run        # run the pipeline in Docker
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


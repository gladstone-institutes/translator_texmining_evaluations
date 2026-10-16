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

On CoreHPC, we first need to download the semmeddb and CTD data because they can't be downloaded from the internet on computed nodes. Then prove the untouched template runs there (the checklist in
[`docs/PIPELINE.md`](docs/PIPELINE.md)), then submit snakemake itself as a job:

```bash
uv run ./workflow/pipeline.sh prepull <config>   # login node: fetch .sif files
TMPDIR=/mnt/scratch/user/$USER 
./workflow/scripts/download_semmeddb_kgx.sh \
    "https://rtx-kg2-public.s3.us-west-2.amazonaws.com/kg2.10.3_semmeddb_dogpark_uncapped_2026_04_07.tar.gz" \
    /mnt/gladstone/bioinformatics/projects/semmedb_access_predicate_frequencies/results/downloads/normalized_edges.jsonl \
    /mnt/gladstone/bioinformatics/projects/semmedb_access_predicate_frequencies/results/downloads/normalized_nodes.jsonl

./workflow/scripts/download_ctd.sh \
    "https://ctdbase.org/reports/CTD_curated_chemicals_diseases.csv.gz" \
  /mnt/gladstone/bioinformatics/projects/semmedb_access_predicate_frequencies/results/downloads/CTD_curated_chemicals_diseases.csv

./workflow/launch.sh all check                        # dry-run, submit nothing
./workflow/launch.sh all                              # submit snakemake as a job (the driver)
/workflow/launch.sh ctd_recall check                  # only the CTD_recall step
```


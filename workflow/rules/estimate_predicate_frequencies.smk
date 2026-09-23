# Estimates frequencies of (subject_category, predicate, object_category)
# triples in the SemMedDB-KGX normalized edge set produced by
# rules/download_semmeddb.smk. "subject_category"/"object_category" are the
# MOST SPECIFIC Biolink category of each node (first element of its
# `category` list). See workflow/scripts/estimate_predicate_frequencies.py
# for the caveat that this edge set is a filtered subset of raw SemMedDB, not
# the full corpus.
#
# Single aggregate rule: one run over the whole corpus, not per-sample.


def _lookup_args(wildcards):
    triples = config.get("predicate_lookup", [])
    return " ".join(f"--lookup {s} {p} {o}" for s, p, o in triples)


rule estimate_predicate_frequencies:
    """Join edges to node categories and count (subject_category, predicate, object_category)."""
    input:
        edges="{output_dir}/downloads/normalized_edges.jsonl",
        nodes="{output_dir}/downloads/normalized_nodes.jsonl",
        script=script_path("estimate_predicate_frequencies.py"),
    output:
        frequencies="{output_dir}/predicate_frequencies.csv",
        lookup="{output_dir}/predicate_frequency_lookup.tsv",
    params:
        docker=docker_run("duckdb_predicates"),
        apptainer=apptainer_run("duckdb_predicates", gpu=False),
        lookup_args=_lookup_args,
        memory_limit=f"{config['resources']['estimate_predicate_frequencies']['mem_gb']}GB",
        # Not declared as a Snakemake output: DuckDB manages/cleans this itself
        # as spill scratch (out-of-core join support), mirroring the
        # undeclared gpu_sampler output pattern in common.smk. See AGENTS.md's
        # note that anything a tool writes outside declared outputs is not
        # tracked by Snakemake.
        tmp_dir="{output_dir}/tmp/estimate_predicate_frequencies",
    threads: _threads("estimate_predicate_frequencies")
    resources:
        **_resources("estimate_predicate_frequencies", gpu=False),
    benchmark:
        "{output_dir}/benchmarks/estimate_predicate_frequencies.tsv"
    log:
        "{output_dir}/logs/estimate_predicate_frequencies/estimate_predicate_frequencies.log",
    shell:
        "mkdir -p {params.tmp_dir}; "
        "{params.docker}{params.apptainer} python {input.script} "
        "--nodes {input.nodes} --edges {input.edges} "
        "--out {output.frequencies} --lookup-out {output.lookup} "
        "--memory-limit {params.memory_limit} --tmp-dir {params.tmp_dir} "
        "{params.lookup_args} 2>&1 | tee {log}"

# Estimates SemMedDB's recall against CTD's curated chemical-disease
# associations (rules/download_ctd.smk), anchored on PubMed IDs evaluated by
# both resources. See workflow/scripts/estimate_ctd_recall.py for the method
# and its shared caveat with estimate_predicate_frequencies.py (SemMedDB-KGX
# is a filtered subset of raw SemMedDB, not the full corpus).
#
# Single aggregate rule: one run over the whole corpus, not per-sample.


def _ctd_category_args(wildcards):
    ctd = config["ctd"]
    args = [f"--chemical-category {c}" for c in ctd["chemical_categories"]]
    args += [f"--disease-category {c}" for c in ctd["disease_categories"]]
    return " ".join(args)


def _ctd_predicate_args(wildcards):
    predicate_map = config["ctd"]["direct_evidence_predicate_map"]
    args = [f"--therapeutic-predicate {p}" for p in predicate_map["therapeutic"]]
    args += [f"--marker-predicate {p}" for p in predicate_map["marker/mechanism"]]
    return " ".join(args)


rule estimate_ctd_recall:
    """Map SemMedDB CUIs to MeSH, intersect PMIDs with CTD, and score recall."""
    input:
        edges="{output_dir}/downloads/normalized_edges.jsonl",
        nodes="{output_dir}/downloads/normalized_nodes.jsonl",
        ctd="{output_dir}/downloads/CTD_curated_chemicals_diseases.csv",
        script=script_path("estimate_ctd_recall.py"),
    output:
        pairs="{output_dir}/ctd_recall_pairs.csv",
        summary="{output_dir}/ctd_recall_summary.csv",
    params:
        docker=docker_run("duckdb_predicates"),
        apptainer=apptainer_run("duckdb_predicates", gpu=False),
        category_args=_ctd_category_args,
        predicate_args=_ctd_predicate_args,
        memory_limit=f"{config['resources']['estimate_ctd_recall']['mem_gb']}GB",
        # Not declared as a Snakemake output: DuckDB manages/cleans this
        # itself as spill scratch, mirroring estimate_predicate_frequencies.smk.
        tmp_dir="{output_dir}/tmp/estimate_ctd_recall",
    threads: _threads("estimate_ctd_recall")
    resources:
        **_resources("estimate_ctd_recall", gpu=False),
    benchmark:
        "{output_dir}/benchmarks/estimate_ctd_recall.tsv"
    log:
        "{output_dir}/logs/estimate_ctd_recall/estimate_ctd_recall.log",
    shell:
        "mkdir -p {params.tmp_dir}; "
        "{params.docker}{params.apptainer} python {input.script} "
        "--nodes {input.nodes} --edges {input.edges} --ctd {input.ctd} "
        "--out-pairs {output.pairs} --out-summary {output.summary} "
        "{params.category_args} {params.predicate_args} "
        "--memory-limit {params.memory_limit} --tmp-dir {params.tmp_dir} "
        "2>&1 | tee {log}"

# Downloads the SemMedDB-KGX "uncapped" normalized edge/node JSONL files
# (https://github.com/Translator-CATRAX/SemMedDB-KGX) used by
# rules/estimate_predicate_frequencies.smk.
#
# Single aggregate rule: this pulls one corpus-wide archive, not a per-sample
# input, so it does not use the {sample} wildcard.


rule download_semmeddb:
    """Download and extract normalized_edges.jsonl + normalized_nodes.jsonl."""
    input:
        script=script_path("download_semmeddb_kgx.sh"),
    output:
        edges="{output_dir}/downloads/normalized_edges.jsonl",
        nodes="{output_dir}/downloads/normalized_nodes.jsonl",
    params:
        docker=docker_run("semmeddb_download"),
        apptainer=apptainer_run("semmeddb_download", gpu=False),
        archive_url=config["semmeddb_kgx"]["archive_url"],
    threads: _threads("download_semmeddb")
    resources:
        **_resources("download_semmeddb", gpu=False),
    benchmark:
        "{output_dir}/benchmarks/download_semmeddb.tsv"
    log:
        "{output_dir}/logs/download_semmeddb/download_semmeddb.log",
    shell:
        "{params.docker}{params.apptainer} bash {input.script} "
        "{params.archive_url:q} {output.edges} {output.nodes} 2>&1 | tee {log}"

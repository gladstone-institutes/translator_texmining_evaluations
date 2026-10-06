# Downloads CTD's curated chemical-disease associations CSV
# (https://ctdbase.org/downloads/), used by rules/estimate_ctd_recall.smk as
# the gold-standard set for the CTD-anchored recall estimate.
#
# Single aggregate rule: this pulls one corpus-wide file, not a per-sample
# input, so it does not use the {sample} wildcard.


rule download_ctd:
    """Download and extract CTD_curated_chemicals_diseases.csv."""
    input:
        script=script_path("download_ctd.sh"),
    output:
        curated="{output_dir}/downloads/CTD_curated_chemicals_diseases.csv",
    params:
        # Reuses semmeddb_download: it already has curl/tar/bash, and this
        # script only needs curl + gunzip (part of the same base image).
        docker=docker_run("semmeddb_download"),
        apptainer=apptainer_run("semmeddb_download", gpu=False),
        url=config["ctd"]["curated_chem_disease_url"],
    threads: _threads("download_ctd")
    resources:
        **_resources("download_ctd", gpu=False),
    benchmark:
        "{output_dir}/benchmarks/download_ctd.tsv"
    log:
        "{output_dir}/logs/download_ctd/download_ctd.log",
    shell:
        "{params.docker}{params.apptainer} bash {input.script} "
        "{params.url:q} {output.curated} 2>&1 | tee {log}"

# Download images to .sif on the login node before a run. Compute nodes have no
# outbound internet, so the Snakefile's onstart auto-pull cannot run from a job.
# See workflow/profiles/slurm/README.md.
#
#   uv run ./workflow/pipeline.sh prepull      # or: ./workflow/launch.sh <scope> prepull


rule pull_container:
    """Pull one image's .sif on the submit host."""
    output:
        # Concatenated, not an f-string: a literal double brace for the wildcard
        # would be eaten by cookiecutter's Jinja renderer.
        sif=config["containers"]["dir"] + "/{name_tag}.sif",
    wildcard_constraints:
        name_tag=r"[^/]+",
    params:
        uri=lambda wildcards: sif_to_docker_uri(f"{wildcards.name_tag}.sif"),
    shell:
        "apptainer pull {output.sif} {params.uri}"

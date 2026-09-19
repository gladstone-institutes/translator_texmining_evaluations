# Hello-world example rule -- the shape every rule copies. See AGENTS.md.
#
#   1. params.docker / params.apptainer: container prefixes from common.smk.
#      Exactly one expands per run mode; both are "" in host mode.
#   2. input.script = script_path(...): declared as an input so script edits
#      rerun the rule. Snakemake's `code` trigger does not track it otherwise.
#   3. threads/resources from config["resources"][rule]; a missing entry is a
#      KeyError at parse.
#   4. log: written with `... 2>&1 | tee {log}`. NOTE tee truncates and the path
#      has no attempt number, so it holds only the last run of the job.
#
# GPU rules (CoreHPC Slurm): pass gpu=True to BOTH apptainer_run and _resources,
# and optionally prepend gpu_sampler_prefix(...) for nvidia-smi logging:
#
#   params:
#       apptainer=apptainer_run("mytool", gpu=True),
#       gpu_sampler=lambda w, output: gpu_sampler_prefix(
#           Path(output.result).parent, "mygpurule", gpu=True),
#   resources:
#       **_resources("mygpurule", gpu=True),
#
# Replace this file with your real rules and drop its include: from the Snakefile.


def _hello_message(wildcards):
    return samples.loc[wildcards.sample, "message"]


rule hello:
    """Write a per-sample greeting drawn from the samples TSV."""
    input:
        script=script_path("hello.sh"),
    output:
        greeting="{output_dir}/{sample}/hello.txt",
    params:
        docker=docker_run("hello"),
        apptainer=apptainer_run("hello", gpu=False),
        message=_hello_message,
    threads: _threads("hello")
    resources:
        **_resources("hello", gpu=False),
    benchmark:
        "{output_dir}/benchmarks/{sample}/hello.tsv"
    log:
        "{output_dir}/logs/hello/{sample}.log",
    shell:
        "{params.docker}{params.apptainer} bash {input.script} "
        "{wildcards.sample} '{params.message}' {output.greeting} 2>&1 | tee {log}"

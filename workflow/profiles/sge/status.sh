#!/bin/bash
# DEPRECATED: Wynton / SGE support is no longer maintained. It is kept because
# it still works and existing pipelines depend on it, but CoreHPC Slurm
# (workflow/profiles/slurm/) is the supported cluster path -- new work, bug
# fixes and validation go there. Expect no updates here.
#
# SGE job status check for Snakemake's cluster-generic executor.
#
# Why this exists: the obvious `qstat -j <id>` check can only say "is this job
# still in the queue?". Once the job leaves the queue, qstat returns non-zero
# whether the job succeeded or crashed, so the naive check conflates real
# success with silent failures (e.g. Python NameError -> exit 1, OOM kill).
# That made Snakemake declare failed jobs "successful" and then trip on the
# missing outputs 120s later.
#
# This script instead:
#   1. If `qstat -j <id>` says the job is still alive -> "running".
#   2. Otherwise query the SGE accounting DB via `qacct -j <id>` and read
#      exit_status:
#        - empty (qacct not yet populated) -> "running"
#        - "0"   -> "success"
#        - other -> "failed"
#
# Performance note: `qacct -j <id>` scans the full accounting file back to
# front. On Wynton that file is huge and a plain call took >5 min per job.
# We feed qacct the tail of the accounting file via process substitution ->
# 2-3s per call. Recent jobs are always near the tail, so this is safe for
# jobs we're actively tracking.
#
# Non-Wynton SGE: override SGE_ACCOUNTING to point at your cluster's
# accounting file, e.g.:
#   export SGE_ACCOUNTING=/var/spool/sge/common/accounting
#
# The Snakemake plugin invokes this as `{statuscmd} '<jobid>'`, so $1 is the
# SGE job id.
set -u

jobid="$1"

: "${SGE_ACCOUNTING:=/opt/sge/wynton/common/accounting}"
: "${SGE_ACCOUNTING_TAIL:=500000}"

if qstat -j "$jobid" >/dev/null 2>&1; then
    echo running
    exit 0
fi

if [ -r "$SGE_ACCOUNTING" ]; then
    exit_status=$(qacct -j "$jobid" \
        -f <(tail -n "$SGE_ACCOUNTING_TAIL" "$SGE_ACCOUNTING") 2>/dev/null \
        | awk '/^exit_status/ {print $2; exit}')
else
    # Fall back to plain qacct (slow) when the accounting file isn't
    # readable. Better slow-but-correct than fast-but-wrong.
    exit_status=$(qacct -j "$jobid" 2>/dev/null \
        | awk '/^exit_status/ {print $2; exit}')
fi

case "$exit_status" in
    "")   echo running ;;
    "0")  echo success ;;
    *)    echo failed ;;
esac

#!/usr/bin/env bash
# Hello-world example script, invoked by rules/hello.smk. Replace with your own.
set -euo pipefail

sample="$1"
message="$2"
out="$3"

echo "Sample ${sample} says: ${message}" > "${out}"
echo "wrote ${out}"

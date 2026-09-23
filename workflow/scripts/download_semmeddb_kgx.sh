#!/usr/bin/env bash
# Downloads the SemMedDB-KGX "uncapped" archive and extracts just the two
# normalized JSONL files needed downstream, invoked by
# rules/download_semmeddb.smk. Source:
# https://github.com/Translator-CATRAX/SemMedDB-KGX
#
# The archive also contains pre-normalization / merged edge and node files
# and several metadata JSON files (see the repo README); we only pull out
# normalized_edges.jsonl and normalized_nodes.jsonl to avoid keeping multiple
# multi-GB copies of the edge data on disk.
set -euo pipefail

archive_url="$1"
edges_out="$2"
nodes_out="$3"

scratch_dir="$(mktemp -d)"
trap 'rm -rf "${scratch_dir}"' EXIT

archive_path="${scratch_dir}/semmeddb_kgx.tar.gz"
echo "Downloading ${archive_url} ..."
curl -fSL "${archive_url}" -o "${archive_path}"

echo "Extracting normalized_edges.jsonl and normalized_nodes.jsonl ..."
tar -xzf "${archive_path}" -C "${scratch_dir}" \
    --wildcards '*normalized_edges.jsonl' '*normalized_nodes.jsonl'

mkdir -p "$(dirname "${edges_out}")" "$(dirname "${nodes_out}")"
find "${scratch_dir}" -name normalized_edges.jsonl -exec mv {} "${edges_out}" \;
find "${scratch_dir}" -name normalized_nodes.jsonl -exec mv {} "${nodes_out}" \;

echo "Wrote ${edges_out} and ${nodes_out}."

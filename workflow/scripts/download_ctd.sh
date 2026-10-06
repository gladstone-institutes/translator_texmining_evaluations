#!/usr/bin/env bash
# Downloads CTD's curated chemical-disease associations file and extracts the
# CSV, invoked by rules/download_ctd.smk. Source:
# https://ctdbase.org/downloads/ ("Curated Chemical-disease associations")
set -euo pipefail

url="$1"
csv_out="$2"

scratch_dir="$(mktemp -d)"
trap 'rm -rf "${scratch_dir}"' EXIT

archive_path="${scratch_dir}/ctd_curated_chemicals_diseases.csv.gz"
echo "Downloading ${url} ..."
curl -fSL "${url}" -o "${archive_path}"

echo "Extracting CSV ..."
gunzip -c "${archive_path}" > "${scratch_dir}/out.csv"

mkdir -p "$(dirname "${csv_out}")"
mv "${scratch_dir}/out.csv" "${csv_out}"

echo "Wrote ${csv_out}."

"""
Estimate SemMedDB's recall against CTD's curated chemical-disease associations,
anchored on PubMed IDs evaluated by both resources, invoked by
rules/estimate_ctd_recall.smk.

Data sources:
  - SemMedDB-KGX normalized_edges.jsonl / normalized_nodes.jsonl (see
    estimate_predicate_frequencies.py for the shared caveat: this is a
    >3-PMID-filtered subset of raw SemMedDB, not the full corpus).
  - CTD curated chemical-disease associations
    (https://ctdbase.org/reports/CTD_curated_chemicals_diseases.csv.gz):
    one row per (ChemicalID, DiseaseID, DirectEvidence) triple, each with its
    own pipe-delimited PubMedIDs list specific to that evidence type.

Method:
  1. Map SemMedDB's UMLS-CUI subject/object identifiers to MeSH via the
     `equivalent_identifiers` cross-references already present in
     normalized_nodes.jsonl (no UMLS MRCONSO license needed).
  2. Restrict to chemical-category-subject / disease-category-object edges,
     then unnest `publications` to (chem_mesh, predicate, disease_mesh, pmid)
     rows -- small enough to unnest directly since step 2 happens first.
  3. Unnest CTD's DirectEvidence/PubMedIDs similarly to (chem_mesh,
     disease_mesh, direct_evidence, pmid) rows (MeSH-only disease rows; OMIM
     rows are excluded and counted).
  4. Intersect the two sides' distinct PMIDs: the common-PMID anchor set.
  5. For each CTD row restricted to common PMIDs: "found_entities" = does any
     SemMedDB row share (chem_mesh, disease_mesh, pmid)? "found_predicate" =
     does a matching SemMedDB row's predicate fall in the configured set for
     that row's DirectEvidence value ("therapeutic" / "marker/mechanism")?

Requires: duckdb (see workflow/containers/duckdb_predicates/Dockerfile).
"""

import argparse
import sys

import duckdb


def _count_header_comment_lines(path: str) -> int:
    """Count leading '#'-prefixed lines in the CTD CSV (no real header row;
    the actual column order is only documented in a '# Fields:' comment)."""
    n = 0
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if not line.startswith("#"):
                break
            n += 1
    return n


def build_recall_tables(
    con: duckdb.DuckDBPyConnection,
    nodes_path: str,
    edges_path: str,
    ctd_path: str,
    chemical_categories: list[str],
    disease_categories: list[str],
    therapeutic_predicates: list[str],
    marker_predicates: list[str],
    max_object_size: int,
) -> None:
    con.execute(
        f"""
        CREATE OR REPLACE TABLE nodes AS
        SELECT
            id,
            replace(category[1], 'biolink:', '') AS most_specific_category,
            equivalent_identifiers
        FROM read_ndjson(
            '{nodes_path}',
            columns = {{
                id: 'VARCHAR', category: 'VARCHAR[]',
                equivalent_identifiers: 'VARCHAR[]'
            }},
            maximum_object_size = {max_object_size}
        )
        """
    )

    # CUI -> MeSH CURIE, from the node normalizer's cross-references. Limited
    # to chemical/disease-like categories so the unnest stays small.
    con.execute(
        """
        CREATE OR REPLACE TABLE node_mesh AS
        SELECT DISTINCT n.id AS cui, n.most_specific_category, xref AS mesh_curie
        FROM nodes n, unnest(n.equivalent_identifiers) AS u(xref)
        WHERE xref LIKE 'MESH:%'
          AND n.most_specific_category IN (SELECT unnest(?))
        """,
        [chemical_categories + disease_categories],
    )
    con.execute(
        "CREATE OR REPLACE TABLE chem_map AS "
        "SELECT cui, mesh_curie FROM node_mesh WHERE most_specific_category IN (SELECT unnest(?))",
        [chemical_categories],
    )
    con.execute(
        "CREATE OR REPLACE TABLE disease_map AS "
        "SELECT cui, mesh_curie FROM node_mesh WHERE most_specific_category IN (SELECT unnest(?))",
        [disease_categories],
    )

    con.execute(
        f"""
        CREATE OR REPLACE TABLE edges_raw AS
        SELECT
            subject,
            replace(predicate, 'biolink:', '') AS predicate,
            object,
            publications
        FROM read_ndjson(
            '{edges_path}',
            columns = {{
                subject: 'VARCHAR', predicate: 'VARCHAR', object: 'VARCHAR',
                publications: 'VARCHAR[]'
            }},
            maximum_object_size = {max_object_size}
        )
        """
    )

    # Filter to chemical-subject / disease-object edges BEFORE unnesting
    # publications, so the unnest only touches a small slice of the corpus.
    con.execute(
        """
        CREATE OR REPLACE TABLE chem_disease_edges AS
        SELECT e.subject, e.predicate, e.object, e.publications
        FROM edges_raw e
        JOIN nodes sn ON e.subject = sn.id AND sn.most_specific_category IN (SELECT unnest(?))
        JOIN nodes on_ ON e.object = on_.id AND on_.most_specific_category IN (SELECT unnest(?))
        """,
        [chemical_categories, disease_categories],
    )

    con.execute(
        """
        CREATE OR REPLACE TABLE semmed_pmid_edges AS
        SELECT DISTINCT
            cm.mesh_curie AS chem_mesh,
            e.predicate,
            dm.mesh_curie AS disease_mesh,
            replace(pmid, 'PMID:', '') AS pmid
        FROM chem_disease_edges e, unnest(e.publications) AS u(pmid)
        JOIN chem_map cm ON e.subject = cm.cui
        JOIN disease_map dm ON e.object = dm.cui
        """
    )

    # CTD side. No real header row -- the column order is only documented in
    # a '# Fields:' comment -- so skip the leading comment block by count.
    skip = _count_header_comment_lines(ctd_path)
    con.execute(
        f"""
        CREATE OR REPLACE TABLE ctd_raw AS
        SELECT * FROM read_csv(
            '{ctd_path}',
            header = false,
            skip = {skip},
            delim = ',',
            quote = '"',
            escape = '"',
            columns = {{
                ChemicalName: 'VARCHAR', ChemicalID: 'VARCHAR', CasRN: 'VARCHAR',
                DiseaseName: 'VARCHAR', DiseaseID: 'VARCHAR',
                DirectEvidence: 'VARCHAR', PubMedIDs: 'VARCHAR'
            }}
        )
        """
    )

    # ChemicalID is a bare MeSH accession (e.g. "C046983"/"D002945"); DiseaseID
    # is already a full CURIE ("MESH:D..." or "OMIM:..."). DirectEvidence and
    # PubMedIDs are each pipe-delimited; in the curated-only file every row
    # observed has exactly one DirectEvidence value, each with its own PMID
    # list (not pooled across evidence types) -- but we still cross-join in
    # case of a rare multi-value row, matching the lenient-scoring choice.
    con.execute(
        """
        CREATE OR REPLACE TABLE ctd_exploded AS
        SELECT
            'MESH:' || ChemicalID AS chem_mesh,
            DiseaseID AS disease_mesh,
            de AS direct_evidence,
            pmid
        FROM ctd_raw,
             unnest(string_split(DirectEvidence, '|')) AS t1(de),
             unnest(string_split(PubMedIDs, '|')) AS t2(pmid)
        """
    )

    con.execute(
        "CREATE OR REPLACE TABLE ctd_mesh_only AS "
        "SELECT * FROM ctd_exploded WHERE disease_mesh LIKE 'MESH:%'"
    )

    con.execute(
        """
        CREATE OR REPLACE TABLE common_pmids AS
        SELECT DISTINCT pmid FROM ctd_mesh_only
        INTERSECT
        SELECT DISTINCT pmid FROM semmed_pmid_edges
        """
    )

    con.execute(
        """
        CREATE OR REPLACE TABLE ctd_common AS
        SELECT DISTINCT chem_mesh, disease_mesh, pmid, direct_evidence
        FROM ctd_mesh_only
        WHERE pmid IN (SELECT pmid FROM common_pmids)
        """
    )

    con.execute(
        """
        CREATE OR REPLACE TABLE semmed_common AS
        SELECT DISTINCT chem_mesh, predicate, disease_mesh, pmid
        FROM semmed_pmid_edges
        WHERE pmid IN (SELECT pmid FROM common_pmids)
        """
    )

    con.execute(
        "CREATE OR REPLACE TABLE predicate_map (direct_evidence VARCHAR, predicate VARCHAR)"
    )
    con.executemany(
        "INSERT INTO predicate_map VALUES (?, ?)",
        [("therapeutic", p) for p in therapeutic_predicates]
        + [("marker/mechanism", p) for p in marker_predicates],
    )

    con.execute(
        """
        CREATE OR REPLACE TABLE ctd_recall_pairs AS
        SELECT
            c.chem_mesh,
            c.disease_mesh,
            c.pmid,
            c.direct_evidence,
            EXISTS (
                SELECT 1 FROM semmed_common s
                WHERE s.chem_mesh = c.chem_mesh AND s.disease_mesh = c.disease_mesh
                  AND s.pmid = c.pmid
            ) AS found_entities,
            EXISTS (
                SELECT 1 FROM semmed_common s
                JOIN predicate_map pm
                  ON pm.predicate = s.predicate AND pm.direct_evidence = c.direct_evidence
                WHERE s.chem_mesh = c.chem_mesh AND s.disease_mesh = c.disease_mesh
                  AND s.pmid = c.pmid
            ) AS found_predicate,
            (
                SELECT list_distinct(list(s.predicate))
                FROM semmed_common s
                WHERE s.chem_mesh = c.chem_mesh AND s.disease_mesh = c.disease_mesh
                  AND s.pmid = c.pmid
            ) AS matched_semmed_predicates
        FROM ctd_common c
        """
    )

    con.execute(
        """
        CREATE OR REPLACE TABLE ctd_recall_summary AS
        SELECT
            direct_evidence,
            count(*) AS n_ctd_common_pairs,
            sum(found_entities::INT) AS n_entity_matches,
            sum(found_entities::INT) * 1.0 / count(*) AS entity_recall,
            sum(found_predicate::INT) AS n_predicate_matches,
            sum(found_predicate::INT) * 1.0 / count(*) AS predicate_recall
        FROM ctd_recall_pairs
        GROUP BY direct_evidence
        UNION ALL
        SELECT
            'ALL' AS direct_evidence,
            count(*),
            sum(found_entities::INT),
            sum(found_entities::INT) * 1.0 / count(*),
            sum(found_predicate::INT),
            sum(found_predicate::INT) * 1.0 / count(*)
        FROM ctd_recall_pairs
        ORDER BY direct_evidence
        """
    )


def print_diagnostics(con: duckdb.DuckDBPyConnection) -> None:
    """Coverage diagnostics -- printed (captured by the rule's log tee), not
    written as a declared output, mirroring estimate_predicate_frequencies.py."""
    n_common_pmids = con.execute("SELECT count(*) FROM common_pmids").fetchone()[0]
    n_ctd_all_pmids = con.execute("SELECT count(DISTINCT pmid) FROM ctd_mesh_only").fetchone()[0]
    n_semmed_all_pmids = con.execute(
        "SELECT count(DISTINCT pmid) FROM semmed_pmid_edges"
    ).fetchone()[0]
    n_omim_rows = con.execute(
        "SELECT count(*) FROM ctd_exploded WHERE disease_mesh NOT LIKE 'MESH:%'"
    ).fetchone()[0]
    n_omim_pairs = con.execute(
        "SELECT count(*) FROM (SELECT DISTINCT chem_mesh, disease_mesh FROM ctd_exploded "
        "WHERE disease_mesh NOT LIKE 'MESH:%')"
    ).fetchone()[0]
    n_chem_cuis_total = con.execute(
        "SELECT count(DISTINCT subject) FROM chem_disease_edges"
    ).fetchone()[0]
    n_chem_cuis_mapped = con.execute(
        "SELECT count(DISTINCT subject) FROM chem_disease_edges WHERE subject IN (SELECT cui FROM chem_map)"
    ).fetchone()[0]
    n_disease_cuis_total = con.execute(
        "SELECT count(DISTINCT object) FROM chem_disease_edges"
    ).fetchone()[0]
    n_disease_cuis_mapped = con.execute(
        "SELECT count(DISTINCT object) FROM chem_disease_edges WHERE object IN (SELECT cui FROM disease_map)"
    ).fetchone()[0]

    print("\nDiagnostics:")
    print(f"  Common PMIDs (evaluated by both CTD and SemMedDB): {n_common_pmids}")
    print(f"  CTD distinct PMIDs (MeSH-disease rows only): {n_ctd_all_pmids}")
    print(f"  SemMedDB distinct PMIDs (chemical/disease edges): {n_semmed_all_pmids}")
    print(f"  CTD rows excluded for non-MeSH (OMIM) DiseaseID: {n_omim_rows} rows, "
          f"{n_omim_pairs} distinct (chemical, disease) pairs")
    print(f"  SemMedDB chemical-subject CUIs mapped to MeSH: "
          f"{n_chem_cuis_mapped}/{n_chem_cuis_total}")
    print(f"  SemMedDB disease-object CUIs mapped to MeSH: "
          f"{n_disease_cuis_mapped}/{n_disease_cuis_total}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nodes", required=True, help="Path to normalized_nodes.jsonl")
    parser.add_argument("--edges", required=True, help="Path to normalized_edges.jsonl")
    parser.add_argument("--ctd", required=True, help="Path to CTD_curated_chemicals_diseases.csv")
    parser.add_argument("--out-pairs", required=True, help="Where to write per-pair recall detail")
    parser.add_argument("--out-summary", required=True, help="Where to write the recall summary")
    parser.add_argument(
        "--chemical-category", action="append", default=[],
        help="Biolink category (no 'biolink:' prefix) treated as chemical-like. Repeatable.",
    )
    parser.add_argument(
        "--disease-category", action="append", default=[],
        help="Biolink category (no 'biolink:' prefix) treated as disease-like. Repeatable.",
    )
    parser.add_argument(
        "--therapeutic-predicate", action="append", default=[],
        help="SemMedDB predicate counted as matching CTD's 'therapeutic' DirectEvidence. Repeatable.",
    )
    parser.add_argument(
        "--marker-predicate", action="append", default=[],
        help="SemMedDB predicate counted as matching CTD's 'marker/mechanism' DirectEvidence. Repeatable.",
    )
    parser.add_argument("--db", default=":memory:", help="DuckDB database file (default in-memory)")
    parser.add_argument("--memory-limit", default=None, help="Optional DuckDB memory limit, e.g. '16GB'")
    parser.add_argument("--tmp-dir", default=None, help="Optional DuckDB temp_directory for spilling")
    parser.add_argument(
        "--max-object-size", type=int, default=67_108_864,
        help="read_ndjson maximum_object_size in bytes (default 64MiB).",
    )
    args = parser.parse_args()

    if not args.chemical_category or not args.disease_category:
        sys.exit("error: at least one --chemical-category and --disease-category are required")

    con = duckdb.connect(args.db)
    if args.memory_limit:
        con.execute(f"PRAGMA memory_limit='{args.memory_limit}'")
    if args.tmp_dir:
        con.execute(f"PRAGMA temp_directory='{args.tmp_dir}'")

    build_recall_tables(
        con,
        args.nodes,
        args.edges,
        args.ctd,
        args.chemical_category,
        args.disease_category,
        args.therapeutic_predicate,
        args.marker_predicate,
        args.max_object_size,
    )

    con.execute(f"COPY ctd_recall_pairs TO '{args.out_pairs}' (HEADER, DELIMITER ',')")
    con.execute(f"COPY ctd_recall_summary TO '{args.out_summary}' (HEADER, DELIMITER ',')")

    n_pairs = con.execute("SELECT count(*) FROM ctd_recall_pairs").fetchone()[0]
    print(f"Wrote {n_pairs} CTD (chemical, disease, pmid, direct_evidence) rows to {args.out_pairs}")
    print(f"\nSummary ({args.out_summary}):")
    print(con.execute("SELECT * FROM ctd_recall_summary").df())

    print_diagnostics(con)


if __name__ == "__main__":
    main()

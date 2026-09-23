"""
Estimate frequencies of (subject_category, predicate, object_category) triples
in the SemMedDB-KGX "uncapped" normalized edge set, invoked by
rules/estimate_predicate_frequencies.smk.

Data source: https://github.com/Translator-CATRAX/SemMedDB-KGX
  - normalized_edges.jsonl  (subject/predicate/object CURIEs + publications)
  - normalized_nodes.jsonl  (CURIE -> Biolink category list, most-specific first)

Caveat: this edge set is a FILTERED subset of raw SemMedDB (>3-PMID filter,
domain/range exclusion, BTE-excluded predicates dropped -- see the repo README's
"Transform stats"). Frequencies below are relative frequencies within this
already-curated set, not the raw SemMedDB PREDICATION table.

Requires: duckdb, pandas (see workflow/containers/duckdb_predicates/Dockerfile).
"""

import argparse
import duckdb


def build_frequency_table(con: duckdb.DuckDBPyConnection, nodes_path: str, edges_path: str) -> None:
    # Most-specific category = category[1] (DuckDB lists are 1-indexed).
    # KGX/bmt convention orders a node's `category` list most-specific first.
    con.execute(
        f"""
        CREATE OR REPLACE TABLE nodes AS
        SELECT
            id,
            replace(category[1], 'biolink:', '') AS most_specific_category
        FROM read_ndjson(
            '{nodes_path}',
            columns = {{id: 'VARCHAR', category: 'VARCHAR[]'}}
        )
        """
    )

    # Explicit column projection so DuckDB never materializes the large
    # embedded `has_supporting_studies` text field per edge.
    con.execute(
        f"""
        CREATE OR REPLACE TABLE edges AS
        SELECT
            subject,
            replace(predicate, 'biolink:', '') AS predicate,
            object,
            len(publications) AS n_publications
        FROM read_ndjson(
            '{edges_path}',
            columns = {{
                subject: 'VARCHAR',
                predicate: 'VARCHAR',
                object: 'VARCHAR',
                publications: 'VARCHAR[]'
            }}
        )
        """
    )

    con.execute(
        """
        CREATE OR REPLACE TABLE predicate_frequencies AS
        SELECT
            sn.most_specific_category AS subject_category,
            e.predicate,
            on_.most_specific_category AS object_category,
            COUNT(*) AS n_edges,
            SUM(e.n_publications) AS n_publications
        FROM edges e
        JOIN nodes sn ON e.subject = sn.id
        JOIN nodes on_ ON e.object = on_.id
        GROUP BY 1, 2, 3
        ORDER BY n_edges DESC
        """
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nodes", required=True, help="Path to normalized_nodes.jsonl")
    parser.add_argument("--edges", required=True, help="Path to normalized_edges.jsonl")
    parser.add_argument(
        "--out", required=True,
        help="Where to write the full (subject_category, predicate, object_category) frequency table",
    )
    parser.add_argument(
        "--lookup-out", default=None,
        help="Optional path to write the --lookup rows as a TSV (subject_category, predicate, "
             "object_category, n_edges, n_publications, found)",
    )
    parser.add_argument(
        "--db", default=":memory:",
        help="DuckDB database file to use instead of in-memory (useful if RAM-constrained; "
             "DuckDB will spill to disk under a file-backed database)",
    )
    parser.add_argument(
        "--memory-limit", default=None,
        help="Optional DuckDB memory limit, e.g. '8GB'",
    )
    parser.add_argument(
        "--tmp-dir", default=None,
        help="Optional DuckDB temp_directory for out-of-core spilling (PRAGMA temp_directory)",
    )
    parser.add_argument(
        "--lookup", nargs=3, metavar=("SUBJECT_CATEGORY", "PREDICATE", "OBJECT_CATEGORY"),
        action="append", default=[],
        help="Print the frequency for one specific triple, e.g. "
             "--lookup Procedure has_input PhysicalEntity. Repeatable.",
    )
    args = parser.parse_args()

    con = duckdb.connect(args.db)
    if args.memory_limit:
        con.execute(f"PRAGMA memory_limit='{args.memory_limit}'")
    if args.tmp_dir:
        con.execute(f"PRAGMA temp_directory='{args.tmp_dir}'")

    build_frequency_table(con, args.nodes, args.edges)

    con.execute(f"COPY predicate_frequencies TO '{args.out}' (HEADER, DELIMITER ',')")
    n_rows = con.execute("SELECT count(*) FROM predicate_frequencies").fetchone()[0]
    print(f"Wrote {n_rows} distinct (subject_category, predicate, object_category) rows to {args.out}")

    print("\nTop 20 triples by edge count:")
    print(con.execute("SELECT * FROM predicate_frequencies LIMIT 20").df())

    lookup_rows = []
    for subj_cat, predicate, obj_cat in args.lookup:
        row = con.execute(
            """
            SELECT n_edges, n_publications FROM predicate_frequencies
            WHERE subject_category = ? AND predicate = ? AND object_category = ?
            """,
            [subj_cat, predicate, obj_cat],
        ).fetchone()
        if row is None:
            print(f"\n{subj_cat} -- {predicate} -- {obj_cat}: 0 edges (not found)")
            lookup_rows.append((subj_cat, predicate, obj_cat, 0, 0, False))
        else:
            n_edges, n_publications = row
            print(f"\n{subj_cat} -- {predicate} -- {obj_cat}: {n_edges} edges, {n_publications} publications")
            lookup_rows.append((subj_cat, predicate, obj_cat, n_edges, n_publications, True))

    if args.lookup_out:
        with open(args.lookup_out, "w") as f:
            f.write("subject_category\tpredicate\tobject_category\tn_edges\tn_publications\tfound\n")
            for row in lookup_rows:
                f.write("\t".join(str(v) for v in row) + "\n")


if __name__ == "__main__":
    main()

# samplesheet-ops

A single, reusable Nextflow connector for common samplesheet/metadata
operations: merge/join, drop/select/rename columns, drop rows (`dropna` / `drop_duplicates`), filter,
and concat. Reads one or two CSV/TSV samplesheets, applies an ordered chain of
operations, and writes the result as CSV or TSV. Implemented entirely with native
Nextflow channel operators (`map`, `filter`, `flatMap`, `unique`, `concat`, `collect`, `collectFile`)
— no Python/pandas dependency.

The logic lives in a named workflow, `SAMPLESHEET_OPS`, which takes all params as
explicit inputs and emits the written file as a path (`SAMPLESHEET_OPS.out.samplesheet`).
See [Using as a subworkflow](#using-as-a-subworkflow).

## Usage

```bash
nextflow run https://github.com/bmds-tue/nf-meta-samplesheet-ops \
  --samplesheet1 sheet_a.csv \
  --samplesheet2 sheet_b.tsv \
  --ops merge,drop_columns,filter \
  --merge_on sample --merge_how left \
  --drop_columns_cols batch_x,batch_y \
  --filter_col condition --filter_op ne --filter_value control \
  --outdir results --outname samplesheet.csv
```

`--ops` is an ordered, comma-separated list of operation names; each op's arguments
come from its own flat `--<op>_*` params, and ops apply left-to-right to a running
samplesheet that starts as `samplesheet1`. Each op may appear at most once per run.

**Limitation:** `merge` and `concat` always read `samplesheet2` fresh — earlier ops in
the chain transform `samplesheet1`'s running state only, not `samplesheet2` itself.

## Input requirements

- **The first line of every input sheet is a header**, and **column names must be unique**.
  Every op addresses columns by name, so a sheet with a repeated column name (e.g.
  `sample,a,a`) fails the run immediately rather than silently losing one of the columns.
- A **header-only** sheet (zero data rows) is valid: its columns are still known, so
  e.g. a `merge` against it works and a `filter` on it writes a header-only result.
- A **completely empty** (0-byte) sheet is rejected.
- Rows with fewer fields than the header get blank values for the missing columns.
- All values are treated as **strings**: comparisons (`merge_on` keys, `filter`,
  `drop_duplicates`) are exact and case-sensitive, so `1` and `1.0` differ.

## Global params

| Param | Default | Description |
|---|---|---|
| `samplesheet1` | (required) | Path to the primary sheet (`.csv`, `.tsv` or `.tab`). |
| `samplesheet2` | — | Path to the second sheet. Required only if `--ops` includes `merge` or `concat`. |
| `ops` | (required) | Ordered comma-separated operation list, e.g. `merge,dropna`. |
| `outdir` | (required) | Directory the output samplesheet is written to. |
| `outname` | `samplesheet.csv` | Output filename, including extension. |
| `quote` | `"` | Quote character used both when parsing input CSV/TSV and when quoting output fields. |
| `drop_header` | `false` | Omit the header row from the output samplesheet. Output-only -- input parsing always assumes a header, since every op binds columns by name. If the result has zero rows, the output file is empty (0 bytes) rather than header-only. |
| `help` | `false` | Print parameter help and exit (see [Params validation & help](#params-validation--help)). |

Both input and output delimiters are auto-detected from a file's extension (`.csv` →
comma, `.tsv`/`.tab` → tab) — `outname`'s extension is what controls the output
format, so give it a `.csv`/`.tsv`/`.tab` name.

Output fields are quoted (RFC4180-style, doubling embedded quote characters) whenever
a value contains the output delimiter, the quote character, or a newline — so free-text
columns (notes, descriptions, ...) round-trip safely.

## Operations

| op | params | Behavior |
|---|---|---|
| `merge` | `merge_on` (default `sample`), `merge_how` (`inner`\|`left`, default `inner`), `merge_suffixes` (default `_x,_y`) | Joins `samplesheet1` (running state) with `samplesheet2` on a single shared key column. Repeated keys are allowed on either side: each left row is paired with *every* matching right row, as in pandas/SQL. `inner` keeps only matched left rows; `left` keeps all left rows, blank-filling right-side columns when unmatched. Rows only in `samplesheet2` are never output. Overlapping non-key column names get suffixed per `merge_suffixes`; the run fails if a suffixed name would collide with an existing column. |
| `drop_columns` | `drop_columns_cols` (required) | Removes the given comma-separated columns. Errors if a listed column doesn't exist. |
| `select_columns` | `select_columns_cols` (required) | Inverse of `drop_columns`: keeps only the given comma-separated columns, in that order, and drops everything else. Errors if a listed column doesn't exist or is listed twice. |
| `rename` | `rename_cols` (required) | Renames columns per a comma-separated `old_key=new_key,...` mapping. `old_key` is matched against the current column names (longest match wins), so either side may itself contain `=` -- only the outer comma is a hard separator (column names containing a comma aren't representable, same limitation every other op's comma-separated param has). Column order is unchanged. Errors if `old_key` doesn't match an existing column, or if the result would contain duplicate column names. |
| `dropna` | `dropna_cols` (default: all columns) | Drops rows where any of the given columns is blank (empty or whitespace-only). Errors if a listed column doesn't exist. |
| `drop_duplicates` | `drop_duplicates_cols` (default: all columns) | Deduplicates rows by the given column(s), comparing each column's value separately, and keeps the first occurrence. Errors if a listed column doesn't exist. |
| `filter` | `filter_col` (required), `filter_op` (`eq`\|`ne`\|`contains`, default `eq`), `filter_value` (required) | Keeps rows where `filter_col` matches `filter_value` per `filter_op` (case-sensitive string comparison; `contains` is a substring match; a blank cell compares as the empty string). Errors if `filter_col` doesn't exist. |
| `concat` | none beyond `samplesheet2` | Stacks `samplesheet1` (running state) and `samplesheet2` row-wise — all `samplesheet1` rows first, then all `samplesheet2` rows — taking the union of both column sets (first sheet's columns first) and blank-filling cells missing from either side. |

### Row order

Row order is deterministic: every op preserves the order of its input rows. `merge`
follows `samplesheet1`'s order (a left row matching several right rows expands in place,
in `samplesheet2`'s order), `drop_duplicates` keeps the first occurrence of each key, and
`concat` writes `samplesheet1`'s rows before `samplesheet2`'s.

### Validation errors

Problems are reported before any rows are processed, with a message naming the param:

- an input sheet that is empty or has duplicate column names;
- an unknown op, or the same op listed twice in `ops`;
- a missing required per-op param (`drop_columns_cols`, `select_columns_cols`, `rename_cols`, `filter_col`, `filter_value`);
- any column param (`merge_on`, `drop_columns_cols`, `select_columns_cols`, `rename_cols`,
  `dropna_cols`, `drop_duplicates_cols`, `filter_col`) naming a column that doesn't exist
  at that point in the chain — e.g. after a `rename`, refer to the new name;
- an op that would produce duplicate column names (`rename`, or `merge` suffix collisions);
- `samplesheet2` missing when `merge`/`concat` is requested;
- an input or output filename without a `.csv`/`.tsv`/`.tab` extension.

## Examples

Drop rows missing a value, then dedup by sample:

```bash
nextflow run main.nf --samplesheet1 sheet.csv --ops dropna,drop_duplicates \
  --dropna_cols condition --drop_duplicates_cols sample --outdir results
```

Stack two sheets with differing columns into one TSV:

```bash
nextflow run main.nf --samplesheet1 a.csv --samplesheet2 b.tsv \
  --ops concat --outdir results --outname samplesheet.tsv
```

Rename a column, then keep only the columns a downstream pipeline expects:

```bash
nextflow run main.nf --samplesheet1 sheet.csv --ops rename,select_columns \
  --rename_cols sample=sample_id --select_columns_cols sample_id,fastq_1,fastq_2 \
  --outdir results
```

Attach per-sample metadata to a per-lane sheet (every lane row gets its sample's metadata):

```bash
nextflow run main.nf --samplesheet1 lanes.csv --samplesheet2 metadata.tsv \
  --ops merge --merge_on sample --merge_how left --outdir results
```

## Compatibility

This repo tracks the **most recent nf-core pipeline template**: its minimum Nextflow
version and its nf-schema plugin version are kept at or above the template's.

## Params validation & help

Parameters are described in `nextflow_schema.json` (types, defaults, required/enum/pattern
constraints) via the [nf-schema](https://nextflow-io.github.io/nf-schema/) plugin. Every
run validates params against that schema before anything executes, so a missing required
param, an unknown `--ops` value, or an invalid enum fails fast with a clear message
instead of an obscure downstream error.

```bash
nextflow run main.nf --help        # all top-level params, grouped
nextflow run main.nf --help ops    # detailed help for a single param
nextflow run main.nf --helpFull    # include hidden/advanced params too
```

## Test

```bash
nf-test test test/                         # everything
nf-test test test/main.nf.test             # pipeline-level tests (params -> output file)
nf-test test test/samplesheet_ops.nf.test  # SAMPLESHEET_OPS called as a subworkflow
```

## Planned

**`collect` op** — seed a samplesheet from a directory listing instead of an existing
CSV/TSV, e.g. `--collect_pattern '/foo/bar/*.tsv'`. Valid only as the first op in the
chain (mutually exclusive with `samplesheet1` for that run), producing a minimal
`path`/`filename`-column sheet, deterministically sorted, that the rest of the chain
(`rename`, `merge`, ...) can shape further. Deliberately scoped to a flat file list —
no filename-pattern sample-ID extraction or R1/R2 pairing, since that's convention-specific
glue better suited to a dedicated per-transition adapter than this general-purpose one.

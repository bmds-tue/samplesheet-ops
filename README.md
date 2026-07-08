# nf-meta-samplesheet-ops

A single, reusable Nextflow connector for common samplesheet/metadata
operations: merge/join, drop columns, drop rows (`dropna` / `drop_duplicates`), filter,
and concat. Reads one or two CSV/TSV samplesheets, applies an ordered chain of
operations, and writes the result as CSV or TSV. Implemented entirely with native
Nextflow channel operators (`map`, `filter`, `join`, `groupTuple`, `mix`, `collectFile`)
— no Python/pandas dependency.

The logic lives in a named workflow, `SAMPLESHEET_OPS`, which takes all params as
explicit inputs and emits the written file as a path (`SAMPLESHEET_OPS.out.samplesheet`).

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
samplesheet that starts as `samplesheet1`. An op name can only appear once per run.

**Limitation:** `merge` and `concat` always read `samplesheet2` fresh — earlier ops in
the chain transform `samplesheet1`'s running state only, not `samplesheet2` itself.

## Global params

| Param | Default | Description |
|---|---|---|
| `samplesheet1` | (required) | Path to the primary sheet. |
| `samplesheet2` | — | Path to the second sheet. Required only if `--ops` includes `merge` or `concat`. |
| `ops` | (required) | Ordered comma-separated operation list, e.g. `merge,dropna`. |
| `outdir` | (required) | Directory the output samplesheet is written to. |
| `outname` | `samplesheet.csv` | Output filename, including extension. |
| `quote` | `"` | Quote character used both when parsing input CSV/TSV and when quoting output fields. |

Both input and output delimiters are auto-detected from a file's extension (`.csv` →
comma, `.tsv`/`.tab` → tab) — `outname`'s extension is what controls the output
format, so give it a `.csv`/`.tsv`/`.tab` name.

Output fields are quoted (RFC4180-style, doubling embedded quote characters) whenever
a value contains the output delimiter, the quote character, or a newline — so free-text
columns (notes, descriptions, ...) round-trip safely.

## Operations

| op | params | Behavior |
|---|---|---|
| `merge` | `merge_on` (default `sample`), `merge_how` (`inner`\|`left`, default `inner`), `merge_suffixes` (default `_x,_y`) | Joins `samplesheet1` (running state) with `samplesheet2` on a single shared key column. Overlapping non-key column names get suffixed per `merge_suffixes`. `left` keeps all left rows, blank-filling right-side columns when unmatched. |
| `drop_columns` | `drop_columns_cols` (required) | Removes the given comma-separated columns. |
| `dropna` | `dropna_cols` (default: all columns) | Drops rows where any of the given columns is blank. |
| `drop_duplicates` | `drop_duplicates_cols` (default: all columns) | Deduplicates rows by the given column(s), keeping the first occurrence. |
| `filter` | `filter_col` (required), `filter_op` (`eq`\|`ne`\|`contains`, default `eq`), `filter_value` (required) | Keeps rows where `filter_col` matches `filter_value` per `filter_op` (string comparison). |
| `concat` | none beyond `samplesheet2` | Stacks `samplesheet1` (running state) and `samplesheet2` row-wise, taking the union of both column sets and blank-filling cells missing from either side. |

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
nf-test test test/main.nf.test
```

nextflow.enable.dsl = 2

params.samplesheet1         = null
params.samplesheet2         = null
params.ops                  = null
params.outdir               = null
params.outname              = 'samplesheet.csv'
params.quote                = '"'

params.merge_on             = "sample"
params.merge_how            = 'inner'
params.merge_suffixes       = '_x,_y'
params.drop_columns_cols    = null
params.dropna_cols          = null
params.drop_duplicates_cols = null
params.filter_col           = null
params.filter_op            = 'eq'
params.filter_value         = null

def supportedOps() {
    return ['merge', 'drop_columns', 'dropna', 'drop_duplicates', 'filter', 'concat']
}

// Also used for the output file: the delimiter is derived from whichever path/name is passed in.
def detectSep(path) {
    def name = path.toString().toLowerCase()
    if (name.endsWith('.csv')) return ','
    if (name.endsWith('.tsv') || name.endsWith('.tab')) return '\t'
    error "Cannot detect delimiter for '${path}' -- expected a .csv or .tsv/.tab extension"
}

def splitList(s) {
    if (!s) return []
    return s.split(',')*.trim()
}

// Applies one op to the running channel, returning [newChannel, newColumnList] so
// later ops (and the final header) know the shape without re-inspecting the data.
// opParams bundles the per-op arguments so this stays a pure function of its inputs
// rather than reading the global params object directly.
def applyOp(op, ch, cols, sheet2Rows, sheet2Cols, opParams) {

    if (op == 'drop_columns') {
        def dropCols = splitList(opParams.drop_columns_cols)
        if (!dropCols) error "drop_columns_cols is required for the 'drop_columns' op"
        return [ ch.map { row -> row.findAll { k, v -> !(k in dropCols) } }, cols - dropCols ]
    }

    if (op == 'dropna') {
        def naCols = splitList(opParams.dropna_cols) ?: cols
        return [ ch.filter { row -> naCols.every { c -> row[c]?.toString()?.trim() } }, cols ]
    }

    if (op == 'drop_duplicates') {
        def dedupCols = splitList(opParams.drop_duplicates_cols) ?: cols
        def dedupedCh = ch
            .map { row -> tuple(dedupCols.collect { row[it] }.join(''), row) }
            .groupTuple()
            .map { key, rows -> rows[0] }
        return [ dedupedCh, cols ]
    }

    if (op == 'filter') {
        def col   = opParams.filter_col
        def fop   = opParams.filter_op ?: 'eq'
        def value = opParams.filter_value
        if (!col)           error "filter_col is required for the 'filter' op"
        if (value == null)  error "filter_value is required for the 'filter' op"
        def filteredCh = ch.filter { row ->
            def v = row[col]?.toString()
            if (fop == 'eq')       return v == value
            if (fop == 'ne')       return v != value
            if (fop == 'contains') return v?.contains(value)
            error "Unknown filter_op '${fop}' -- expected 'eq', 'ne', or 'contains'"
        }
        return [ filteredCh, cols ]
    }

    if (op == 'merge') {
        def on = opParams.merge_on
        if (!on) error "merge_on is required for the 'merge' op"
        if (!(on in cols))       error "merge_on '${on}' not found in samplesheet1's columns"
        if (!(on in sheet2Cols)) error "merge_on '${on}' not found in samplesheet2's columns"

        def how = opParams.merge_how ?: 'inner'
        def suffixes = splitList(opParams.merge_suffixes ?: '_x,_y')
        if (suffixes.size() != 2) error "merge_suffixes must be exactly two comma-separated values, got '${opParams.merge_suffixes}'"
        def (lSuf, rSuf) = suffixes

        def leftCols  = cols - on
        def rightCols = sheet2Cols - on
        def overlap   = leftCols.intersect(rightCols)

        def leftCh  = ch.map { row -> tuple(row[on], row) }
        def rightCh = channel.fromList(sheet2Rows.collect { row -> tuple(row[on], row) })

        def mergeRow = { l, r ->
            def out = [(on): l[on]]
            leftCols.each  { k -> out[ overlap.contains(k) ? "${k}${lSuf}" : k ] = l[k] }
            rightCols.each { k -> out[ overlap.contains(k) ? "${k}${rSuf}" : k ] = r ? r[k] : '' }
            out
        }

        def mergedCh
        if (how == 'inner') {
            mergedCh = leftCh.join(rightCh).map { key, l, r -> mergeRow.call(l, r) }
        } else if (how == 'left') {
            mergedCh = leftCh.join(rightCh, remainder: true)
                .filter { key, l, r -> l != null }   // drop right-only remainder rows to keep left-join semantics
                .map    { key, l, r -> mergeRow.call(l, r) }
        } else {
            error "Unknown merge_how '${how}' -- expected 'inner' or 'left'"
        }

        def newCols = [on] +
            leftCols.collect  { overlap.contains(it) ? "${it}${lSuf}" : it } +
            rightCols.collect { overlap.contains(it) ? "${it}${rSuf}" : it }
        return [ mergedCh, newCols ]
    }

    if (op == 'concat') {
        def allCols = (cols + sheet2Cols).unique()
        def fillRow = { row -> allCols.collectEntries { c -> [c, row.containsKey(c) ? (row[c] ?: '') : ''] } }
        def rightCh = channel.fromList(sheet2Rows).map(fillRow)
        return [ ch.map(fillRow).mix(rightCh), allCols ]
    }

    error "Unknown op '${op}' -- expected one of: ${supportedOps().join(', ')}"
}

workflow SAMPLESHEET_OPS {
    take:
    samplesheet1
    samplesheet2
    ops
    outdir
    outname
    quote
    merge_on
    merge_how
    merge_suffixes
    drop_columns_cols
    dropna_cols
    drop_duplicates_cols
    filter_col
    filter_op
    filter_value

    main:
    if (!samplesheet1) error "Missing required samplesheet1"
    if (!ops)          error "Missing required ops"
    if (!outdir)       error "Missing required outdir"

    def opsList = splitList(ops)
    def unknown = opsList - supportedOps()
    if (unknown) error "Unknown op(s) in ops: ${unknown.join(', ')} -- expected one of: ${supportedOps().join(', ')}"

    def sheet1Rows = file(samplesheet1, checkIfExists: true)
        .splitCsv(header: true, sep: detectSep(samplesheet1), quote: quote)
    def cols = sheet1Rows ? (sheet1Rows[0].keySet() as List) : []

    print(sheet1Rows)
    print(cols)

    def needsSheet2 = opsList.any { it in ['merge', 'concat'] }
    def sheet2Rows = []
    def sheet2Cols = []
    if (needsSheet2) {
        if (!samplesheet2) error "samplesheet2 is required when ops includes 'merge' or 'concat'"
        sheet2Rows = file(samplesheet2, checkIfExists: true)
            .splitCsv(header: true, sep: detectSep(samplesheet2), quote: quote)
        sheet2Cols = sheet2Rows ? (sheet2Rows[0].keySet() as List) : []
    }

    def opParams = [
        merge_on            : merge_on,
        merge_how           : merge_how,
        merge_suffixes      : merge_suffixes,
        drop_columns_cols   : drop_columns_cols,
        dropna_cols         : dropna_cols,
        drop_duplicates_cols: drop_duplicates_cols,
        filter_col          : filter_col,
        filter_op           : filter_op,
        filter_value        : filter_value,
    ]

    def sheet1Ch = channel.fromList(sheet1Rows)

    def result    = opsList.inject([sheet1Ch, cols]) { acc, op ->
        applyOp(op, acc[0], acc[1], sheet2Rows, sheet2Cols, opParams)
    }
    def finalCh   = result[0]
    def finalCols = result[1]

    def outSep = detectSep(outname)

    def outCh = finalCh
        .collect()
        .ifEmpty([])   // collect() on an empty channel emits nothing at all -- force one [] so the header still gets written
        .map { rows ->
            if (!rows) return finalCols.collect { c -> csvQuote(c, outSep, quote) }.join(outSep) + '\n'
            def header = rows[0].keySet().collect { c -> csvQuote(c, outSep, quote) }.join(outSep)
            def body   = rows.collect { r -> r.values().collect { v -> csvQuote(v, outSep, quote) }.join(outSep) }.join('\n')
            header + '\n' + body + '\n'
        }
        .collectFile(name: outname, storeDir: outdir)

    emit:
    samplesheet = outCh
}

workflow {
    SAMPLESHEET_OPS(
        params.samplesheet1,
        params.samplesheet2,
        params.ops,
        params.outdir,
        params.outname,
        params.quote,
        params.merge_on,
        params.merge_how,
        params.merge_suffixes,
        params.drop_columns_cols,
        params.dropna_cols,
        params.drop_duplicates_cols,
        params.filter_col,
        params.filter_op,
        params.filter_value,
    )
}

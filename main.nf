nextflow.enable.dsl = 2

include { validateParameters; paramsHelp } from 'plugin/nf-schema'

params.help                 = false
params.samplesheet1         = null
params.samplesheet2         = null
params.ops                  = null
params.outdir               = null
params.outname              = 'samplesheet.csv'
params.quote                = '"'
params.drop_header          = false

params.merge_on             = "sample"
params.merge_how            = 'inner'
params.merge_suffixes       = '_x,_y'
params.drop_columns_cols    = null
params.select_columns_cols  = null
params.rename_cols          = null
params.dropna_cols          = null
params.drop_duplicates_cols = null
params.filter_col           = null
params.filter_op            = 'eq'
params.filter_value         = null

def supportedOps() {
    return ['merge', 'drop_columns', 'select_columns', 'rename', 'dropna', 'drop_duplicates', 'filter', 'concat']
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
    return s.toString().split(',')*.trim()
}

def duplicatesOf(list) {
    return list.findAll { x -> list.count(x) > 1 }.unique()
}

// Errors if any of `wanted` isn't a current column. `param` names the offending param
// so a typo fails loudly instead of silently matching nothing (or everything).
def requireColumns(wanted, cols, param) {
    def missing = wanted - cols
    if (missing) error "${param} references unknown column(s): ${missing.join(', ')} -- available columns: ${cols.join(', ')}"
}

// SAMPLESHEET_OPS takes plain values, not channels. Booleans may also arrive as strings
// (e.g. from a config or another samplesheet), so 'false' must not be truthy.
def asBoolean(value, name) {
    if (value == null) return false
    if (value instanceof Boolean) return value
    if (value instanceof CharSequence) {
        def s = value.toString().trim().toLowerCase()
        if (s in ['true', 'yes', '1'])      return true
        if (s in ['false', 'no', '0', '']) return false
    }
    error "${name} must be a boolean (true/false), got '${value}' (${value.getClass().simpleName}) -- SAMPLESHEET_OPS takes plain values, not channels"
}

// Reads a CSV/TSV into [columns, rows]. The header is parsed on its own so that
// (a) a header-only file still yields its column list, and (b) duplicate column
// names are caught -- splitCsv(header: true) would otherwise silently collapse them
// into a single map key and lose data.
def readSheet(path, quote, label) {
    def f   = file(path, checkIfExists: true)
    def sep = detectSep(path)
    def headerRows = f.splitCsv(header: false, sep: sep, quote: quote, limit: 1)
    if (!headerRows) error "${label} '${path}' is empty -- expected at least a header line"
    def cols  = headerRows[0].collect { it == null ? '' : it.toString() }
    def dupes = duplicatesOf(cols)
    if (dupes) error "${label} '${path}' has duplicate column name(s): ${dupes.join(', ')} -- column names must be unique"
    def rows = f.splitCsv(header: true, sep: sep, quote: quote)
    return [cols, rows]
}

// Parses "old=new,old2=new2" into an ordered old->new map. old_key is matched against
// known column names (longest match wins) rather than split on a fixed character, so
// old_key itself may contain '=' -- only new_key's content is taken verbatim after the
// separator, which is why it can contain '=' too without any escaping.
def parseRenameMap(s, cols) {
    def sep = '='
    def map = [:]
    splitList(s).each { pair ->
        def oldKey = cols.findAll { c -> pair.startsWith(c) }.max { it.length() }
        def rest = oldKey ? pair.substring(oldKey.length()).trim() : ''
        if (!oldKey || !rest.startsWith(sep)) {
            error "Invalid rename_cols entry '${pair}' -- expected 'old_key${sep}new_key' where old_key is an existing column name immediately followed by '${sep}'"
        }
        def newKey = rest.substring(1).trim()
        if (!newKey) error "Invalid rename_cols entry '${pair}' -- new_key must not be empty"
        if (map.containsKey(oldKey)) error "rename_cols specifies old column '${oldKey}' more than once"
        map[oldKey] = newKey
    }
    return map
}

// Quotes a single output field if it contains the delimiter, the quote character,
// or a newline -- otherwise CSV/TSV rows silently shift columns whenever a value
// (e.g. a free-text notes field) happens to contain a comma/tab.
def csvQuote(value, sep, quoteChar) {
    def v = value == null ? '' : value.toString()
    if (v.contains(sep) || v.contains(quoteChar) || v.contains('\n') || v.contains('\r')) {
        return quoteChar + v.replace(quoteChar, quoteChar + quoteChar) + quoteChar
    }
    return v
}

// Applies one op to the running channel, returning [newChannel, newColumnList] so
// later ops (and the final header) know the shape without re-inspecting the data.
// opParams bundles the per-op arguments so this stays a pure function of its inputs
// rather than reading the global params object directly.
def applyOp(op, ch, cols, sheet2Rows, sheet2Cols, opParams) {

    if (op == 'drop_columns') {
        def dropCols = splitList(opParams.drop_columns_cols)
        if (!dropCols) error "drop_columns_cols is required for the 'drop_columns' op"
        requireColumns(dropCols, cols, 'drop_columns_cols')
        return [ ch.map { row -> row.findAll { k, v -> !(k in dropCols) } }, cols - dropCols ]
    }

    if (op == 'select_columns') {
        def keepCols = splitList(opParams.select_columns_cols)
        if (!keepCols) error "select_columns_cols is required for the 'select_columns' op"
        requireColumns(keepCols, cols, 'select_columns_cols')
        def repeated = duplicatesOf(keepCols)
        if (repeated) error "select_columns_cols lists column(s) more than once: ${repeated.join(', ')}"
        return [ ch.map { row -> row.subMap(keepCols) }, keepCols ]
    }

    if (op == 'rename') {
        if (!opParams.rename_cols) error "rename_cols is required for the 'rename' op"
        def renameMap = parseRenameMap(opParams.rename_cols, cols)
        def newCols = cols.collect { c -> renameMap.containsKey(c) ? renameMap[c] : c }
        def dupes = duplicatesOf(newCols)
        if (dupes) error "rename_cols produces duplicate column name(s): ${dupes.join(', ')}"
        return [ ch.map { row ->
            row.collectEntries { k, v -> [renameMap.containsKey(k) ? renameMap[k] : k, v] }
        }, newCols ]
    }

    if (op == 'dropna') {
        def naCols = splitList(opParams.dropna_cols) ?: cols
        requireColumns(naCols, cols, 'dropna_cols')
        return [ ch.filter { row -> naCols.every { c -> row[c]?.toString()?.trim() } }, cols ]
    }

    if (op == 'drop_duplicates') {
        def dedupCols = splitList(opParams.drop_duplicates_cols) ?: cols
        requireColumns(dedupCols, cols, 'drop_duplicates_cols')
        // unique() compares the key *list* (no string concatenation, so ('ab','c') and
        // ('a','bc') stay distinct) and streams in arrival order, keeping the first occurrence.
        def dedupedCh = ch.unique { row -> dedupCols.collect { c -> row[c] } }
        return [ dedupedCh, cols ]
    }

    if (op == 'filter') {
        def col   = opParams.filter_col
        def fop   = opParams.filter_op ?: 'eq'
        def value = opParams.filter_value == null ? null : opParams.filter_value.toString()
        if (!col)           error "filter_col is required for the 'filter' op"
        if (value == null)  error "filter_value is required for the 'filter' op"
        if (!(fop in ['eq', 'ne', 'contains'])) error "Unknown filter_op '${fop}' -- expected 'eq', 'ne', or 'contains'"
        requireColumns([col], cols, 'filter_col')
        def filteredCh = ch.filter { row ->
            def v = row[col] == null ? '' : row[col].toString()
            if (fop == 'eq') return v == value
            if (fop == 'ne') return v != value
            return v.contains(value)
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

        if (!(how in ['inner', 'left'])) error "Unknown merge_how '${how}' -- expected 'inner' or 'left'"

        // .toString(): GString keys would not match String lookups when writing the output.
        def leftName  = { k -> (overlap.contains(k) ? "${k}${lSuf}" : k).toString() }
        def rightName = { k -> (overlap.contains(k) ? "${k}${rSuf}" : k).toString() }
        def newCols   = [on] + leftCols.collect(leftName) + rightCols.collect(rightName)
        def clashes   = duplicatesOf(newCols)
        if (clashes) error "merge would produce duplicate column name(s): ${clashes.join(', ')} -- choose different merge_suffixes or rename/drop the clashing columns first"

        // samplesheet2 is already fully in memory, so index it by key and look matches up
        // per left row. Unlike channel join() (which pairs one item per key), this handles
        // repeated keys on either side -- every left row gets every matching right row --
        // and keeps the left sheet's row order.
        def rightIndex = sheet2Rows.groupBy { row -> row[on] }
        def mergeRow = { l, r ->
            def out = [(on): l[on]]
            leftCols.each  { k -> out[leftName.call(k)]  = l[k] }
            rightCols.each { k -> out[rightName.call(k)] = r ? r[k] : '' }
            out
        }
        def mergedCh = ch.flatMap { l ->
            def matches = rightIndex[l[on]] ?: []
            if (!matches && how == 'left') return [mergeRow.call(l, null)]
            return matches.collect { r -> mergeRow.call(l, r) }
        }
        return [ mergedCh, newCols ]
    }

    if (op == 'concat') {
        def allCols = (cols + sheet2Cols).unique()
        def fillRow = { row -> allCols.collectEntries { c -> [c, row.containsKey(c) ? (row[c] ?: '') : ''] } }
        def rightCh = channel.fromList(sheet2Rows).map(fillRow)
        // concat (not mix) so samplesheet1's rows always come before samplesheet2's
        return [ ch.map(fillRow).concat(rightCh), allCols ]
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
    drop_header
    merge_on
    merge_how
    merge_suffixes
    drop_columns_cols
    select_columns_cols
    rename_cols
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
    def repeatedOps = duplicatesOf(opsList)
    if (repeatedOps) error "ops lists op(s) more than once: ${repeatedOps.join(', ')} -- each op may appear only once per run"

    def dropHeader = asBoolean(drop_header, 'drop_header')
    def outSep     = detectSep(outname)   // validate outname before doing any work

    def (cols, sheet1Rows) = readSheet(samplesheet1, quote, 'samplesheet1')

    def needsSheet2 = opsList.any { it in ['merge', 'concat'] }
    def sheet2Rows = []
    def sheet2Cols = []
    if (needsSheet2) {
        if (!samplesheet2) error "samplesheet2 is required when ops includes 'merge' or 'concat'"
        (sheet2Cols, sheet2Rows) = readSheet(samplesheet2, quote, 'samplesheet2')
    }

    def opParams = [
        merge_on            : merge_on,
        merge_how           : merge_how,
        merge_suffixes      : merge_suffixes,
        drop_columns_cols   : drop_columns_cols,
        select_columns_cols : select_columns_cols,
        rename_cols         : rename_cols,
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

    def outCh = finalCh
        .collect()
        .ifEmpty([])   // collect() on an empty channel emits nothing at all -- force one [] so the header still gets written
        .map { rows ->
            def headerLine = dropHeader ? '' : finalCols.collect { c -> csvQuote(c, outSep, quote) }.join(outSep) + '\n'
            if (!rows) return headerLine
            // Look values up by column name so the body always lines up with the header,
            // regardless of each row map's internal key order.
            def body = rows.collect { r -> finalCols.collect { c -> csvQuote(r[c], outSep, quote) }.join(outSep) }.join('\n')
            headerLine + body + '\n'
        }
        .collectFile(name: outname, storeDir: outdir)

    emit:
    samplesheet = outCh
}

workflow {
    if (params.help) {
        log.info paramsHelp(command: "nextflow run main.nf --samplesheet1 <path> --ops <ops> --outdir <dir>")
        exit 0
    }
    validateParameters()

    SAMPLESHEET_OPS(
        params.samplesheet1,
        params.samplesheet2,
        params.ops,
        params.outdir,
        params.outname,
        params.quote,
        params.drop_header,
        params.merge_on,
        params.merge_how,
        params.merge_suffixes,
        params.drop_columns_cols,
        params.select_columns_cols,
        params.rename_cols,
        params.dropna_cols,
        params.drop_duplicates_cols,
        params.filter_col,
        params.filter_op,
        params.filter_value,
    )
}

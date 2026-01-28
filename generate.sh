#!/usr/bin/env bash
set -euo pipefail

VERBOSE=0

### Resources setup

WORK=$(mktemp -d)
LOG_FILE=$(mktemp)
PIDS=()

# Ensure that it's deleted even if crashes
trap 'rm -rf "$LOG_FILE" "$WORK"' EXIT

### Constants

OUTPUT="dist/resume.pdf"
TEX_TEMPLATE="resume.tmpl.tex"

### Smart logging

log() {
    if [[ $VERBOSE == 1 ]]; then
        echo "$*" >&2
    else
        echo "$*" >>"$LOG_FILE"
    fi
}

log::pipe() {
    if [[ $VERBOSE == 1 ]]; then
        cat >&2 # redirect stdin to stderr
    else
        cat >>"$LOG_FILE"
    fi
}

log::flush() {
    cat "$LOG_FILE" >&2
}

### Resume generation

# generate_async input.json output.pdf
generate_async() {
    generate "$1" "$2" &
    PIDS+=($!)
}

# generate input.json output.pdf
generate() {
    local input="$1"
    local output="$2"
    local outputName="${output%.*}"

    # Enforce reproducible builds.
    # See https://reproducible-builds.org/docs/source-date-epoch/.
    export SOURCE_DATE_EPOCH=0

    if ! gomplate \
        -c .="$input" \
        -o "$outputName.tex" \
        -f "$TEX_TEMPLATE" \
        --left-delim '<' --right-delim '>'; then
        return 1
    fi

    tectonic -c minimal "$outputName.tex" |& log::pipe
    status=$?

    rm "$outputName.tex"
    return $status
}

main() {
    while (($# > 0)); do
        case "${1:-''}" in
            "-v" | "--verbose")
                VERBOSE=1
                shift
                ;;
            "-o" | "--output")
                OUTPUT="$2"
                shift 2
                ;;
            *)
                log "Error: unknown option $1" >&2
                return 1
                ;;
        esac
    done

    outputBase="${OUTPUT%.*}"
    outputFile="${outputBase}.pdf"
    outputSecretFile="${outputBase}.secret.pdf"

    if ! jq . resume.json >/dev/null 2>&1; then
        log "Error: resume.json is not a valid JSON file" >&2
        return 1
    fi

    generate_async resume.json "$outputFile"

    if jq -s '.[0] * .[1]' \
        resume.json \
        resume.secret.json \
        1>"$WORK/resume.secret.json" \
        2>/dev/null; then
        generate_async "$WORK/resume.secret.json" "$outputSecretFile"
    fi

    # Wait for each PID individually. This allows the status code to be
    # propagated correctly.
    local status=0
    for pid in "${PIDS[@]}"; do
        wait "$pid" || status=$?
    done

    # Ensure that all background processes have finished separately before
    # returning.
    wait

    return $status
}

if ! main "$@"; then
    log "Error: failed to generate resume"
    log "Working directory: $WORK"
    log::flush
    exit 1
fi

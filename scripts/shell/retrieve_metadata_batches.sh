#!/bin/bash
#===============================================================================
# Salesforce Metadata Batch Retriever (Bash 3+ Compatible)
#===============================================================================
# Description : Splits a package.xml into smaller batches and retrieves each
#               batch independently. Useful when full retrieves time out or
#               hit governor limits on large orgs.
# Usage       : ./retrieve_metadata_batches.sh [OPTIONS]
# Example     : ./retrieve_metadata_batches.sh -m manifest/package.xml -b 3
#===============================================================================

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Color codes
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────────────────────
PACKAGE_XML="manifest/full_Package.xml"
BATCH_SIZE=3
TARGET_ORG="my-trail-dev-org"
WAIT_TIME=30
MAX_RETRIES=2
TEMP_DIR="./temp_manifests"
KEEP_TEMP=false
DRY_RUN=false
API_VERSION=""

# ─────────────────────────────────────────────────────────────────────────────
# Parallel indexed arrays (bash 3 safe — no associative arrays)
#
# TYPE_NAMES[i]   = metadata type name (e.g. "ApexClass")
# TYPE_MEMBERS[i] = XML member block for that type
# ─────────────────────────────────────────────────────────────────────────────
TYPE_NAMES=()
TYPE_MEMBERS=()
TOTAL_TYPES=0
TOTAL_BATCHES=0

# Tracking
FAILED_BATCHES=()
FAILED_BATCH_TYPES=()
SUCCEEDED_COUNT=0
FAILED_COUNT=0

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       ${BOLD}Salesforce Metadata Batch Retriever${NC}${CYAN}                     ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

log_info()    { echo -e "${CYAN}[INFO]${NC}    $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }

log_step() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Usage
# ─────────────────────────────────────────────────────────────────────────────
show_usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -m, --manifest <path>         Path to package.xml"
    echo "                                (default: manifest/package.xml)"
    echo "  -b, --batch-size <number>     Metadata types per batch (1-20)"
    echo "                                (default: 3)"
    echo "  -o, --target-org <alias>      Target org username or alias"
    echo "                                (default: default connected org)"
    echo "  -w, --wait <minutes>          Wait time per retrieve in minutes"
    echo "                                (default: 30)"
    echo "  -r, --retries <count>         Max retries for failed batches (0-5)"
    echo "                                (default: 2)"
    echo "  -k, --keep-temp               Keep temp manifest files after run"
    echo "  -d, --dry-run                 Preview batches without retrieving"
    echo "  -h, --help                    Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 -m manifest/package.xml -b 5"
    echo "  $0 -o my-sandbox -b 3 -r 3 -w 45"
    echo "  $0 --dry-run --batch-size 4       # Preview batch split only"
    echo ""
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────────────────────
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -m|--manifest)
                PACKAGE_XML="$2"; shift 2 ;;
            -b|--batch-size)
                BATCH_SIZE="$2"; shift 2 ;;
            -o|--target-org)
                TARGET_ORG="$2"; shift 2 ;;
            -w|--wait)
                WAIT_TIME="$2"; shift 2 ;;
            -r|--retries)
                MAX_RETRIES="$2"; shift 2 ;;
            -k|--keep-temp)
                KEEP_TEMP=true; shift ;;
            -d|--dry-run)
                DRY_RUN=true; shift ;;
            -h|--help)
                show_usage ;;
            *)
                log_error "Unknown option: $1"
                show_usage ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────────
validate_inputs() {
    log_step "Validating inputs"

    # Check sf CLI
    if ! command -v sf > /dev/null 2>&1; then
        log_error "Salesforce CLI (sf) is not installed."
        log_info  "Install it: npm install -g @salesforce/cli"
        exit 1
    fi
    log_success "Salesforce CLI found"

    # Check package.xml exists
    if [ ! -f "$PACKAGE_XML" ]; then
        log_error "Package.xml not found: $PACKAGE_XML"
        exit 1
    fi
    log_success "Manifest found: $PACKAGE_XML"

    # Validate batch size (1-20) — case/pattern match is bash 3 safe
    case "$BATCH_SIZE" in
        [1-9]|1[0-9]|20) ;;
        *)
            log_error "Batch size must be between 1 and 20. Got: $BATCH_SIZE"
            exit 1
            ;;
    esac

    # Validate retries (0-5)
    case "$MAX_RETRIES" in
        [0-5]) ;;
        *)
            log_error "Retries must be between 0 and 5. Got: $MAX_RETRIES"
            exit 1
            ;;
    esac

    # Extract API version — sed only, no grep -P
    API_VERSION=$(grep '<version>' "$PACKAGE_XML" | sed 's/.*<version>//;s/<\/version>.*//' | head -1 | tr -d '[:space:]')
    if [ -z "$API_VERSION" ]; then
        log_error "Could not extract API version from package.xml"
        exit 1
    fi
    log_success "API version: $API_VERSION"

    # Target org info
    if [ -z "$TARGET_ORG" ]; then
        log_info "Target org: default connected org"
    else
        log_info "Target org: $TARGET_ORG"
    fi

    log_info "Batch size: $BATCH_SIZE types per batch"
    log_info "Retries: $MAX_RETRIES per failed batch"

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN mode — no actual retrieves will happen"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse package.xml into parallel arrays
#
# Bash 3 compatible:
#   - No associative arrays (declare -A)
#   - No [[ ... =~ regex ]]
#   - No grep -P (perl regex)
#   - Uses case/esac for pattern matching
#   - Uses sed for string extraction
# ─────────────────────────────────────────────────────────────────────────────
parse_package_xml() {
    log_step "Parsing package.xml"

    local in_types=false
    local current_members=""
    local current_name=""

    while IFS= read -r line; do
        # Trim whitespace with sed
        local trimmed
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Detect <types> open
        case "$trimmed" in
            "<types>"*|"<types />")
                in_types=true
                current_members=""
                current_name=""
                continue
                ;;
        esac

        # Detect </types> close — store what we collected
        case "$trimmed" in
            "</types>"*)
                if [ -n "$current_name" ] && [ "$current_name" != "$API_VERSION" ]; then
                    TYPE_NAMES+=("$current_name")
                    TYPE_MEMBERS+=("$current_members")
                fi
                in_types=false
                continue
                ;;
        esac

        if [ "$in_types" = true ]; then
            # Capture <members>...</members> lines
            case "$trimmed" in
                *"<members>"*"</members>"*)
                    if [ -z "$current_members" ]; then
                        current_members="        ${trimmed}"
                    else
                        current_members="${current_members}
        ${trimmed}"
                    fi
                    ;;
            esac

            # Capture <name>...</name> line
            case "$trimmed" in
                *"<name>"*"</name>"*)
                    current_name=$(echo "$trimmed" | sed 's/.*<name>//;s/<\/name>.*//')
                    ;;
            esac
        fi
    done < "$PACKAGE_XML"

    # Sort the parallel arrays alphabetically by type name
    # Write index-name pairs to a temp string, sort, rebuild arrays
    local sort_input=""
    local i=0
    while [ $i -lt ${#TYPE_NAMES[@]} ]; do
        sort_input="${sort_input}${i}	${TYPE_NAMES[$i]}
"
        i=$((i + 1))
    done

    local sorted_indices
    sorted_indices=$(echo "$sort_input" | sort -t'	' -k2,2 | cut -f1)

    local sorted_names=()
    local sorted_members=()
    for idx in $sorted_indices; do
        sorted_names+=("${TYPE_NAMES[$idx]}")
        sorted_members+=("${TYPE_MEMBERS[$idx]}")
    done

    TYPE_NAMES=("${sorted_names[@]}")
    TYPE_MEMBERS=("${sorted_members[@]}")

    TOTAL_TYPES=${#TYPE_NAMES[@]}
    TOTAL_BATCHES=$(( (TOTAL_TYPES + BATCH_SIZE - 1) / BATCH_SIZE ))

    log_success "Found $TOTAL_TYPES metadata types across $TOTAL_BATCHES batches"
    echo ""

    # List all types with member counts
    i=0
    while [ $i -lt $TOTAL_TYPES ]; do
        local member_count=0
        if [ -n "${TYPE_MEMBERS[$i]}" ]; then
            member_count=$(echo "${TYPE_MEMBERS[$i]}" | grep -c "<members>" || true)
        fi
        printf "  ${CYAN}%3d.${NC} %-40s (%s members)\n" "$((i + 1))" "${TYPE_NAMES[$i]}" "$member_count"
        i=$((i + 1))
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Generate a temporary package.xml for a batch of types
# ─────────────────────────────────────────────────────────────────────────────
create_batch_manifest() {
    local batch_num=$1
    shift
    local type_indices="$@"
    local manifest_path="${TEMP_DIR}/batch_${batch_num}_package.xml"

    cat > "$manifest_path" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
EOF

    local idx
    for idx in $type_indices; do
        local type_name="${TYPE_NAMES[$idx]}"
        local members="${TYPE_MEMBERS[$idx]}"

        echo "    <types>" >> "$manifest_path"
        if [ -n "$members" ]; then
            echo "$members" >> "$manifest_path"
        fi
        echo "        <name>${type_name}</name>" >> "$manifest_path"
        echo "    </types>" >> "$manifest_path"
    done

    cat >> "$manifest_path" <<EOF
    <version>${API_VERSION}</version>
</Package>
EOF

    echo "$manifest_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Retrieve a single batch with retry logic
# ─────────────────────────────────────────────────────────────────────────────
retrieve_batch() {
    local batch_num=$1
    local manifest_path=$2
    local type_list=$3

    log_info "Types: ${type_list}"
    log_info "Manifest: ${manifest_path}"

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN — skipping actual retrieve"
        SUCCEEDED_COUNT=$((SUCCEEDED_COUNT + 1))
        return 0
    fi

    # Build retrieve command
    local cmd="sf project retrieve start"
    cmd="${cmd} --manifest \"${manifest_path}\""
    cmd="${cmd} --wait ${WAIT_TIME}"

    if [ -n "$TARGET_ORG" ]; then
        cmd="${cmd} --target-org \"${TARGET_ORG}\""
    fi

    # Attempt retrieve with retries
    local attempt=1
    local max_attempts=$((MAX_RETRIES + 1))

    while [ $attempt -le $max_attempts ]; do
        if [ $attempt -gt 1 ]; then
            local wait_secs=$((attempt * 5))
            log_warn "Retry $((attempt - 1))/$MAX_RETRIES — waiting ${wait_secs}s before retry..."
            sleep "$wait_secs"
        fi

        log_info "Attempt ${attempt}/${max_attempts}..."

        if eval "$cmd" 2>&1; then
            log_success "Batch ${batch_num} retrieved successfully"
            SUCCEEDED_COUNT=$((SUCCEEDED_COUNT + 1))
            return 0
        else
            log_warn "Attempt ${attempt} failed for batch ${batch_num}"
        fi

        attempt=$((attempt + 1))
    done

    log_error "Batch ${batch_num} failed after ${max_attempts} attempts"
    FAILED_BATCHES+=("$batch_num")
    FAILED_BATCH_TYPES+=("$type_list")
    FAILED_COUNT=$((FAILED_COUNT + 1))
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Process all batches
# ─────────────────────────────────────────────────────────────────────────────
process_batches() {
    log_step "Retrieving metadata in batches of ${BATCH_SIZE}"

    mkdir -p "$TEMP_DIR"

    local batch_num=1
    local current_index=0

    while [ $current_index -lt $TOTAL_TYPES ]; do
        # Collect indices and names for this batch
        local batch_indices=""
        local batch_type_names=""
        local count=0

        while [ $count -lt $BATCH_SIZE ] && [ $current_index -lt $TOTAL_TYPES ]; do
            if [ -z "$batch_indices" ]; then
                batch_indices="$current_index"
                batch_type_names="${TYPE_NAMES[$current_index]}"
            else
                batch_indices="${batch_indices} ${current_index}"
                batch_type_names="${batch_type_names}, ${TYPE_NAMES[$current_index]}"
            fi
            current_index=$((current_index + 1))
            count=$((count + 1))
        done

        echo ""
        echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│  ${BOLD}Batch ${batch_num} of ${TOTAL_BATCHES}${NC}${CYAN}  (types $((current_index - count + 1))-${current_index} of ${TOTAL_TYPES})${NC}"
        echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"

        # Generate batch manifest
        local manifest_path
        manifest_path=$(create_batch_manifest "$batch_num" $batch_indices)

        # Retrieve (don't exit on failure — continue to next batch)
        retrieve_batch "$batch_num" "$manifest_path" "$batch_type_names" || true

        batch_num=$((batch_num + 1))
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup temp files
# ─────────────────────────────────────────────────────────────────────────────
cleanup() {
    if [ "$KEEP_TEMP" = true ]; then
        log_info "Keeping temp manifests in: ${TEMP_DIR}/"
        return 0
    fi

    if [ ${#FAILED_BATCHES[@]} -gt 0 ]; then
        log_warn "Keeping temp manifests because some batches failed."
        log_info "Temp files in: ${TEMP_DIR}/"
        log_info "To clean up manually: rm -rf ${TEMP_DIR}"
        return 0
    fi

    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log_info "Temp manifests cleaned up."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Print summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    if [ "$FAILED_COUNT" -eq 0 ]; then
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              ${BOLD}All batches retrieved successfully!${NC}${GREEN}              ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║              ${BOLD}Some batches failed!${NC}${RED}                            ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}Summary${NC}"
    echo -e "  ─────────────────────────────────────"
    echo -e "  Total metadata types : ${TOTAL_TYPES}"
    echo -e "  Total batches        : ${TOTAL_BATCHES}"
    echo -e "  Succeeded            : ${GREEN}${SUCCEEDED_COUNT}${NC}"
    echo -e "  Failed               : ${RED}${FAILED_COUNT}${NC}"
    echo -e "  Batch size           : ${BATCH_SIZE} types"
    echo -e "  API version          : ${API_VERSION}"
    echo ""

    # List failed batches with their types
    if [ "$FAILED_COUNT" -gt 0 ]; then
        echo -e "  ${RED}${BOLD}Failed batches:${NC}"
        echo -e "  ─────────────────────────────────────"
        local i=0
        while [ $i -lt ${#FAILED_BATCHES[@]} ]; do
            echo -e "  ${RED}Batch ${FAILED_BATCHES[$i]}:${NC} ${FAILED_BATCH_TYPES[$i]}"
            i=$((i + 1))
        done
        echo ""
        echo -e "  ${YELLOW}Retry failed batches manually:${NC}"
        i=0
        while [ $i -lt ${#FAILED_BATCHES[@]} ]; do
            local bnum="${FAILED_BATCHES[$i]}"
            local org_flag=""
            if [ -n "$TARGET_ORG" ]; then
                org_flag=" --target-org \"${TARGET_ORG}\""
            fi
            echo -e "    sf project retrieve start --manifest \"${TEMP_DIR}/batch_${bnum}_package.xml\" --wait ${WAIT_TIME}${org_flag}"
            i=$((i + 1))
        done
        echo ""
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    print_banner
    parse_arguments "$@"
    validate_inputs
    parse_package_xml
    process_batches

    local elapsed=$SECONDS
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    cleanup
    print_summary

    log_info "Total time: ${mins}m ${secs}s"

    # Exit with error code if any batch failed
    if [ "$FAILED_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
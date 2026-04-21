#!/bin/bash
#===============================================================================
# Salesforce Scratch Org Setup Script
#===============================================================================
# Description : Automates scratch org creation, source push, permission
#               assignment, password reset, and org launch.
# Usage       : sh ./setup-scratch-org.sh [options]
# Example     : sh ./setup-scratch-org.sh -a MyScratchOrg -d 14 -p MyPermSet
#===============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Color codes for output
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────────────────────
# Default values
# ─────────────────────────────────────────────────────────────────────────────
DEV_HUB_USERNAME="MAIN_ORG"           # Empty = use default connected org
SCRATCH_ORG_ALIAS=""          # Alias for the new scratch org
SCRATCH_ORG_DURATION=7        # Days until scratch org expires
PERMISSION_SETS="Example_permissionset Stripe_Object_Permissions"            # Comma-separated permission sets / perm set groups
DEFINITION_FILE="config/project-scratch-def.json"  # Scratch org definition file
SKIP_PUSH=false               # Skip source push if true
OPEN_ORG=true                 # Open org in browser after setup

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       ${BOLD}Salesforce Scratch Org Setup Script${NC}${CYAN}                    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

log_info() {
    echo -e "${CYAN}[INFO]${NC}    $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC}    $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC}   $1"
}

log_step() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  STEP $1: $2${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Usage / Help
# ─────────────────────────────────────────────────────────────────────────────
show_usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -v, --devhub <username|alias>     Dev Hub username or alias"
    echo "                                    (default: default connected org)"
    echo "  -a, --alias <alias>               Alias for the new scratch org"
    echo "                                    (default: auto-generated)"
    echo "  -d, --duration <days>             Scratch org duration in days (1-30)"
    echo "                                    (default: 7)"
    echo "  -p, --permsets <name1,name2,...>   Comma-separated permission set or"
    echo "                                    permission set group API names"
    echo "  -f, --definition <file>           Path to scratch org definition JSON"
    echo "                                    (default: config/project-scratch-def.json)"
    echo "  -s, --skip-push                   Skip source push step"
    echo "  -n, --no-open                     Don't open org in browser after setup"
    echo "  -h, --help                        Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 -a MyScratchOrg -d 14 -p Admin_PermSet"
    echo "  $0 -v mydevhub@org.com -a QA_Org -p \"PS_Admin,PSG_Support\""
    echo "  $0 --alias TestOrg --duration 3 --skip-push"
    echo ""
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse command-line arguments
# ─────────────────────────────────────────────────────────────────────────────
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--devhub)
                DEV_HUB_USERNAME="$2"
                shift 2
                ;;
            -a|--alias)
                SCRATCH_ORG_ALIAS="$2"
                shift 2
                ;;
            -d|--duration)
                SCRATCH_ORG_DURATION="$2"
                shift 2
                ;;
            -p|--permsets)
                PERMISSION_SETS="$2"
                shift 2
                ;;
            -f|--definition)
                DEFINITION_FILE="$2"
                shift 2
                ;;
            -s|--skip-push)
                SKIP_PUSH=true
                shift
                ;;
            -n|--no-open)
                OPEN_ORG=false
                shift
                ;;
            -h|--help)
                show_usage
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────────
validate_inputs() {
    log_step "0" "Validating inputs and prerequisites"

    # Check if sf CLI is installed
    if ! command -v sf &> /dev/null; then
        log_error "Salesforce CLI (sf) is not installed."
        log_info  "Install it: npm install -g @salesforce/cli"
        exit 1
    fi
    log_success "Salesforce CLI found: $(sf --version | head -1)"

    # Validate duration is between 1 and 30
    if ! [[ "$SCRATCH_ORG_DURATION" =~ ^[0-9]+$ ]] || \
       [ "$SCRATCH_ORG_DURATION" -lt 1 ] || \
       [ "$SCRATCH_ORG_DURATION" -gt 30 ]; then
        log_error "Duration must be a number between 1 and 30. Got: $SCRATCH_ORG_DURATION"
        exit 1
    fi
    log_success "Scratch org duration: ${SCRATCH_ORG_DURATION} days"

    # Validate scratch org definition file exists
    if [ ! -f "$DEFINITION_FILE" ]; then
        log_error "Scratch org definition file not found: $DEFINITION_FILE"
        log_info  "Create one or specify a path with -f option."
        exit 1
    fi
    log_success "Definition file found: $DEFINITION_FILE"

    # If no alias provided, generate one
    if [ -z "$SCRATCH_ORG_ALIAS" ]; then
        SCRATCH_ORG_ALIAS="scratch-$(date +%Y%m%d-%H%M%S)"
        log_warn "No alias provided. Auto-generated: $SCRATCH_ORG_ALIAS"
    fi

    # Log Dev Hub info
    if [ -z "$DEV_HUB_USERNAME" ]; then
        log_info "Dev Hub: Using default connected org"
    else
        log_info "Dev Hub: $DEV_HUB_USERNAME"
    fi

    # Log permission sets
    if [ -z "$PERMISSION_SETS" ]; then
        log_warn "No permission sets specified. Skipping assignment step."
    else
        log_info "Permission sets to assign: $PERMISSION_SETS"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Create Scratch Org
# ─────────────────────────────────────────────────────────────────────────────
create_scratch_org() {
    log_step "1" "Creating scratch org"

    local cmd="sf org create scratch"
    cmd+=" --definition-file \"$DEFINITION_FILE\""
    cmd+=" --alias \"$SCRATCH_ORG_ALIAS\""
    cmd+=" --duration-days $SCRATCH_ORG_DURATION"
    cmd+=" --set-default"
    cmd+=" --wait 10"
    cmd+=" --json"

    # Append Dev Hub flag only if a username/alias was provided
    if [ -n "$DEV_HUB_USERNAME" ]; then
        cmd+=" --target-dev-hub \"$DEV_HUB_USERNAME\""
    fi

    log_info "Running: $cmd"
    echo ""

    local result
    if ! result=$(eval "$cmd" 2>&1); then
        log_error "Failed to create scratch org."
        echo "$result" | python3 -m json.tool 2>/dev/null || echo "$result"
        exit 1
    fi

    # Extract the username from JSON response
    SCRATCH_ORG_USERNAME=$(echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('result', {}).get('username', 'UNKNOWN'))
" 2>/dev/null || echo "UNKNOWN")

    log_success "Scratch org created successfully!"
    log_info    "Alias    : $SCRATCH_ORG_ALIAS"
    log_info    "Username : $SCRATCH_ORG_USERNAME"
    log_info    "Expires  : in $SCRATCH_ORG_DURATION days"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Push Source Code
# ─────────────────────────────────────────────────────────────────────────────
push_source() {
    if [ "$SKIP_PUSH" = true ]; then
        log_step "2" "Pushing source code (SKIPPED)"
        log_warn "Source push skipped via --skip-push flag."
        return 0
    fi

    log_step "2" "Pushing source code to scratch org"

    local cmd="sf project deploy start"
    cmd+=" --target-org \"$SCRATCH_ORG_ALIAS\""
    cmd+=" --wait 30"

    log_info "Running: $cmd"
    echo ""

    if ! eval "$cmd"; then
        log_error "Source push failed!"
        log_warn  "You can retry manually: $cmd"
        log_warn  "Continuing with remaining steps..."
    else
        log_success "Source code pushed successfully!"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Assign Permission Sets / Permission Set Groups
# ─────────────────────────────────────────────────────────────────────────────
assign_permissions() {
    log_step "3" "Assigning permission sets"

    if [ -z "$PERMISSION_SETS" ]; then
        log_warn "No permission sets to assign. Skipping."
        return 0
    fi

    # Split comma-separated permission sets and trim whitespace
    IFS=',' read -ra PERM_ARRAY <<< "$PERMISSION_SETS"

    local success_count=0
    local fail_count=0

    for perm in "${PERM_ARRAY[@]}"; do
        # Trim whitespace
        perm=$(echo "$perm" | xargs)

        if [ -z "$perm" ]; then
            continue
        fi

        log_info "Assigning: $perm"

        local cmd="sf org assign permset"
        cmd+=" --name \"$perm\""
        cmd+=" --target-org \"$SCRATCH_ORG_ALIAS\""

        if eval "$cmd" 2>&1; then
            log_success "Assigned: $perm"
            ((success_count++))
        else
            log_warn "Failed to assign '$perm' as Permission Set. Trying as Permission Set Group..."

            # Retry as Permission Set Group
            local cmd_psg="sf org assign permsetlicense"
            cmd_psg+=" --name \"$perm\""
            cmd_psg+=" --target-org \"$SCRATCH_ORG_ALIAS\""

            if eval "$cmd_psg" 2>&1; then
                log_success "Assigned (as PSG): $perm"
                ((success_count++))
            else
                log_error "Could not assign '$perm' as Permission Set or Permission Set Group."
                ((fail_count++))
            fi
        fi
    done

    echo ""
    log_info "Permission assignment summary: ${success_count} succeeded, ${fail_count} failed"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Reset User Password
# ─────────────────────────────────────────────────────────────────────────────
reset_password() {
    log_step "4" "Generating user password"

    local cmd="sf org generate password"
    cmd+=" --target-org \"$SCRATCH_ORG_ALIAS\""

    log_info "Running: $cmd"
    echo ""

    local result
    if result=$(eval "$cmd" 2>&1); then
        log_success "Password generated successfully!"
        echo ""
        echo -e "${YELLOW}┌──────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  ${BOLD}Credentials (save these!)${NC}${YELLOW}                                │${NC}"
        echo -e "${YELLOW}├──────────────────────────────────────────────────────────┤${NC}"
        echo "$result" | while IFS= read -r line; do
            printf "${YELLOW}│${NC}  %-56s ${YELLOW}│${NC}\n" "$line"
        done
        echo -e "${YELLOW}└──────────────────────────────────────────────────────────┘${NC}"
        echo ""
    else
        log_warn "Password generation returned a warning (may already be set)."
        echo "$result"
    fi

    # Also display org info for reference
    log_info "Full org details:"
    sf org display --target-org "$SCRATCH_ORG_ALIAS" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Open the Org
# ─────────────────────────────────────────────────────────────────────────────
open_org() {
    log_step "5" "Opening scratch org in browser"

    if [ "$OPEN_ORG" = false ]; then
        log_warn "Org open skipped via --no-open flag."
        log_info "Open manually: sf org open --target-org \"$SCRATCH_ORG_ALIAS\""
        return 0
    fi

    local cmd="sf org open --target-org \"$SCRATCH_ORG_ALIAS\""

    log_info "Running: $cmd"

    if eval "$cmd" 2>&1; then
        log_success "Org opened in browser!"
    else
        log_warn "Could not open org automatically."
        log_info "Open manually: $cmd"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ${BOLD}Setup Complete!${NC}${GREEN}                            ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf  "${GREEN}║${NC}  Org Alias    : %-41s ${GREEN}║${NC}\n" "$SCRATCH_ORG_ALIAS"
    printf  "${GREEN}║${NC}  Username     : %-41s ${GREEN}║${NC}\n" "${SCRATCH_ORG_USERNAME:-N/A}"
    printf  "${GREEN}║${NC}  Duration     : %-41s ${GREEN}║${NC}\n" "$SCRATCH_ORG_DURATION days"
    printf  "${GREEN}║${NC}  Perm Sets    : %-41s ${GREEN}║${NC}\n" "${PERMISSION_SETS:-None}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Useful Commands:${NC}                                           ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Open org   : sf org open -o $SCRATCH_ORG_ALIAS            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Push code  : sf project deploy start -o $SCRATCH_ORG_ALIAS ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Delete org : sf org delete scratch -o $SCRATCH_ORG_ALIAS   ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Main execution
# ─────────────────────────────────────────────────────────────────────────────
main() {
    print_banner
    parse_arguments "$@"
    validate_inputs

    local start_time=$SECONDS

    create_scratch_org
    push_source
    assign_permissions
    reset_password
    open_org

    local elapsed=$(( SECONDS - start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))

    print_summary
    log_info "Total time: ${mins}m ${secs}s"
}

# Run
main "$@"
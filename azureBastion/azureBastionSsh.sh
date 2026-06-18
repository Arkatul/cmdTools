#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

USERNAME=""
SSH_KEY=""
VM_NAME=""
RESOURCE_GROUP=""
DRY_RUN=0
SKIP_HISTORY=0
USE_HISTORY=0
HISTORY_FILE="${HOME}/.azurebastion"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME -u USERNAME -s SSH_KEY -v VM_NAME [-g RESOURCE_GROUP]

Connect to an Azure VM through Azure Bastion using Azure CLI.

Required options:
  -u, --username        SSH username for the VM
  -s, --ssh-key         Path to the SSH private key
  -v, --vmname          Name of the target VM

Optional options:
  -g, --resource-group  Resource group of the VM
      --dry-run         Print the az command without executing it
      --no-history      Ignore history and resolve VM/Bastion from Azure
  -h, --help            Show this help and exit

Examples:
  $SCRIPT_NAME -u dbas -s ~/.ssh/id_ed25519 -v slictprdjhic1
  $SCRIPT_NAME -u dbas -s ~/.ssh/id_ed25519 -v slictprdjhic1 -g my-resource-group
EOF
}

err() {
    printf "Error: %s\n" "$*" >&2
}

expand_path() {
    local path="$1"

    case "$path" in
        "~")
            printf "%s\n" "$HOME"
            ;;
        "~/"*)
            printf "%s/%s\n" "$HOME" "${path#~/}"
            ;;
        *)
            printf "%s\n" "$path"
            ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        err "Required command not found: $1"
        exit 1
    }
}

prompt_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local i choice

    printf "%s\n" "$prompt" >&2
    for i in "${!options[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${options[$i]}" >&2
    done

    while true; do
        read -r -p "Enter number (1-${#options[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            printf "%s\n" "${options[$((choice - 1))]}"
            return 0
        fi
        printf "Invalid choice.\n" >&2
    done
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--username)
                [[ $# -ge 2 ]] || {
                    err "Missing value for $1"
                    usage
                    exit 1
                }
                USERNAME="$2"
                shift 2
                ;;
            -s|--ssh-key)
                [[ $# -ge 2 ]] || {
                    err "Missing value for $1"
                    usage
                    exit 1
                }
                SSH_KEY="$2"
                shift 2
                ;;
            -v|--vmname)
                [[ $# -ge 2 ]] || {
                    err "Missing value for $1"
                    usage
                    exit 1
                }
                VM_NAME="$2"
                shift 2
                ;;
            -g|--resource-group)
                [[ $# -ge 2 ]] || {
                    err "Missing value for $1"
                    usage
                    exit 1
                }
                RESOURCE_GROUP="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --no-history)
                SKIP_HISTORY=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                err "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$USERNAME" || -z "$VM_NAME" ]]; then
        err "Missing required options."
        usage
        exit 1
    fi
}

try_history() {
    (( SKIP_HISTORY )) && return 1
    [[ -f "$HISTORY_FILE" ]] || return 1

    local h_vm_name h_vm_rg h_vm_loc h_vm_id h_bast_name h_bast_rg h_bast_loc h_ssh_key h_ts found=0

    while IFS=$'\t' read -r h_vm_name h_vm_rg h_vm_loc h_vm_id h_bast_name h_bast_rg h_bast_loc h_ssh_key h_ts; do
        [[ "$h_vm_name" == "$VM_NAME" ]] || continue
        if [[ -n "$RESOURCE_GROUP" && "$h_vm_rg" != "$RESOURCE_GROUP" ]]; then
            continue
        fi
        found=1
        break
    done < "$HISTORY_FILE"

    if [[ "$found" -eq 0 ]]; then return 1; fi

    printf "Found previous connection for '%s':\n" "$VM_NAME"
    printf "  VM:        %s (resource group: %s, %s)\n" "$VM_NAME" "$h_vm_rg" "$h_vm_loc"
    printf "  Bastion:   %s (resource group: %s, %s)\n" "$h_bast_name" "$h_bast_rg" "$h_bast_loc"
    printf "  SSH key:   %s\n" "$h_ssh_key"
    printf "  Last used: %s\n" "$h_ts"

    local answer
    read -r -p "Use previous connection? [Y/n]: " answer
    case "${answer,,}" in
        ""|y|yes)
            VM_ID="$h_vm_id"
            VM_RESOURCE_GROUP="$h_vm_rg"
            VM_LOCATION="$h_vm_loc"
            BASTION_NAME="$h_bast_name"
            BASTION_RESOURCE_GROUP="$h_bast_rg"
            BASTION_LOCATION="$h_bast_loc"
            [[ -z "$SSH_KEY" ]] && SSH_KEY="$h_ssh_key"
            USE_HISTORY=1
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

save_to_history() {
    local timestamp new_entry tmp_file vm_name vm_rg count
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    new_entry="$(printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "$VM_NAME" "$VM_RESOURCE_GROUP" "$VM_LOCATION" "$VM_ID" \
        "$BASTION_NAME" "$BASTION_RESOURCE_GROUP" "$BASTION_LOCATION" \
        "$SSH_KEY" "$timestamp")"

    tmp_file="$(mktemp)"
    printf "%s\n" "$new_entry" > "$tmp_file"

    if [[ -f "$HISTORY_FILE" ]]; then
        count=0
        while IFS=$'\t' read -r vm_name vm_rg rest; do
            if [[ "$vm_name" == "$VM_NAME" && "$vm_rg" == "$VM_RESOURCE_GROUP" ]]; then
                continue
            fi
            if [[ "$count" -ge 49 ]]; then break; fi
            printf "%s\t%s\t%s\n" "$vm_name" "$vm_rg" "$rest" >> "$tmp_file"
            count=$(( count + 1 ))
        done < "$HISTORY_FILE"
    fi

    mv "$tmp_file" "$HISTORY_FILE"
}

check_prereqs() {
    require_command az

    if ! az account show >/dev/null 2>&1; then
        err "Azure CLI is not authenticated. Run 'az login' first."
        exit 1
    fi

    if ! az extension show --name ssh --query name --output tsv >/dev/null 2>&1; then
        err "Azure CLI extension 'ssh' is not installed. Run: az extension add --name ssh"
        exit 1
    fi

    SSH_KEY="$(expand_path "$SSH_KEY")"
    if [[ ! -f "$SSH_KEY" ]]; then
        err "SSH key file not found: $SSH_KEY"
        exit 1
    fi

    local perm
    perm="$(stat -c "%a" "$SSH_KEY")"
    if [[ "${perm: -2}" != "00" ]]; then
        err "SSH key has insecure permissions ($perm). Run: chmod 600 \"$SSH_KEY\""
        exit 1
    fi
}

resolve_vm() {
    local matches choice

    if [[ -n "$RESOURCE_GROUP" ]]; then
        if ! VM_ID="$(az vm show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --query id \
            --output tsv 2>/dev/null)"; then
            err "VM '$VM_NAME' not found in resource group '$RESOURCE_GROUP'."
            exit 1
        fi

        VM_LOCATION="$(az vm show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --query location \
            --output tsv)"
        VM_RESOURCE_GROUP="$RESOURCE_GROUP"
        return 0
    fi

    mapfile -t VM_MATCHES < <(
        az vm list \
            --query "[?name=='$VM_NAME'].[id, resourceGroup, location]" \
            --output tsv
    )

    if (( ${#VM_MATCHES[@]} == 0 )); then
        err "No VM named '$VM_NAME' found in the current subscription."
        exit 1
    fi

    if (( ${#VM_MATCHES[@]} == 1 )); then
        IFS=$'\t' read -r VM_ID VM_RESOURCE_GROUP VM_LOCATION <<< "${VM_MATCHES[0]}"
        return 0
    fi

    mapfile -t matches < <(
        printf "%s\n" "${VM_MATCHES[@]}" | while IFS=$'\t' read -r id rg location; do
            printf "%s (resource group: %s, location: %s)\n" "$VM_NAME" "$rg" "$location"
        done
    )

    choice="$(prompt_choice "Multiple VMs named '$VM_NAME' were found. Select one:" "${matches[@]}")"

    local index=0
    for index in "${!matches[@]}"; do
        if [[ "${matches[$index]}" == "$choice" ]]; then
            IFS=$'\t' read -r VM_ID VM_RESOURCE_GROUP VM_LOCATION <<< "${VM_MATCHES[$index]}"
            return 0
        fi
    done

    err "Failed to resolve VM selection."
    exit 1
}

check_vm_state() {
    local state
    state="$(az vm get-instance-view \
        --resource-group "$VM_RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" \
        --output tsv | tr -d '\r')"

    if [[ "$state" != "VM running" ]]; then
        err "VM '$VM_NAME' is not running (current state: ${state:-unknown})."
        exit 1
    fi
}

choose_bastion() {
    local bastion_lines=()
    local preferred_lines=()
    local fallback_lines=()
    local any_lines=()
    local choice

    mapfile -t bastion_lines < <(
        az network bastion list \
            --query "[].[name, resourceGroup, location, id]" \
            --output tsv
    )

    if (( ${#bastion_lines[@]} == 0 )); then
        err "No Azure Bastion hosts found in the current subscription."
        exit 1
    fi

    local line name rg location id
    for line in "${bastion_lines[@]}"; do
        IFS=$'\t' read -r name rg location id <<< "$line"
        if [[ "$rg" == "$VM_RESOURCE_GROUP" ]]; then
            preferred_lines+=("$line")
        elif [[ "$location" == "$VM_LOCATION" ]]; then
            fallback_lines+=("$line")
        else
            any_lines+=("$line")
        fi
    done

    local selected_pool=()
    if (( ${#preferred_lines[@]} > 0 )); then
        selected_pool=("${preferred_lines[@]}")
    elif (( ${#fallback_lines[@]} > 0 )); then
        selected_pool=("${fallback_lines[@]}")
    else
        selected_pool=("${any_lines[@]}")
    fi

    if (( ${#selected_pool[@]} == 1 )); then
        IFS=$'\t' read -r BASTION_NAME BASTION_RESOURCE_GROUP BASTION_LOCATION BASTION_ID <<< "${selected_pool[0]}"
        return 0
    fi

    mapfile -t BASTION_DISPLAY < <(
        printf "%s\n" "${selected_pool[@]}" | while IFS=$'\t' read -r name rg location id; do
            printf "%s (resource group: %s, location: %s)\n" "$name" "$rg" "$location"
        done
    )

    choice="$(prompt_choice "Multiple Bastion hosts are suitable. Select one:" "${BASTION_DISPLAY[@]}")"

    local index=0
    for index in "${!BASTION_DISPLAY[@]}"; do
        if [[ "${BASTION_DISPLAY[$index]}" == "$choice" ]]; then
            IFS=$'\t' read -r BASTION_NAME BASTION_RESOURCE_GROUP BASTION_LOCATION BASTION_ID <<< "${selected_pool[$index]}"
            return 0
        fi
    done

    err "Failed to resolve Bastion selection."
    exit 1
}

check_bastion_sku() {
    local sku
    sku="$(az network bastion show \
        --name "$BASTION_NAME" \
        --resource-group "$BASTION_RESOURCE_GROUP" \
        --query "sku.name" \
        --output tsv)"

    if [[ "$sku" == "Basic" ]]; then
        err "Bastion '$BASTION_NAME' uses the Basic SKU, which does not support native SSH. Upgrade to Standard or Premium."
        exit 1
    fi
}

run_bastion_ssh() {
    printf "Using VM '%s' in resource group '%s' (%s).\n" "$VM_NAME" "$VM_RESOURCE_GROUP" "$VM_LOCATION"
    printf "Using Bastion '%s' in resource group '%s' (%s).\n" "$BASTION_NAME" "$BASTION_RESOURCE_GROUP" "$BASTION_LOCATION"

    local cmd=(
        az network bastion ssh
        --name "$BASTION_NAME"
        --resource-group "$BASTION_RESOURCE_GROUP"
        --target-resource-id "$VM_ID"
        --auth-type ssh-key
        --username "$USERNAME"
        --ssh-key "$SSH_KEY"
    )

    if (( DRY_RUN )); then
        printf "Dry run — would execute:\n  %s\n" "${cmd[*]}"
        return 0
    fi

    "${cmd[@]}"
}

main() {
    parse_args "$@"
    try_history || true
    if [[ -z "$SSH_KEY" ]]; then
        err "Missing required option: -s / --ssh-key"
        usage
        exit 1
    fi
    check_prereqs
    if [[ "$USE_HISTORY" -eq 0 ]]; then
        resolve_vm
        choose_bastion
        check_bastion_sku
    fi
    check_vm_state
    run_bastion_ssh
    if [[ "$DRY_RUN" -eq 0 ]]; then
        save_to_history
    fi
}

main "$@"

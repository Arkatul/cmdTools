#!/usr/bin/env bash
# deploy-bicep.sh
# Requirements: Azure CLI (az)

set -euo pipefail

# ---------- helpers ----------
err()   { printf "Error: %s\n" "$*" >&2; }
ask_yn() {
  # ask_yn "Prompt" defaultN_or_Y
  local prompt="$1" def="${2:-N}" ans
  local suffix="[y/N]"
  [[ "${def^^}" == "Y" ]] && suffix="[Y/n]"
  read -r -p "$prompt $suffix " ans || true
  ans="${ans:-$def}"
  [[ "${ans^^}" == "Y" ]]
}

select_from_list() {
  # select_from_list "prompt" array_items...
  local prompt="$1"; shift
  local items=("$@")
  local i
  echo "$prompt"
  for i in "${!items[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${items[$i]}"
  done
  local choice
  while true; do
    read -r -p "Enter number (1-${#items[@]}): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#items[@]} )) && break
    echo "Invalid choice."
  done
  printf "%s" "${items[$((choice-1))]}"
}

prefill_read() {
  # prefill_read var_name prompt default_value
  local __var="$1" prompt="$2" def="$3" tmp
  # shellcheck disable=SC2162
  read -e -i "$def" -p "$prompt" tmp || true
  tmp="${tmp:-$def}"
  printf -v "$__var" "%s" "$tmp"
}
menu_pick() {
  # menu_pick "Prompt" array_items...
  local prompt="$1"; shift
  local items=("$@")
  local PS3="Enter number (1-${#items[@]}): "
  echo "$prompt"
  select opt in "${items[@]}"; do
    if [[ -n "$opt" ]]; then
      printf "%s" "$opt"
      break
    else
      echo "Invalid choice."
    fi
  done
}

# ---------- 1) discover files ----------
shopt -s nullglob
mapfile -t BICEPS < <(find . -maxdepth 1 -type f -name '*.bicep' ! -name '*.bicepparam' -printf '%f\n' | sort)
mapfile -t PARAMS < <(find . -maxdepth 1 -type f -name '*.bicepparam' -printf '%f\n' | sort)
shopt -u nullglob

if (( ${#BICEPS[@]} == 0 )); then
  err "No .bicep files in current directory."
  exit 1
fi

# ---------- 2) choose bicep ----------
chosen_bicep=""
if (( ${#BICEPS[@]} == 1 )); then
  echo "Found single Bicep file: ${BICEPS[0]}"
  if ask_yn "Deploy this template?" "Y"; then
    chosen_bicep="${BICEPS[0]}"
  else
    err "Aborted."
    exit 1
  fi
else
  chosen_bicep="$(select_from_list "Select Bicep template:" "${BICEPS[@]}")"
fi

# ---------- 3) choose params (optional) ----------
chosen_params=""
if (( ${#PARAMS[@]} == 0 )); then
  echo "No .bicepparam files found. Continue without parameters file."
else
  if (( ${#PARAMS[@]} == 1 )); then
    echo "Found single parameter file:"
    printf "  1) %s\n" "${PARAMS[0]}"
    if ask_yn "Use this parameters file?" "Y"; then
      chosen_params="${PARAMS[0]}"
    fi
  else
    if ask_yn "Use a parameters file?" "Y"; then
      chosen_params="$(menu_pick "Select parameters file:" "${PARAMS[@]}")"
    fi
  fi
fi


# ---------- 4) location (default WestEurope) ----------
location=""
prefill_read location "Deployment location: " "WestEurope"

# ---------- 5) resource group name ----------
read -r -p "Resource group name: " rg_name
if [[ -z "$rg_name" ]]; then
  err "Resource group name is required."
  exit 1
fi

# ---------- 6) deployment name ----------
folder_name="$(basename "$PWD")"
def_deploy="deploy-${folder_name}-$(date +%Y%m%d)"
deployment_name=""
prefill_read deployment_name "Deployment name: " "$def_deploy"

# ---------- 7) summary & confirm ----------
echo
echo "Summary:"
echo "  Template     : $chosen_bicep"
echo "  Parameters   : ${chosen_params:-<none>}"
echo "  Location     : $location"
echo "  ResourceGroup: $rg_name"
echo "  Deployment   : $deployment_name"
echo

if ! ask_yn "Proceed with deployment?" "N"; then
  echo "Aborted."
  exit 0
fi

# ---------- 8) deploy ----------
cmd=( az deployment group create
  --resource-group "$rg_name"
  --name "$deployment_name"
  --template-file "$chosen_bicep"
  --location "$location"
)
if [[ -n "$chosen_params" ]]; then
  # Use @file syntax to pass the bicepparam content
  cmd+=( --parameters @"$chosen_params" )
fi

echo "Running: ${cmd[*]}"
"${cmd[@]}"

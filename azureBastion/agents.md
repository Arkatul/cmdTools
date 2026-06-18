# azureBastion

## Purpose

`azureBastionSsh.sh` — connects to an Azure VM via Azure Bastion using SSH key authentication. Resolves the VM and Bastion host automatically from the current Azure subscription.

## Usage

```bash
./azureBastionSsh.sh -u USERNAME -s SSH_KEY -v VM_NAME [-g RESOURCE_GROUP]
```

| Flag | Long form | Required | Description |
|------|-----------|----------|-------------|
| `-u` | `--username` | yes | SSH username on the target VM |
| `-s` | `--ssh-key` | no* | Path to the SSH private key (`~` expansion supported). Optional if a previous connection exists in history |
| `-v` | `--vmname` | yes | Name of the target VM |
| `-g` | `--resource-group` | no | Resource group of the VM (skips subscription-wide search) |
| | `--dry-run` | no | Print the `az` command without executing it |
| | `--no-history` | no | Ignore history and resolve VM/Bastion from Azure |
| `-h` | `--help` | no | Show help and exit |

## Prerequisites

- `az` (Azure CLI) installed and authenticated (`az login`)
- Azure Bastion host with **Standard or Premium SKU** (Basic is rejected — does not support native SSH tunneling)
- SSH private key accessible at the given path

## Behavior

### History
On each successful connection, the script saves the VM/Bastion resolution to `~/.azurebastion` (TSV, 50-entry cap, newest first). On the next run for the same VM name, it offers to reuse the cached result — skipping all Azure API calls. Pass `--no-history` to bypass the cache and force a fresh lookup.

The SSH key path is also stored in history. If `-s` is omitted on a subsequent run, the cached key is used automatically.

### VM resolution
- If `-g` is provided: looks up the VM directly in that resource group.
- Otherwise: searches all VMs in the subscription by name.
  - Single match → used automatically.
  - Multiple matches → interactive numbered prompt to select one.

### Bastion selection
Picks the most local Bastion host using a priority cascade:
1. Same resource group as the VM
2. Same Azure region as the VM
3. Any Bastion in the subscription

If multiple hosts qualify at the chosen tier, an interactive prompt is shown.

### Connection
Delegates to `az network bastion ssh` with `--auth-type ssh-key`.

## Files

| File | Description |
|------|-------------|
| `azureBastionSsh.sh` | Main script — all logic lives here |
| `install.sh` | Copies the script to `~/.local/bin/azureBastionSsh` with `755` permissions |
| `.claude/settings.local.json` | Claude Code local permissions (allows `chmod` and `git` commands) |

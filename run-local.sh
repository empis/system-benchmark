#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 benchmark|odoo [ip=1.2.3.4] [KEY=VALUE ...]" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage

cmd="$1"
shift

if [[ "$cmd" != "benchmark" && "$cmd" != "odoo" ]]; then
  usage
fi

ip=""
ssh_user=""
use_key=""
ssh_key_file=""
ssh_pass=""
sudo_pass=""
local_env_file=""
local_sql_file=""

# Collect KEY=VALUE args
extra_kv=()
for arg in "$@"; do
  if [[ "$arg" != *=* ]]; then
    echo "Invalid argument: $arg" >&2
    usage
  fi
  key="${arg%%=*}"
  val="${arg#*=}"

  case "$key" in
    ip)
      ip="$val"
      ;;
    SSH_USER)
      ssh_user="$val"
      ;;
    SSH_KEY_FILE)
      ssh_key_file="$val"
      ;;
    SSH_USE_KEY)
      use_key="$val"
      ;;
    SSH_PASSWORD)
      ssh_pass="$val"
      ;;
    SSH_SUDO_PASSWORD)
      sudo_pass="$val"
      ;;
    ENV_FILE)
      local_env_file="$val"
      ;;
    SQL_FILE)
      local_sql_file="$val"
      ;;
    *)
      extra_kv+=("$key=$val")
      ;;
  esac
done

if [[ -z "$ip" ]]; then
  read -r -p "IP: " ip
fi

if [[ -z "$ssh_user" ]]; then
  read -r -p "SSH user: " ssh_user
fi

if [[ -z "$use_key" ]]; then
  read -r -p "Use SSH key? (y/n): " use_key
fi

if [[ "$use_key" =~ ^[Yy]$ ]]; then
  if [[ -z "$ssh_key_file" ]]; then
    read -r -p "SSH key path [~/.ssh/id_rsa]: " ssh_key_file
  fi
  if [[ -z "$ssh_key_file" ]]; then
    ssh_key_file="~/.ssh/id_rsa"
  fi
else
  if [[ -z "$ssh_pass" ]]; then
    read -r -s -p "SSH password: " ssh_pass
    echo
  fi
fi

if [[ "$ssh_user" != "root" ]]; then
  if [[ -z "$sudo_pass" ]]; then
    read -r -s -p "Sudo password: " sudo_pass
    echo
  fi
fi

[[ -n "$ip" ]] || { echo "Missing ip=..." >&2; usage; }

# Expand ~ for paths
if [[ -n "$ssh_key_file" ]]; then
  ssh_key_file="${ssh_key_file/#\~/$HOME}"
fi
if [[ -n "$local_env_file" ]]; then
  local_env_file="${local_env_file/#\~/$HOME}"
fi
if [[ -n "$local_sql_file" ]]; then
  local_sql_file="${local_sql_file/#\~/$HOME}"
fi

# Validate files
if [[ -n "$ssh_key_file" && ! -f "$ssh_key_file" ]]; then
  echo "SSH_KEY_FILE not found: $ssh_key_file" >&2
  exit 1
fi
if [[ -n "$local_env_file" && ! -f "$local_env_file" ]]; then
  echo "ENV_FILE not found: $local_env_file" >&2
  exit 1
fi
if [[ -n "$local_sql_file" && ! -f "$local_sql_file" ]]; then
  echo "SQL_FILE not found: $local_sql_file" >&2
  exit 1
fi

# Build a temp vars file for ansible
vars_file="$(mktemp)"
trap 'rm -f "$vars_file"' EXIT

{
  echo "target_host: $ip"
  echo "ssh_user: $ssh_user"
  if [[ -n "$ssh_pass" ]]; then
    echo "ssh_pass: \"$ssh_pass\""
  fi
  if [[ -n "$sudo_pass" ]]; then
    echo "sudo_pass: \"$sudo_pass\""
  fi
  echo "bench_env:"
  for kv in "${extra_kv[@]+${extra_kv[@]}}"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    # Quote as string for YAML
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf "  %s: \"%s\"\n" "$k" "$v"
  done

  if [[ -n "$local_env_file" ]]; then
    echo "local_env_file: $local_env_file"
  fi
  if [[ -n "$local_sql_file" ]]; then
    echo "local_sql_file: $local_sql_file"
  fi
  if [[ -n "$ssh_key_file" ]]; then
    echo "ssh_key_file: $ssh_key_file"
  fi
} > "$vars_file"

playbook="ansible-playbook.yml"
if [[ "$cmd" == "odoo" ]]; then
  playbook="odoo-playbook.yml"
fi

ansible_cmd=(ansible-playbook -i "$ip," "$playbook" -e "@$vars_file")
if [[ -n "$ssh_user" ]]; then
  ansible_cmd+=(-u "$ssh_user")
fi
if [[ -n "$ssh_key_file" && "$use_key" =~ ^[Yy]$ ]]; then
  ansible_cmd+=(--private-key "$ssh_key_file")
fi
if [[ -n "$ssh_pass" && ! "$use_key" =~ ^[Yy]$ ]]; then
  ansible_cmd+=(--ssh-common-args "-o PreferredAuthentications=password")
fi
if [[ "$ssh_user" != "root" ]]; then
  ansible_cmd+=(--become)
fi

notify() {
  local msg="$1"
  echo "$msg" >&2
  printf '\a' >&2
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"system-benchmark\""
  fi
}

if "${ansible_cmd[@]}"; then
  notify "Benchmark run completed."
else
  notify "Benchmark run failed."
  exit 1
fi

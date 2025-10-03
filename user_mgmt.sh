#!/usr/bin/env bash
# user_mgmt_backup.sh
# Simple user management + backup utility for Linux
# Usage: ./user_mgmt_backup.sh help   (or see individual subcommands)

set -euo pipefail
shopt -s nullglob

####################
# Configuration
####################
HOSTNAME=$(hostname -s)
TIMESTAMP_FMT="%Y%m%d-%H%M%S"

# choose a logfile: root writes to /var/log, non-root writes to local file
if [ "$(id -u)" -eq 0 ]; then
  LOGFILE="/var/log/user_mgmt_backup.log"
else
  LOGFILE="./user_mgmt_backup.log"
fi

# default backup destination (can be overridden)
DEFAULT_BACKUP_DIR="./backups"

####################
# Helpers
####################
log() {
  local ts; ts=$(date '+%F %T')
  echo "${ts} [$$] $*" | tee -a "$LOGFILE"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This action requires root. Re-run with sudo or as root." >&2
    exit 1
  fi
}

exists_user() {
  id -u "$1" >/dev/null 2>&1
}

exists_group() {
  getent group "$1" >/dev/null 2>&1
}

print_global_help() {
  cat <<EOF
User Management & Backup script
Usage:
  $0 <action> [options]

Actions:
  add-user        --username NAME [--group G] [--shell /bin/bash] [--password PASS] [--no-home]
  del-user        --username NAME [--remove-home] [--force]
  modify-user     --username NAME [--shell SHELL] [--add-groups g1,g2] [--lock|--unlock]
  add-group       --group NAME
  del-group       --group NAME
  backup          --source DIR [--dest DIR] [--retention N] [--dry-run]
  list-users
  help

Examples:
  $0 add-user --username testuser --group devs --shell /bin/bash
  $0 backup --source /etc --dest /var/backups/etc --retention 7
EOF
}

####################
# Subcommands
####################

add_user() {
  require_root
  local username="" group="" shell="/bin/bash" password="" create_home=true force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--username) username="$2"; shift 2;;
      -g|--group) group="$2"; shift 2;;
      -s|--shell) shell="$2"; shift 2;;
      --password) password="$2"; shift 2;;
      --no-home) create_home=false; shift;;
      --force) force=true; shift;;
      *) echo "Unknown option: $1"; return 1;;
    esac
  done

  if [ -z "$username" ]; then echo "Username required"; return 1; fi

  if exists_user "$username"; then
    echo "User $username already exists."
    if [ "$force" = true ]; then
      log "add_user: user $username exists, but --force provided: continuing."
    else
      echo "Use --force to continue (or choose another name)."
      return 1
    fi
  fi

  if [ -n "$group" ] && ! exists_group "$group"; then
    log "add_user: creating group $group"
    groupadd "$group"
  fi

  # build useradd options
  local ua_opts=()
  if [ "$create_home" = true ]; then
    ua_opts+=("-m")
  else
    ua_opts+=("-M")
  fi
  ua_opts+=("-s" "$shell")
  if [ -n "$group" ]; then
    ua_opts+=("-G" "$group")
  fi

  log "Running useradd ${ua_opts[*]} $username"
  useradd "${ua_opts[@]}" "$username"

  if [ -n "$password" ]; then
    echo "$username:$password" | chpasswd
    log "Password set non-interactively for $username (insecure)."
  else
    log "No password provided. Please run 'passwd $username' to set password interactively."
  fi

  log "User $username created."
}

del_user() {
  require_root
  local username="" remove_home=false force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--username) username="$2"; shift 2;;
      --remove-home) remove_home=true; shift;;
      --force) force=true; shift;;
      *) echo "Unknown option: $1"; return 1;;
    esac
  done

  if [ -z "$username" ]; then echo "Username required"; return 1; fi
  if ! exists_user "$username"; then echo "User $username does not exist"; return 1; fi

  local uid; uid=$(id -u "$username")
  if [ "$uid" -lt 1000 ] && [ "$force" != true ]; then
    echo "Refusing to delete system or low-UID user (UID=$uid). Use --force to override."
    return 1
  fi

  local cmd=(userdel)
  if [ "$remove_home" = true ]; then
    cmd+=("-r")
  fi

  log "Deleting user $username with: ${cmd[*]}"
  "${cmd[@]}" "$username"
  log "User $username deleted."
}

modify_user() {
  require_root
  local username="" shell="" add_groups="" lock=false unlock=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--username) username="$2"; shift 2;;
      --shell) shell="$2"; shift 2;;
      --add-groups) add_groups="$2"; shift 2;; # comma-separated
      --lock) lock=true; shift;;
      --unlock) unlock=true; shift;;
      *) echo "Unknown option: $1"; return 1;;
    esac
  done

  if [ -z "$username" ]; then echo "Username required"; return 1; fi
  if ! exists_user "$username"; then echo "User $username does not exist"; return 1; fi

  if [ -n "$shell" ]; then
    log "Changing shell for $username -> $shell"
    usermod -s "$shell" "$username"
  fi

  if [ -n "$add_groups" ]; then
    log "Adding $username to groups: $add_groups"
    IFS=',' read -ra GARR <<< "$add_groups"
    for g in "${GARR[@]}"; do
      if ! exists_group "$g"; then
        log "Group $g does not exist; creating"
        groupadd "$g"
      fi
    done
    usermod -a -G "$add_groups" "$username"
  fi

  if [ "$lock" = true ]; then
    log "Locking account $username"
    passwd -l "$username"
  fi
  if [ "$unlock" = true ]; then
    log "Unlocking account $username"
    passwd -u "$username"
  fi

  log "Modification done for $username."
}

add_group_cmd() {
  require_root
  local group=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--group) group="$2"; shift 2;;
      *) echo "Unknown option: $1"; return 1;;
    esac
  done
  if [ -z "$group" ]; then echo "Group name required"; return 1; fi
  if exists_group "$group"; then echo "Group already exists"; return 1; fi
  groupadd "$group"
  log "Group $group created."
}

del_group_cmd() {
  require_root
  local group=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--group) group="$2"; shift 2;;
      *) echo "Unknown option: $1"; return 1;;
    esac
  done
  if [ -z "$group" ]; then echo "Group name required"; return 1; fi
  if ! exists_group "$group"; then echo "Group does not exist"; return 1; fi
  groupdel "$group"
  log "Group $group deleted."
}

list_users_cmd() {
  awk -F: '{ if ($3 >= 1000) printf "%-15s UID:%-6s GID:%-6s HOME:%-25s SHELL:%s\n", $1,$3,$4,$6,$7 }' /etc/passwd
}

####################
# Backup logic
####################
backup_cmd() {
  local source_dir="" dest_dir="$DEFAULT_BACKUP_DIR" retention=0 dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source) source_dir="$2"; shift 2;;
      --dest) dest_dir="$2"; shift 2;;
      --retention) retention="$2"; shift 2;;  # keep last N backups
      --dry-run) dry_run=true; shift;;
      *) echo "Unknown option: $1"; return 1;;
    esac
  done

  if [ -z "$source_dir" ]; then echo "Source directory required: --source /path"; return 1; fi
  if [ ! -d "$source_dir" ]; then echo "Source directory does not exist: $source_dir"; return 1; fi

  mkdir -p "$dest_dir"

  local ts; ts=$(date +"$TIMESTAMP_FMT")
  local srcbase; srcbase=$(basename "$source_dir")
  local fname="backup-${HOSTNAME}-${srcbase}-${ts}.tar.gz"
  local fullpath="${dest_dir%/}/$fname"

  if [ "$dry_run" = true ]; then
    echo "[DRY RUN] Would create backup: tar -czf '$fullpath' -C '$(dirname "$source_dir")' '$srcbase'"
  else
    log "Creating backup $fullpath from $source_dir"
    tar -czf "$fullpath" -C "$(dirname "$source_dir")" "$srcbase"
    log "Backup created: $fullpath"
  fi

  # retention by keeping latest N backups
  if [ "$retention" -gt 0 ]; then
    # collect backups sorted by time (newest first)
    mapfile -t files < <(ls -1t "${dest_dir%/}"/backup-"${HOSTNAME}-${srcbase}"-*.tar.gz 2>/dev/null || true)
    local total=${#files[@]}
    if [ "$total" -gt "$retention" ]; then
      # files to delete are the ones after the first $retention
      for f in "${files[@]:$retention}"; do
        if [ "$dry_run" = true ]; then
          echo "[DRY RUN] Would remove: $f"
        else
          log "Removing old backup: $f"
          rm -f -- "$f"
        fi
      done
    fi
  fi
}

####################
# Main dispatcher
####################
if [ $# -lt 1 ]; then
  print_global_help
  exit 1
fi

action="$1"; shift

case "$action" in
  add-user) add_user "$@" ;;
  del-user|delete-user) del_user "$@" ;;
  modify-user) modify_user "$@" ;;
  add-group) add_group_cmd "$@" ;;
  del-group) del_group_cmd "$@" ;;
  list-users) list_users_cmd ;;
  backup) backup_cmd "$@" ;;
  help|-h|--help) print_global_help ;;
  *) echo "Unknown action: $action"; print_global_help; exit 1 ;;
esac

exit 0

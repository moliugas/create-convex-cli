#!/usr/bin/env bash
set -euo pipefail

# Simple installer for CCC (Create Convex CLI)

if [ -t 1 ] && [ -z "${NO_COLOR-}" ]; then
  RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m";
  RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m";
else
  RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN="";
fi
info()    { printf "%b\n" "${BLUE}➜${RESET} $*"; }
success() { printf "%b\n" "${GREEN}✔${RESET} $*"; }
warn()    { printf "%b\n" "${YELLOW}⚠${RESET} $*"; }
error()   { printf "%b\n" "${RED}✖${RESET} $*"; }
section() { printf "\n%b\n" "${BOLD}${MAGENTA}==>${RESET} $*"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SOURCE_SCRIPT="${SOURCE_SCRIPT:-$SCRIPT_DIR/dokploy_bootstrap_script_postgres.sh}"
TARGET_NAME="ccc"
TEMPLATE_FILES=("docker-compose.yml" "docker-compose-dashless.yml")

usage() {
  echo "Usage: ./install_ccc.sh [--global|--user|--uninstall|--uninstall-user|--uninstall-global]"
  echo "       SOURCE_SCRIPT=/path/to/script ./install_ccc.sh --global"
  echo
  echo "Flags:"
  echo "  --global             Install for all users to /usr/local/bin/ccc"
  echo "  --user               Install for current user to ~/.local/bin/ccc (default)"
  echo "  --uninstall          Uninstall from current user by default (use flags below to choose)"
  echo "  --uninstall-user     Uninstall from ~/.local/bin/ccc"
  echo "  --uninstall-global   Uninstall from /usr/local/bin/ccc"
}

ensure_deps() {
  local missing=()
  for bin in bash curl jq install; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "Missing dependencies: ${missing[*]}"
    if command -v apt >/dev/null 2>&1; then
      echo "Try: sudo apt update && sudo apt install -y jq curl install" >&2
    fi
    exit 1
  fi
}

normalize_line_endings() {
  # Convert CRLF to LF if present (in-place)
  if grep -q $'\r' "$SOURCE_SCRIPT" 2>/dev/null; then
    info "Converting CRLF to LF in $SOURCE_SCRIPT"
    sed -i 's/\r$//' "$SOURCE_SCRIPT"
  fi
}

install_global() {
  local target="/usr/local/bin/$TARGET_NAME"
  info "Installing globally to $target"
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    sudo install -m 0755 "$SOURCE_SCRIPT" "$target"
  else
    install -m 0755 "$SOURCE_SCRIPT" "$target"
  fi
  success "Installed: $target"

  # Copy template compose files to a shared location
  local share_dir="/usr/local/share/$TARGET_NAME"
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    sudo mkdir -p "$share_dir"
  else
    mkdir -p "$share_dir"
  fi
  for f in "${TEMPLATE_FILES[@]}"; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
      if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        sudo install -m 0644 "$SCRIPT_DIR/$f" "$share_dir/$f"
      else
        install -m 0644 "$SCRIPT_DIR/$f" "$share_dir/$f"
      fi
    fi
  done
  info "Templates copied to: $share_dir"
}

install_user() {
  local bin_dir="$HOME/.local/bin"
  local target="$bin_dir/$TARGET_NAME"
  mkdir -p "$bin_dir"
  info "Installing for current user to $target"
  install -m 0755 "$SOURCE_SCRIPT" "$target"
  # Ensure PATH
  if ! echo ":$PATH:" | grep -q ":$bin_dir:"; then
    warn "$bin_dir not in PATH. Adding to ~/.profile"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"
    info "Run: source ~/.profile"
  fi
  success "Installed: $target"

   # Copy template compose files to a user share dir
   local share_dir="$HOME/.local/share/$TARGET_NAME"
   mkdir -p "$share_dir"
   for f in "${TEMPLATE_FILES[@]}"; do
     if [ -f "$SCRIPT_DIR/$f" ]; then
       install -m 0644 "$SCRIPT_DIR/$f" "$share_dir/$f"
     fi
   done
   info "Templates copied to: $share_dir"
}

uninstall_cmd() {
  local scope="${1-}"
  local removed=false
  if [ "$scope" = "global" ]; then
    local path="/usr/local/bin/$TARGET_NAME"
    if [ -e "$path" ]; then
      info "Removing $path"
      sudo rm -f "$path"
      removed=true
    fi
  elif [ "$scope" = "user" ]; then
    local path="$HOME/.local/bin/$TARGET_NAME"
    if [ -e "$path" ]; then
      info "Removing $path"
      rm -f "$path"
      removed=true
    fi
  else
    # legacy: remove both if no scope provided
    for path in "/usr/local/bin/$TARGET_NAME" "$HOME/.local/bin/$TARGET_NAME"; do
      if [ -e "$path" ]; then
        info "Removing $path"
        if [ -w "$(dirname "$path")" ]; then
          rm -f "$path"
        else
          sudo rm -f "$path"
        fi
        removed=true
      fi
    done
  fi
  if $removed; then success "Uninstalled $TARGET_NAME"; else warn "$TARGET_NAME not found"; fi
}

main() {
  case "${1-}" in
    -h|--help|help) usage; exit 0 ;;
    --uninstall) info "Defaulting to current-user uninstall. Use --uninstall-global to remove system-wide."; uninstall_cmd user; exit 0 ;;
    --uninstall-user) uninstall_cmd user; exit 0 ;;
    --uninstall-global) uninstall_cmd global; exit 0 ;;
    --global) scope=global ;;
    --user) scope=user ;;
    *) scope="" ;;
  esac

  ensure_deps
  [ -f "$SOURCE_SCRIPT" ] || { error "Source script not found: $SOURCE_SCRIPT"; exit 1; }
  normalize_line_endings

  if [ -z "$scope" ]; then
    # Default to current user install without prompting
    scope=user
    info "Defaulting to current-user install (~/.local/bin). Use --global for system-wide."
  fi

  if [ "$scope" = "global" ]; then
    install_global
  else
    install_user
  fi

  echo
  success "Try: $TARGET_NAME --help"

  echo
  info "Template compose files were installed to a share directory."
  info "Copy one into your project directory and customize as needed."
  info "Example: cp ~/.local/share/$TARGET_NAME/docker-compose.yml ./  (for user installs)"
  info "         sudo cp /usr/local/share/$TARGET_NAME/docker-compose.yml ./  (for global installs)"
}

main "$@"

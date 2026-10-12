#!/usr/bin/env bash
# Uninstall all ARC Agent / tessera artifacts from the machine WITHOUT touching
# the github-cloned development project folders (default: ~/Documents/SwiftProjects/
# arc-agent and ~/Documents/SwiftProjects/tessera).
#
# Removes (all outside the project clones):
#   * installed binaries  : ~/.local/bin/arc, arc-agent-webui, tessera
#   * config + data home  : ~/.arc/           (config, sessions, skills, plugins,
#                                              profiles, memories, cron, kanban,
#                                              checkpoints, hooks, mcp-cache,
#                                              workspaces, tessera db/cfg, .env,
#                                              gateway.json, webui-settings.json)
#   * install.sh checkouts: ~/.arc-agent*,    (source checkouts from previous
#                                              installs; NOT the dev projects)
#   * runtime logs        : ${TMPDIR:-/tmp}/arc-serve.log, relay-federated.log
#   * running processes   : `arc serve` and `tessera run` (stopped first)
#
# The development project folders (~/Documents/SwiftProjects/arc-agent and
# /tessera) are NEVER removed. A target path that resolves to, is under, or
# contains a project folder is refused.
#
# Safety: DRY-RUN by default (prints the plan, deletes nothing).
#   --yes        actually delete
#   --backup     tar up ~/.arc to ~/.arc-uninstall-backup-<timestamp>.tar.gz
#                before removing it
#   --force-purge include install.sh checkout dirs (~/.arc-agent*) even if they
#                contain a .git repo (they are installs, not the dev projects)
#   --dry-run    print the plan only (default)
#
# Env overrides:
#   ARC_BIN_DIR           (~/.local/bin)
#   ARC_HOME              (~/.arc)
#   ARC_INSTALL_DIRS      (space-separated install checkout dirs)
#   ARC_LOG_DIR           (${TMPDIR:-/tmp})
#   ARC_PROJECT_DIRS      (space-separated project folders that are never removed)
set -u

BIN_DIR="${ARC_BIN_DIR:-$HOME/.local/bin}"
ARC_HOME="${ARC_HOME:-$HOME/.arc}"
LOG_DIR="${ARC_LOG_DIR:-${TMPDIR:-/tmp}}"
INSTALL_DIRS="${ARC_INSTALL_DIRS:-$HOME/.arc-agent $HOME/.arc-agent-nowebui $HOME/.arc-agent-webui}"
PROJECT_DIRS="${ARC_PROJECT_DIRS:-$HOME/Documents/SwiftProjects/arc-agent
$HOME/Documents/SwiftProjects/tessera}"

BINARIES=(
  "$BIN_DIR/arc"
  "$BIN_DIR/arc-agent-webui"
  "$BIN_DIR/tessera"
)
LOGS=(
  "$LOG_DIR/arc-serve.log"
  "$LOG_DIR/relay-federated.log"
)

YES=false
DO_BACKUP=false
PURGE=false
DRY=true

usage() {
  cat <<'EOF'
ARC Agent uninstaller

Usage:
  bash uninstall.sh              # dry run: print every path that would be removed
  bash uninstall.sh --yes        # actually remove
  bash uninstall.sh --yes --backup
  bash uninstall.sh --force-purge --yes

Options:
  --yes           delete instead of dry-run
  --backup        tar up ~/.arc to a timestamped tarball before removing it
  --force-purge   remove install.sh checkouts (~/.arc-agent*) even if they have a .git
  --dry-run       print the plan only (default)
  -h, --help      this message

The development project folders (ARC_PROJECT_DIRS, default
~/Documents/SwiftProjects/arc-agent and /tessera) are NEVER removed.
EOF
}

for a in "$@"; do
  case "$a" in
    --yes)          YES=true ;;
    --backup)       DO_BACKUP=true ;;
    --force-purge)  PURGE=true ;;
    --dry-run)      DRY=true ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown option: $a (see --help)" >&2; exit 2 ;;
  esac
done

# Running processes to stop first.
stop_services() {
  echo "→ Stopping arc/tessera services…"
  local pids
  pids="$(pgrep -f '[a]rc serve' || true)"
  [ -n "$pids" ] && { echo "  kill ${pids}"; [ "$YES" = true ] && kill $pids 2>/dev/null; }
  pids="$(pgrep -f '[t]essera run' || true)"
  [ -n "$pids" ] && { echo "  kill ${pids}"; [ "$YES" = true ] && kill $pids 2>/dev/null; }
}

# Resolve a path and check it is safe: not equal to / under / containing a project dir.
realpath_safe() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || echo "$1"; }

is_project_related() {
  local t; t="$(realpath_safe "$1")"
  for p in $PROJECT_DIRS; do
    local rp; rp="$(realpath_safe "$p")"
    case "$t" in
      "$rp"|"$rp"/*) return 0 ;;   # target is project dir or inside it
      "$t"/*)        return 0 ;;   # target contains a project dir (e.g. ~/.config/something) - refuse
    esac
  done
  return 1
}

remove_checked() {
  local label="$1" path="$2"
  if is_project_related "$path"; then
    echo "  SKIP  $path  (matches a protected project folder)"
    return
  fi
  if [ ! -e "$path" ]; then
    echo "  (absent) $path"
    return
  fi
  if [ "$YES" = true ]; then
    rm -rf -- "$path" && echo "  rm -rf $path"
  else
    echo "  would remove: $path"
  fi
}

backup_arc_home() {
  [ "$DO_BACKUP" = true ] || return 0
  [ -d "$ARC_HOME" ] || return 0
  local tarball="$HOME/arc-uninstall-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  echo "→ Backing up $ARC_HOME to $tarball"
  tar --exclude="$tarball" -czf "$tarball" -C "$HOME" "$(basename "$ARC_HOME")" \
    && echo "  backup written: $tarball"
}

echo "=== ARC Agent uninstaller ==="
echo "Mode        : $([ "$DRY" = true ] && echo "DRY RUN (nothing deleted)" || echo "DELETE")"
echo "Backup      : $([ "$DO_BACKUP" = true ] && echo yes || echo no)"
echo "Force purge : $([ "$PURGE" = true ] && echo yes || echo no)"
echo "Protected   : "
for p in $PROJECT_DIRS; do echo "                 $p"; done
echo ""

stop_services

echo "→ Installed binaries"
for b in "${BINARIES[@]}"; do remove_checked "binary" "$b"; done

echo "→ Config / data home"
remove_checked "arc home" "$ARC_HOME"

echo "→ Runtime logs"
for l in "${LOGS[@]}"; do remove_checked "log" "$l"; done

echo "→ Install.sh source checkouts (not the dev projects)"
for d in $INSTALL_DIRS; do
  [ -e "$d" ] || { echo "  (absent) $d"; continue; }
  if [ -d "$d/.git" ] && [ "$PURGE" = false ]; then
    # It is a git clone; but it is an *install* checkout, not a dev project.
    # Only remove it with --force-purge, unless it is a protected project.
    if is_project_related "$d"; then
      echo "  SKIP  $d  (matches a protected project folder)"
    else
      echo "  would remove (use --force-purge): $d"
    fi
  else
    remove_checked "install dir" "$d"
  fi
done

echo ""
if [ "$YES" = true ]; then
  echo "Done. ARC Agent / tessera artifacts removed (dev project folders preserved)."
else
  echo "Dry run only — nothing was deleted. Re-run with --yes to execute."
  echo "Add --backup to archive ~/.arc first."
fi

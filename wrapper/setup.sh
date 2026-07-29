#!/usr/bin/env bash
# setup.sh - install the govc-safe wrapper for the current user. No root, no sudo.
#
# Installs everything AND wires the hooks into settings.json, so there is nothing
# to edit by hand. Until those hooks are registered the wrapper does nothing at
# all -- govc is not redirected, output is not scrubbed, and your screen shows
# tokens instead of real names -- so leaving that step to a copy-paste was the
# difference between a working install and one that only looked installed.
#
# Linux and macOS. On Windows use WSL or Git Bash: the Python is portable, but
# the installer is not, and no PowerShell version has been tested.
#
# Usage:
#   ./setup.sh                 install, wire ~/.claude/settings.json
#   ./setup.sh --project       wire ./.claude/settings.json instead
#   ./setup.sh --yes           non-interactive (credentials from env or existing file)
#   ./setup.sh --no-settings   install only; do not touch settings.json
#
# This is an anonymisation tool, not a privilege boundary. It runs as you, so an
# agent that deliberately worked around it could read the same files you can. It
# removes the routine leak, which is where the exposure actually comes from.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${GOVC_SAFE_BIN_DIR:-$HOME/.local/bin}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/govc-safe"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/govc-safe"
CREDS="$CFG_DIR/creds"
SKILLS="$HOME/.claude/skills"
SETTINGS="$HOME/.claude/settings.json"
ASSUME_YES=0
DO_SETTINGS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --project)     SETTINGS="$PWD/.claude/settings.json" ;;
        --settings)    SETTINGS="${2:?--settings needs a path}"; shift ;;
        --yes|-y)      ASSUME_YES=1 ;;
        --no-settings) DO_SETTINGS=0 ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; echo "try --help"; exit 1 ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || { echo "[!!] do not run this as root; it installs for one user"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[!!] python3 is required"; exit 1; }

echo "[..] installing to $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 0755 "$SRC/govc-safe"           "$BIN_DIR/govc-safe"
install -m 0755 "$SRC/hooks/govc-guard.py" "$BIN_DIR/govc-guard.py"

mkdir -p "$DATA_DIR"; chmod 0700 "$DATA_DIR"
mkdir -p "$CFG_DIR";  chmod 0700 "$CFG_DIR"

# --- credentials -------------------------------------------------------------
if [ -f "$CREDS" ]; then
    echo "[ok] $CREDS exists - keeping it"
elif [ "$ASSUME_YES" -eq 1 ]; then
    : "${GOVC_URL:?--yes needs GOVC_URL in the environment (or an existing creds file)}"
    umask 077
    {
        echo "GOVC_URL=$GOVC_URL"
        [ -n "${GOVC_USERNAME:-}" ] && echo "GOVC_USERNAME=$GOVC_USERNAME"
        [ -n "${GOVC_PASSWORD:-}" ] && echo "GOVC_PASSWORD=$GOVC_PASSWORD"
        [ -n "${GOVC_INSECURE:-}" ] && echo "GOVC_INSECURE=$GOVC_INSECURE"
    } > "$CREDS"
    echo "[ok] credentials written from the environment"
else
    echo "[..] vCenter credentials -> $CREDS"
    printf '  GOVC_URL      (e.g. vcenter.example.com): ' >&2; read -r U
    printf '  GOVC_USERNAME                           : ' >&2; read -r N
    printf '  GOVC_PASSWORD                           : ' >&2; stty -echo; read -r P; stty echo; echo >&2
    printf '  self-signed cert? GOVC_INSECURE [y/N]   : ' >&2; read -r I
    umask 077
    {
        echo "GOVC_URL=$U"
        echo "GOVC_USERNAME=$N"
        echo "GOVC_PASSWORD=$P"
        case "$I" in [Yy]*) echo "GOVC_INSECURE=true" ;; esac
    } > "$CREDS"
    unset P
fi
chmod 0600 "$CREDS"

# --- optional companion skill ------------------------------------------------
echo "[..] installing the optional govc-private skill (data-minimisation habits)"
mkdir -p "$SKILLS"
rm -rf "$SKILLS/govc-private"
cp -r "$SRC/govc-private" "$SKILLS/"

# --- the step that actually turns it on --------------------------------------
if [ "$DO_SETTINGS" -eq 1 ]; then
    # Editing someone else's settings.json is inherently risky: it is hand-edited,
    # shared with every other tool they have wired in, and has no schema to
    # validate against. The merge is careful and tested, and it writes its own
    # backup -- but that backup sits next to the original and is produced by the
    # same code being trusted, so say plainly that an independent copy is wanted.
    if [ -s "$SETTINGS" ]; then
        echo
        echo "[!!] About to merge hooks into an existing $SETTINGS"
        echo "[!!] A timestamped backup is written next to it, but keep your own copy"
        echo "[!!] somewhere else first:"
        echo "[!!]     cp $SETTINGS ~/settings.json.mine"
        if [ "$ASSUME_YES" -eq 0 ]; then
            printf '     continue? [Y/n]: ' >&2; read -r a
            case "$a" in [Nn]*)
                echo "[--] skipped. Nothing is active until the hooks are wired."
                echo "     Re-run later, or use --no-settings and wire them yourself."
                DO_SETTINGS=0 ;;
            esac
        fi
    fi
fi

if [ "$DO_SETTINGS" -eq 1 ]; then
    echo "[..] wiring hooks into $SETTINGS"
    python3 "$SRC/settings-merge.py" --install "$SETTINGS" --hook "$BIN_DIR/govc-guard.py"
else
    echo "[--] Hooks NOT wired - nothing is active until they are."
    echo "     To wire them later:"
    echo "       python3 $SRC/settings-merge.py --install $SETTINGS --hook $BIN_DIR/govc-guard.py"
    echo "     Or add the block by hand; see the README section 'What it writes to settings.json'."
fi

echo
case ":$PATH:" in
    *":$BIN_DIR:"*) echo "[ok] $BIN_DIR is on PATH" ;;
    *) echo "[!!] $BIN_DIR is NOT on PATH. The PreToolUse hook rewrites govc to"
       echo "     govc-safe, which then has to resolve. Add to ~/.zshrc or ~/.bashrc:"
       echo "       export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# The one thing that quietly defeats the whole point: an agent that inherits
# working credentials never needs the wrapper.
if env | grep -q '^GOVC_'; then
    echo
    echo "[!!] Your shell exports GOVC_* variables. Claude Code inherits the"
    echo "[!!] environment it is started from, so the agent would get working"
    echo "[!!] credentials and could reach vCenter directly, unanonymised."
    echo "[!!] Remove those exports from ~/.zshrc / ~/.bashrc and open a new shell."
    echo "[!!] The credentials now live in $CREDS instead."
else
    echo "[ok] no GOVC_* exported - the agent inherits nothing"
fi

cat <<EOF

Restart Claude Code so it reloads the hooks, then verify:

  $SRC/test-deployment.sh

What was wired (one script, three events):
  PreToolUse      rewrites 'govc ...' -> 'govc-safe ...', so your existing skill
                  keeps working unchanged
  PostToolUse     backstop scrub of IPs/MACs/emails in any other command output
  MessageDisplay  shows YOU real names while the model keeps tokens; display-only,
                  so nothing real is transmitted (/verbose shows what left)

To reverse everything:  $SRC/uninstall.sh
EOF

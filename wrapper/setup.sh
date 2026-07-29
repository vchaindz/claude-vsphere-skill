#!/usr/bin/env bash
# setup.sh - install govc-safe for the current user. No root, no sudo.
#
# What this does:
#   1. puts govc-safe and the hook on your PATH (~/.local/bin)
#   2. stores your vCenter credentials in ~/.config/govc-safe/creds (0600)
#   3. installs the optional govc-private skill
#   4. prints the settings.json block for the hooks
#
# You do NOT need a special skill or a new command name: the PreToolUse hook
# rewrites `govc ...` into `govc-safe ...` before it runs, so the stock govc
# skill keeps working and is anonymised on the way through.
#
# The point of step 2 is that the credentials are NOT exported into the shell
# that launches Claude Code. The agent therefore does not inherit them, they do
# not appear in `env`, and the natural way to reach vCenter is the wrapper --
# which pseudonymises.
#
# This is an anonymisation tool, not a privilege boundary. It runs as you, so an
# agent that deliberately worked around it could read the same files you can.
# It is built to stop real identifiers reaching the model on the normal path,
# which is where leaks actually happen.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${GOVC_SAFE_BIN_DIR:-$HOME/.local/bin}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/govc-safe"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/govc-safe"
CREDS="$CFG_DIR/creds"
SKILLS="$HOME/.claude/skills"

[ "$(id -u)" -ne 0 ] || { echo "[!!] do not run this as root; it installs for one user"; exit 1; }

echo "[..] installing govc-safe to $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 0755 "$SRC/govc-safe" "$BIN_DIR/govc-safe"

mkdir -p "$DATA_DIR"; chmod 0700 "$DATA_DIR"
mkdir -p "$CFG_DIR";  chmod 0700 "$CFG_DIR"

if [ -f "$CREDS" ]; then
    echo "[ok] $CREDS already exists - keeping its contents"
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

echo "[..] installing the optional govc-private skill (minimisation habits)"
mkdir -p "$SKILLS"
rm -rf "$SKILLS/govc-private"
cp -r "$SRC/govc-private" "$SKILLS/"

echo
case ":$PATH:" in
    *":$BIN_DIR:"*) echo "[ok] $BIN_DIR is on PATH" ;;
    *) echo "[!!] $BIN_DIR is NOT on PATH. Add to ~/.zshrc or ~/.bashrc:"
       echo "       export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# The one thing that quietly defeats the whole point: if the shell that starts
# Claude Code exports GOVC_*, the agent inherits working credentials and never
# needs the wrapper.
if env | grep -q '^GOVC_'; then
    echo
    echo "[!!] Your current shell exports GOVC_* variables. Claude Code inherits the"
    echo "[!!] environment it is started from, so the agent would get working"
    echo "[!!] credentials and could call govc directly, bypassing anonymisation."
    echo "[!!] Remove those exports from ~/.zshrc / ~/.bashrc and open a new shell."
    echo "[!!] The credentials now live in $CREDS instead."
else
    echo "[ok] no GOVC_* in the current environment - the agent will not inherit any"
fi

cat <<EOF

Add to .claude/settings.json (project) or ~/.claude/settings.json (user):

{
  "permissions": {
    "deny": ["Bash(*GOVC_PASSWORD*)"]
  },
  "hooks": {
    "PreToolUse":  [{ "matcher": "Bash",
      "hooks": [{ "type": "command", "command": "$BIN_DIR/govc-guard.py" }] }],
    "PostToolUse": [{ "matcher": "Bash",
      "hooks": [{ "type": "command", "command": "$BIN_DIR/govc-guard.py" }] }],
    "MessageDisplay": [
      { "hooks": [{ "type": "command", "command": "$BIN_DIR/govc-guard.py" }] }]
  }
}

Note there is deliberately no "Bash(govc:*)" deny rule: deny rules are evaluated
regardless of what a hook returns, so it would block the very command the
PreToolUse hook is redirecting.

How the three fit together:
  PreToolUse     rewrites `govc ...` -> `govc-safe ...`, so your existing skill
                 and habits keep working unchanged
  PostToolUse    backstop scrub of IPs/MACs/emails in any other command output
  MessageDisplay shows YOU the real names while the model keeps the tokens.
                 Display-only: the transcript and what the model sees keep the
                 tokens, so nothing real is transmitted. /verbose shows exactly
                 what left the machine.

Then check the setup:
  $SRC/test-deployment.sh
EOF

install -m 0755 "$SRC/hooks/govc-guard.py" "$BIN_DIR/govc-guard.py"
echo
echo "[ok] hook installed to $BIN_DIR/govc-guard.py"

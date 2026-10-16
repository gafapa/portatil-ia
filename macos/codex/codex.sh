#!/bin/sh
# Codex CLI - portable launcher (Linux and macOS).
# Runs ../lib/lanzador.py, which keeps the assistant's state in this folder
# and its credentials encrypted. See ../README.md.
#
#   codex.sh                      workspace menu
#   codex.sh --espacio NAME       open or create a workspace directly
#   codex.sh --solo-cifrar        encrypt credentials left unencrypted, then exit
#   codex.sh <arguments>          arguments go to the assistant (for example --version)
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
. "$DIR/../lib/python.sh" || exit 1
exec "$PYTHON" -I -S -B "$DIR/../lib/lanzador.py" codex "$@"

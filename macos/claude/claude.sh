#!/bin/sh
# Claude Code - portable launcher (Linux and macOS).
# Runs ../lib/lanzador.py, which keeps the assistant's state in this folder
# and its credentials encrypted. See ../README.md.
#
#   claude.sh                      workspace menu
#   claude.sh --espacio NAME       open or create a workspace directly
#   claude.sh --solo-cifrar        encrypt credentials left unencrypted, then exit
#   claude.sh --configurar-token   macOS: create or replace the stored login token
#   claude.sh <arguments>          arguments go to the assistant (for example --version)
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
. "$DIR/../lib/python.sh" || exit 1
exec "$PYTHON" -I -S -B "$DIR/../lib/lanzador.py" claude "$@"

#!/bin/sh
# Updates THIS portable from the internet: downloads the latest official
# versions of the assistants that need it and verifies the installation.
# Sessions and credentials are not touched. See README.md.
#
#   sh actualizar.sh [--si] [--forzar] [--solo-verificar] [--arq todas]
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
. "$DIR/lib/python.sh" || exit 1
exec "$PYTHON" -I -S -B "$DIR/lib/instalar.py" "$DIR" "$@"

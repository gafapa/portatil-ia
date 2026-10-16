#!/bin/sh
# Installs or updates the portable assistants (downloading them from their
# official sources) in a folder or a USB drive, and verifies the result.
# See README.md.
#
#   sh instalar.sh                          interactive
#   sh instalar.sh /media/usb/portatil/linux
#   sh instalar.sh DEST --si | --forzar | --solo-verificar | --arq todas
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
. "$DIR/lib/python.sh" || exit 1
exec "$PYTHON" -I -S -B "$DIR/lib/instalar.py" "$@"

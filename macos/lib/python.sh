# Sourced by the .sh scripts: sets PYTHON to a Python 3.8+ interpreter or
# explains how to install one. POSIX sh (also macOS /bin/sh).

PYTHON=
for candidate in python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python; do
  if command -v "$candidate" >/dev/null 2>&1 &&
     "$candidate" -I -S -B -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    PYTHON=$(command -v "$candidate")
    break
  fi
done

if [ -z "$PYTHON" ]; then
  echo "[portatil] Hace falta Python 3.8 o posterior." >&2
  case "$(uname -s)" in
    Darwin) echo "[portatil] Instalalo con: xcode-select --install" >&2 ;;
    *)      echo "[portatil] Instalalo con el gestor de paquetes (por ejemplo: sudo apt install python3, sudo dnf install python3)." >&2 ;;
  esac
  return 1 2>/dev/null || exit 1
fi

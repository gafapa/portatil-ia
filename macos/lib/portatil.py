# -*- coding: utf-8 -*-
"""Shared core of the portable assistants for Linux and macOS.

Credential encryption, the common portable password, and small helpers
used by lanzador.py (launchers) and instalar.py (installer).

The encrypted format is byte-for-byte the one of the Windows version
(portable-crypto.ps1):

    magic (8 ASCII) | salt (16) | IV (16) | AES-256-CBC ciphertext | HMAC-SHA256 (32)

Keys: PBKDF2-HMAC-SHA256(password UTF-8, salt, 210000 iterations, 64 bytes);
bytes 0-31 encrypt, bytes 32-63 authenticate magic|salt|IV|ciphertext.

Only the Python standard library is used. AES is implemented here because
the standard library has none, and calling the openssl command would put
the key on its command line, visible to other users of the computer.

Requires Python 3.8 or later.
"""

import getpass
import contextlib
import hashlib
import hmac
import os
import sys
import tempfile

PBKDF2_ITERATIONS = 210000
PASSCHECK_FILE = 'portatil.passcheck'
PASSCHECK_MAGIC = 'PORTPW02'
PASSCHECK_VALUE = b'portatil-password-check'
PASSWORD_VARIABLES = ('PORTATIL_PASSWORD',)

# Only operating-system and terminal settings may cross into an assistant.
# An allowlist also blocks credentials from providers we do not know yet.
CHILD_ENVIRONMENT_NAMES = frozenset((
    'PATH', 'PATHEXT', 'SYSTEMROOT', 'WINDIR', 'COMSPEC',
    'LANG', 'LANGUAGE', 'TZ',
    'LC_ALL', 'LC_CTYPE', 'LC_MESSAGES', 'LC_COLLATE', 'LC_NUMERIC',
    'LC_TIME', 'LC_MONETARY', 'LC_PAPER', 'LC_NAME', 'LC_ADDRESS',
    'LC_TELEPHONE', 'LC_MEASUREMENT', 'LC_IDENTIFICATION',
    'TERM', 'COLORTERM', 'TERM_PROGRAM', 'TERM_PROGRAM_VERSION',
    'DISPLAY', 'WAYLAND_DISPLAY',
))


def child_environment(home, inherited=None):
    """Keep essential process settings and use portable credential profiles.

    No provider keys, tokens, endpoint overrides, proxy credentials, agent
    sockets, or authentication helpers are inherited from the host.
    """
    source = os.environ if inherited is None else inherited
    env = {name: value for name, value in source.items()
           if name.upper() in CHILD_ENVIRONMENT_NAMES}
    config = os.path.join(home, '.config')
    temporary = os.path.join(home, 'tmp')
    env.update({
        'TEMP': temporary, 'TMP': temporary, 'TMPDIR': temporary,
        'CLAUDE_CODE_TMPDIR': temporary,
        'XDG_RUNTIME_DIR': os.path.join(home, 'runtime'),
        'HOME': home, 'USERPROFILE': home,
        'APPDATA': config, 'LOCALAPPDATA': os.path.join(home, '.cache'),
        'XDG_CONFIG_HOME': config, 'XDG_DATA_HOME': os.path.join(home, '.local', 'share'),
        'XDG_CACHE_HOME': os.path.join(home, '.cache'),
        'XDG_STATE_HOME': os.path.join(home, '.local', 'state'),
        'AWS_CONFIG_FILE': os.path.join(home, '.aws', 'config'),
        'AWS_SHARED_CREDENTIALS_FILE': os.path.join(home, '.aws', 'credentials'),
        'BOTO_CONFIG': os.path.join(home, '.boto'),
        'BOTO_PATH': os.path.join(home, '.boto'),
        'CLOUDSDK_CONFIG': os.path.join(config, 'gcloud'),
        'AZURE_CONFIG_DIR': os.path.join(home, '.azure'),
        'KUBECONFIG': os.path.join(home, '.kube', 'config'),
        'GIT_CONFIG_GLOBAL': os.path.join(home, '.gitconfig'),
        'GIT_CONFIG_NOSYSTEM': '1',
        'AWS_EC2_METADATA_DISABLED': 'true',
    })
    return env


def require_portable_path(root, path):
    """Reject escapes and existing symlinks/junctions before file access.

    Only links *inside* the portable are refused. The folders above its root
    may legitimately resolve elsewhere (macOS /var -> /private/var, Windows
    8.3 short names such as RUNNER~1), so each component is compared with
    where it should be relative to the resolved root."""
    root = os.path.abspath(root)
    path = os.path.abspath(path)
    try:
        if os.path.commonpath((root, path)) != root:
            raise ValueError('outside portable root')
        real_root = os.path.normcase(os.path.realpath(root))
        is_junction = getattr(os.path, 'isjunction', lambda p: False)
        current = path
        while True:
            if os.path.islink(current) or is_junction(current):
                raise ValueError('linked portable path')
            if os.path.exists(current):
                relative = os.path.relpath(current, root)
                expected = real_root if relative == os.curdir else os.path.join(real_root, os.path.normcase(relative))
                if os.path.normcase(os.path.realpath(current)) != expected:
                    raise ValueError('linked portable path')
            if current == root:
                break
            current = os.path.dirname(current)
    except ValueError:
        raise CredentialError('La ruta debe permanecer dentro del portable y no contener enlaces: %s' % path)
    return path


def validate_portable_tree(root):
    """Refuse existing linked files or directories in a managed tree."""
    require_portable_path(root, root)
    for base, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            require_portable_path(root, os.path.join(base, name))


def temporary_root(root):
    path = require_portable_path(root, os.path.join(root, '.portable-tmp'))
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


@contextlib.contextmanager
def session_lock(root):
    """One credential session per assistant; OS locks recover after crashes."""
    path = require_portable_path(root, os.path.join(root, '.portable-session.lock'))
    os.makedirs(root, exist_ok=True)
    with open(path, 'a+b') as handle:
        if os.name == 'nt':
            import msvcrt
            if os.path.getsize(path) == 0:
                handle.write(b'\0')
                handle.flush()
            handle.seek(0)
            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                raise CredentialError('Ya hay una sesion de este asistente en ejecucion.')
        else:
            import fcntl
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise CredentialError('Ya hay una sesion de este asistente en ejecucion.')
        try:
            yield
        finally:
            if os.name == 'nt':
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


class CredentialError(Exception):
    """Wrong password, damaged file, or unsupported format."""


# ----------------------------------------------------------------------
#  AES-256 (FIPS-197), block encryption and decryption
# ----------------------------------------------------------------------

def _build_tables():
    sbox = [0] * 256
    p = q = 1
    # Walk the multiplicative group of GF(2^8) with generator 3.
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4)
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    inv = [0] * 256
    for i, v in enumerate(sbox):
        inv[v] = i
    return sbox, inv


def _rotl8(x, shift):
    return ((x << shift) | (x >> (8 - shift))) & 0xFF


_SBOX, _INV_SBOX = _build_tables()


def _xtime(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _mul(a, b):
    result = 0
    while b:
        if b & 1:
            result ^= a
        a = _xtime(a)
        b >>= 1
    return result


_MUL = {k: [_mul(i, k) for i in range(256)] for k in (2, 3, 9, 11, 13, 14)}


def _expand_key(key):
    if len(key) != 32:
        raise ValueError('AES-256 needs a 32-byte key')
    words = [list(key[i:i + 4]) for i in range(0, 32, 4)]
    rcon = 1
    for i in range(8, 60):
        t = list(words[i - 1])
        if i % 8 == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= rcon
            rcon = _xtime(rcon)
        elif i % 8 == 4:
            t = [_SBOX[b] for b in t]
        words.append([a ^ b for a, b in zip(words[i - 8], t)])
    return [sum(words[r * 4:r * 4 + 4], []) for r in range(15)]


def _encrypt_block(round_keys, block):
    s = [b ^ k for b, k in zip(block, round_keys[0])]
    m2, m3 = _MUL[2], _MUL[3]
    for rnd in range(1, 15):
        s = [_SBOX[b] for b in s]
        # ShiftRows (column-major state)
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]
        if rnd != 14:
            t = []
            for c in range(4):
                a0, a1, a2, a3 = s[4 * c:4 * c + 4]
                t += [m2[a0] ^ m3[a1] ^ a2 ^ a3, a0 ^ m2[a1] ^ m3[a2] ^ a3,
                      a0 ^ a1 ^ m2[a2] ^ m3[a3], m3[a0] ^ a1 ^ a2 ^ m2[a3]]
            s = t
        s = [b ^ k for b, k in zip(s, round_keys[rnd])]
    return bytes(s)


def _decrypt_block(round_keys, block):
    s = [b ^ k for b, k in zip(block, round_keys[14])]
    m9, m11, m13, m14 = _MUL[9], _MUL[11], _MUL[13], _MUL[14]
    for rnd in range(13, -1, -1):
        # InvShiftRows
        s = [s[(i - 4 * (i % 4)) % 16] for i in range(16)]
        s = [_INV_SBOX[b] for b in s]
        s = [b ^ k for b, k in zip(s, round_keys[rnd])]
        if rnd != 0:
            t = []
            for c in range(4):
                a0, a1, a2, a3 = s[4 * c:4 * c + 4]
                t += [m14[a0] ^ m11[a1] ^ m13[a2] ^ m9[a3], m9[a0] ^ m14[a1] ^ m11[a2] ^ m13[a3],
                      m13[a0] ^ m9[a1] ^ m14[a2] ^ m11[a3], m11[a0] ^ m13[a1] ^ m9[a2] ^ m14[a3]]
            s = t
    return bytes(s)


def _cbc_encrypt(key, iv, data):
    pad = 16 - len(data) % 16
    data = data + bytes([pad]) * pad
    round_keys = _expand_key(key)
    out, prev = bytearray(), iv
    for i in range(0, len(data), 16):
        prev = _encrypt_block(round_keys, bytes(a ^ b for a, b in zip(data[i:i + 16], prev)))
        out += prev
    return bytes(out)


def _cbc_decrypt(key, iv, data):
    if len(data) == 0 or len(data) % 16:
        raise CredentialError('Unsupported portable credential format.')
    round_keys = _expand_key(key)
    out, prev = bytearray(), iv
    for i in range(0, len(data), 16):
        block = data[i:i + 16]
        out += bytes(a ^ b for a, b in zip(_decrypt_block(round_keys, block), prev))
        prev = block
    pad = out[-1]
    if pad < 1 or pad > 16 or out[-pad:] != bytes([pad]) * pad:
        raise CredentialError('The password is incorrect or the credential file is corrupt.')
    return bytes(out[:-pad])


# ----------------------------------------------------------------------
#  Portable encryption format
# ----------------------------------------------------------------------

def _keys(password, salt):
    material = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, PBKDF2_ITERATIONS, 64)
    return material[:32], material[32:]


def protect(plaintext, password, magic):
    """Encrypts bytes with the portable format."""
    if len(magic) != 8:
        raise ValueError('Portable encryption magic must contain exactly 8 ASCII characters.')
    salt, iv = os.urandom(16), os.urandom(16)
    enc_key, mac_key = _keys(password, salt)
    data = magic.encode('ascii') + salt + iv + _cbc_encrypt(enc_key, iv, plaintext)
    return data + hmac.new(mac_key, data, hashlib.sha256).digest()


def unprotect(blob, password, magic):
    """Decrypts bytes of the portable format; CredentialError if wrong."""
    if len(blob) < 88 or blob[:8] != magic.encode('ascii'):
        raise CredentialError('Unsupported portable credential format.')
    enc_key, mac_key = _keys(password, blob[8:24])
    expected = hmac.new(mac_key, blob[:-32], hashlib.sha256).digest()
    if not hmac.compare_digest(expected, blob[-32:]):
        raise CredentialError('The password is incorrect or the credential file is corrupt.')
    return _cbc_decrypt(enc_key, blob[24:40], blob[40:-32])


# ----------------------------------------------------------------------
#  Common password
# ----------------------------------------------------------------------

def pop_env_password(extra_names=()):
    """Reads the password variables and removes them from the environment,
    so the assistant never inherits them."""
    found = None
    for name in PASSWORD_VARIABLES + tuple(extra_names):
        value = os.environ.pop(name, None)
        if found is None and value:
            found = value
    return found


def _read_secret(prompt):
    try:
        value = getpass.getpass(prompt + ': ')
    except (EOFError, KeyboardInterrupt):
        print('')
        raise CredentialError('No se introdujo ninguna contrasena.')
    if not value:
        raise CredentialError('No se introdujo ninguna contrasena.')
    return value


def passcheck_path(root):
    return os.path.join(root, PASSCHECK_FILE)


def test_password(root, password):
    try:
        with open(passcheck_path(root), 'rb') as f:
            return unprotect(f.read(), password, PASSCHECK_MAGIC) == PASSCHECK_VALUE
    except (OSError, CredentialError):
        return False


def register_password(root, password):
    """Records the common password if none is recorded yet."""
    path = passcheck_path(root)
    if not os.path.exists(path):
        write_private(path, protect(PASSCHECK_VALUE, password, PASSCHECK_MAGIC))


def get_password(root, tool, provided=None, for_new_credentials=False):
    """Returns the common password.

    provided             value from the command line or the environment
    for_new_credentials  credentials are about to be saved for the first
                         time; without a common password yet, ask twice
    """
    if os.path.exists(passcheck_path(root)):
        if provided is not None:
            if test_password(root, provided):
                return provided
            raise CredentialError('La contrasena proporcionada no es la contrasena comun del portable.')
        for _ in range(3):
            candidate = _read_secret('[%s] Contrasena del portable' % tool)
            if test_password(root, candidate):
                return candidate
            print('  Contrasena incorrecta.')
        raise CredentialError('Contrasena incorrecta.')

    if provided is not None:
        if for_new_credentials:
            register_password(root, provided)
        return provided
    if not for_new_credentials:
        # Stored before portatil.passcheck existed: decrypting validates it.
        return _read_secret('[%s] Contrasena del portable' % tool)

    print('')
    print('[%s] Es la primera vez que se guardan credenciales en este portable.' % tool)
    print('[%s] Elige la contrasena comun: la usaran los cuatro asistentes.' % tool)
    while True:
        first = _read_secret('Nueva contrasena del portable')
        second = _read_secret('Repite la contrasena')
        if hmac.compare_digest(first.encode('utf-8'), second.encode('utf-8')):
            register_password(root, first)
            return first
        print('  Las contrasenas no coinciden. Intentalo de nuevo.')


# ----------------------------------------------------------------------
#  Files
# ----------------------------------------------------------------------

def write_private(path, data):
    """Writes bytes readable only by the current user (mode 0600). File
    systems without permissions (exFAT, FAT) ignore the mode."""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix='.portable-save-', dir=parent or '.')
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            remove_quietly(temporary)


def remove_quietly(path):
    try:
        os.remove(path)
    except OSError:
        pass


def host_system():
    """'linux', 'macos', or another name."""
    if sys.platform.startswith('linux'):
        return 'linux'
    if sys.platform == 'darwin':
        return 'macos'
    return sys.platform


def host_arch():
    """'x64', 'arm64', or the raw machine name."""
    import platform
    machine = platform.machine().lower()
    if machine in ('x86_64', 'amd64'):
        return 'x64'
    if machine in ('aarch64', 'arm64'):
        return 'arm64'
    return machine

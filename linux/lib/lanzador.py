# -*- coding: utf-8 -*-
"""Portable launcher for Linux and macOS.

Usage (through the assistant's .sh script):
    lanzador.py <assistant> [--espacio NAME] [--solo-cifrar] [--configurar-token] [assistant arguments...]

Lifecycle (same as the Windows launchers):
  1. take the password from PORTATIL_PASSWORD and remove the variable;
  2. redirect all the assistant's state into its folder;
  3. encrypt credentials left in the clear by an interrupted session;
  4. decrypt the credentials for this session (common password);
  5. choose a workspace and run the program;
  6. on exit, encrypt the credentials and remove the plain copies.

Credentials of each assistant are kept together in <assistant>/credenciales.enc.
See docs/ARCHITECTURE.md in the project for the details.
"""

import base64
import json
import os
import re
import shutil
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import portatil  # noqa: E402

ROOT = os.path.dirname(HERE)          # the portatil/<system> folder
SYSTEM = portatil.host_system()

# Tests may replace these module attributes in their disposable harness.
# Host environment variables cannot replace programs or credential stores.
_TEST_PROGRAM = None
_TEST_SECURITY = None

INFO_ARGS = ('--version', '-v', '-V', '--help', '-h', 'help', 'version')
BUNDLE_FORMAT = 'portatil-2'


# ----------------------------------------------------------------------
#  Assistants
# ----------------------------------------------------------------------
# state(t)   environment variables that move the state into folder t
# secrets    credential files, relative to the assistant folder
# workspaces folder of the workspaces
# magic      8-character tag of the encrypted file

def _claude_state(t):
    return {'CLAUDE_CONFIG_DIR': os.path.join(t, 'data', 'claude'),
            'DISABLE_AUTOUPDATER': '1', 'CLAUDE_NO_UPDATE_NOTIFIER': '1'}


def _codex_state(t):
    return {'CODEX_HOME': os.path.join(t, 'data', 'codex')}


def _oc_state(t):
    return {'XDG_DATA_HOME': os.path.join(t, 'data'), 'XDG_CONFIG_HOME': os.path.join(t, 'config'),
            'XDG_CACHE_HOME': os.path.join(t, 'cache'), 'XDG_STATE_HOME': os.path.join(t, 'state'),
            'OPENCODE_DISABLE_AUTOUPDATE': '1'}


def _agy_state(t):
    home = os.path.join(t, 'data')
    return {'HOME': home, 'XDG_CONFIG_HOME': os.path.join(t, 'config'), 'XDG_CACHE_HOME': os.path.join(t, 'cache'),
            'XDG_DATA_HOME': os.path.join(home, '.local', 'share'), 'XDG_STATE_HOME': os.path.join(home, '.local', 'state'),
            'AGY_CLI_DISABLE_AUTO_UPDATE': '1'}


TOOLS = {
    'claude': {'name': 'Claude Code', 'folder': 'claude', 'exe': 'claude', 'magic': 'PORTCC02',
               'state': _claude_state, 'secrets': ['data/claude/.credentials.json'],
               'workspaces': 'sesiones', 'login': '/login'},
    'codex': {'name': 'Codex', 'folder': 'codex', 'exe': 'bin/codex', 'magic': 'PORTCX02',
              'state': _codex_state, 'secrets': ['data/codex/auth.json', 'data/codex/.credentials.json'],
              'workspaces': 'workspaces', 'login': 'codex login (o cuando Codex lo pida)'},
    'oc': {'name': 'OpenCode', 'folder': 'oc', 'exe': 'opencode', 'magic': 'PORTOC02',
           'state': _oc_state, 'secrets': ['data/opencode/auth.json', 'data/opencode/mcp-auth.json'],
           'workspaces': 'sesiones', 'login': '/connect'},
    'antigravity': {'name': 'Antigravity', 'folder': 'antigravity', 'exe': 'antigravity', 'magic': 'PORTAG02',
                    'state': _agy_state, 'secrets': [],
                    'workspaces': 'sesiones', 'login': 'el inicio de sesion de Google en el navegador'},
}

# Antigravity keeps its login in the OS keyring; without one it falls back
# to files in its (redirected) home. The file names are not documented, so
# credential-looking files under these folders are treated as secrets.
AGY_SECRET_ROOTS = ['data/.gemini', 'data/.config', 'data/.local/share', 'config']
AGY_SECRET_NAME = re.compile(r'(oauth|token|credential|keyring|account|auth)', re.I)

# macOS: Claude Code stores /login in the Mac's Keychain and has no option to
# use a file; the portable uses a long-lived token instead (setup-token).
CLAUDE_TOKEN_ENV = 'CLAUDE_CODE_OAUTH_TOKEN'
# macOS: Antigravity's Keychain item, moved in and out like on Windows.
AGY_KEYCHAIN_SERVICE = 'gemini'
AGY_KEYCHAIN_ACCOUNT = 'antigravity'
KEYCHAIN_BACKUP_ACCOUNT = 'portatil-respaldo:' + AGY_KEYCHAIN_ACCOUNT
KEYCHAIN_PENDING_ACCOUNT = 'portatil-pendiente:' + AGY_KEYCHAIN_ACCOUNT


def say(tool, text):
    print('[%s] %s' % (tool, text))


def err(tool, text):
    sys.stderr.write('[%s] %s\n' % (tool, text))


# ----------------------------------------------------------------------
#  macOS Keychain (Antigravity)
# ----------------------------------------------------------------------

def _security(args, stdin=None):
    if not _TEST_SECURITY:
        raise portatil.CredentialError('El acceso al llavero del equipo esta deshabilitado.')
    base = json.loads(_TEST_SECURITY)
    return subprocess.run(base + args, input=stdin, capture_output=True)


def keychain_get(account):
    r = _security(['find-generic-password', '-s', AGY_KEYCHAIN_SERVICE, '-a', account, '-w'])
    if r.returncode != 0:
        return None
    return r.stdout.rstrip(b'\n')


def keychain_set(account, secret):
    # Through 'security -i' so the secret never appears on a command line;
    # -X takes it hex-encoded (as Antigravity's keyring library does).
    command = 'add-generic-password -U -s %s -a %s -X %s\n' % (AGY_KEYCHAIN_SERVICE, account, secret.hex())
    r = _security(['-i'], stdin=command.encode('ascii'))
    if r.returncode != 0 or keychain_get(account) != secret:
        raise portatil.CredentialError('no se pudo escribir en el Llavero')


def keychain_delete(account):
    _security(['delete-generic-password', '-s', AGY_KEYCHAIN_SERVICE, '-a', account])


# ----------------------------------------------------------------------
#  Launcher
# ----------------------------------------------------------------------

class Launcher:
    def __init__(self, key, args):
        self.key = key
        self.spec = TOOLS[key]
        self.tool = self.spec['folder']
        self.dir = os.path.join(ROOT, self.tool)
        self.enc = os.path.join(self.dir, 'credenciales.enc')
        self.password = None
        self.provided = portatil.pop_env_password(['%s_PASSWORD' % key.upper()])
        self.workspace = None
        self.encrypt_only = False
        self.setup_token = False
        self.args = []
        i = 0
        while i < len(args):
            a = args[i]
            if a == '--espacio' and i + 1 < len(args):
                self.workspace = args[i + 1]
                i += 2
                continue
            if a == '--solo-cifrar':
                self.encrypt_only = True
            elif a == '--configurar-token':
                self.setup_token = True
            else:
                self.args.append(a)
            i += 1
        self.token_mode = key == 'claude' and SYSTEM == 'macos'
        self.keychain_mode = False  # Native host credential stores are disabled.
        self.token = None
        # The live Keychain item is the portable's only after the Mac's own
        # item has been set aside; until then it belongs to the Mac.
        self.host_set_aside = False

    # --- program ------------------------------------------------------

    def program_dir(self):
        arch = portatil.host_arch()
        candidates = [arch]
        if SYSTEM == 'macos' and arch == 'arm64':
            candidates.append('x64')   # runs under Rosetta 2
        for a in candidates:
            d = os.path.join(self.dir, 'prog', a)
            if os.path.exists(os.path.join(d, self.spec['exe'])):
                return d
        return None

    def runnable_program(self, prog):
        """Path of the executable, made runnable. Drives mounted without
        execute permission (FAT 'showexec', 'noexec') cannot run programs:
        then the program is copied once to a private folder of this PC."""
        exe = os.path.join(prog, self.spec['exe'])
        if _TEST_PROGRAM or (os.access(exe, os.X_OK) and not _noexec(exe)):
            return exe, prog
        try:
            for base, _, files in os.walk(prog):
                for f in files:
                    p = os.path.join(base, f)
                    os.chmod(p, os.stat(p).st_mode | 0o755)
        except OSError:
            pass
        if os.access(exe, os.X_OK) and not _noexec(exe):
            return exe, prog
        raise portatil.CredentialError('La unidad no permite ejecutar programas. No se copiara nada al equipo; usa una unidad con permiso de ejecucion.')

    def environment(self, prog):
        env = portatil.child_environment(os.path.join(self.dir, 'data'))
        env.update(self.spec['state'](self.dir))
        for name in ('TEMP', 'TMP', 'TMPDIR', 'XDG_RUNTIME_DIR'):
            portatil.require_portable_path(ROOT, env[name])
            os.makedirs(env[name], mode=0o700, exist_ok=True)
        for v in self.spec['state'](self.dir).values():
            if v.startswith(self.dir):
                os.makedirs(v, exist_ok=True)
        if self.key == 'codex':
            env['PATH'] = os.path.join(prog, 'codex-path') + os.pathsep + env.get('PATH', '')
            env['CODEX_SQLITE_HOME'] = env['CODEX_HOME']
        if self.key == 'antigravity' and SYSTEM == 'linux':
            # Without a D-Bus session Antigravity skips the keyring and keeps
            # its login in files under its (portable) home.
            env.pop('DBUS_SESSION_BUS_ADDRESS', None)
        if self.token_mode and self.token:
            env[CLAUDE_TOKEN_ENV] = self.token
        return env

    # --- credentials ----------------------------------------------------

    def codex_options(self):
        """Enforce portable storage without rewriting arbitrary user TOML."""
        home = os.path.join(self.dir, 'data', 'codex')
        return ['-c', 'cli_auth_credentials_store="file"',
                '-c', 'mcp_oauth_credentials_store="file"',
                '-c', 'sqlite_home=' + json.dumps(home),
                '-c', 'log_dir=' + json.dumps(os.path.join(home, 'logs'))]

    def validate_codex_arguments(self):
        reserved = {'cli_auth_credentials_store', 'mcp_oauth_credentials_store',
                    'sqlite_home', 'log_dir', 'codex_home'}
        index = 0
        while index < len(self.args):
            argument = self.args[index]
            if argument == '--':
                break
            value = None
            if argument in ('-c', '--config'):
                index += 1
                if index < len(self.args):
                    value = self.args[index]
            elif argument.startswith('--config='):
                value = argument[len('--config='):]
            elif argument.startswith('-c') and len(argument) > 2:
                value = argument[2:]
            if value is not None:
                key = value.split('=', 1)[0].replace('"', '').replace("'", '').strip()
                if any(part.strip() in reserved for part in key.split('.')):
                    raise portatil.CredentialError('Portable Codex storage settings cannot be overridden: ' + key)
            index += 1

    def secret_files(self):
        """Credential files present now, relative to the assistant folder."""
        found = [s for s in self.spec['secrets'] if os.path.isfile(os.path.join(self.dir, s))]
        if self.key == 'antigravity':
            for root in AGY_SECRET_ROOTS:
                top = os.path.join(self.dir, root)
                if not os.path.isdir(top):
                    continue
                for base, dirs, files in os.walk(top):
                    if base[len(top):].count(os.sep) >= 3:
                        dirs[:] = []
                    for f in files:
                        p = os.path.join(base, f)
                        if AGY_SECRET_NAME.search(f) and not f.endswith('.enc') and os.path.getsize(p) < 1024 * 1024:
                            rel = os.path.relpath(p, self.dir).replace(os.sep, '/')
                            if rel not in found:
                                found.append(rel)
        return found

    def keychain_live(self):
        if not self.keychain_mode or not self.host_set_aside:
            return None
        return keychain_get(AGY_KEYCHAIN_ACCOUNT)

    def has_leftovers(self):
        if self.keychain_mode and keychain_get(KEYCHAIN_PENDING_ACCOUNT) is not None:
            return True
        return bool(self.secret_files())

    def bundle(self, keychain_secret=None):
        files = {}
        for rel in self.secret_files():
            with open(os.path.join(self.dir, rel), 'rb') as f:
                files[rel] = base64.b64encode(f.read()).decode('ascii')
        data = {'formato': BUNDLE_FORMAT, 'archivos': files}
        if self.token_mode and self.token:
            data['token'] = self.token
        if keychain_secret is not None:
            data['llavero'] = base64.b64encode(keychain_secret).decode('ascii')
        return json.dumps(data, indent=1).encode('utf-8')

    def restore_bundle(self, plain):
        data = json.loads(plain.decode('utf-8'))
        kept = []
        for rel, content in data.get('archivos', {}).items():
            target = portatil.require_portable_path(self.dir, os.path.join(self.dir, rel))
            if os.path.exists(target):
                # Left by a session that ended abruptly: newer than the
                # encrypted copy (for example a refreshed token). Keep it;
                # it is encrypted when this session ends.
                kept.append(rel)
                continue
            portatil.write_private(target, base64.b64decode(content))
        if kept:
            say(self.tool, 'Se conservan credenciales mas recientes de una sesion anterior: %s' % ', '.join(kept))
        self.token = data.get('token') or self.token
        return base64.b64decode(data['llavero']) if data.get('llavero') else None

    def ensure_password(self, for_new):
        if self.password is None:
            if for_new:
                say(self.tool, 'Guardando las credenciales en el portable.')
            self.password = portatil.get_password(ROOT, self.tool, self.provided, for_new)
        return self.password

    def protect(self):
        """Encrypts what the session left and removes the plain copies. On
        failure the plain copies are kept (Keychain: as 'pendiente') and
        are encrypted on the next start."""
        live = self.keychain_live()
        pending = keychain_get(KEYCHAIN_PENDING_ACCOUNT) if self.keychain_mode else None
        files = self.secret_files()
        token_new = self.token_mode and self.token and not os.path.exists(self.enc)
        try:
            if live is None and pending is None and not files and not token_new and not (self.key == 'codex' and os.path.exists(self.enc)):
                return True
            try:
                self.ensure_password(for_new=True)
                secret = live if live is not None else pending
                portatil.write_private(self.enc, portatil.protect(self.bundle(secret), self.password, self.spec['magic']))
                for rel in files:
                    os.remove(os.path.join(self.dir, rel))
                if live is not None:
                    keychain_delete(AGY_KEYCHAIN_ACCOUNT)
                if pending is not None:
                    keychain_delete(KEYCHAIN_PENDING_ACCOUNT)
            except (portatil.CredentialError, OSError) as e:
                if live is not None:
                    try:
                        keychain_set(KEYCHAIN_PENDING_ACCOUNT, live)
                        keychain_delete(AGY_KEYCHAIN_ACCOUNT)
                    except portatil.CredentialError:
                        pass
                err(self.tool, 'No se pudieron cifrar las credenciales: %s' % e)
                err(self.tool, 'Quedan sin cifrar y se cifraran en el proximo arranque.')
                return False
        finally:
            self.restore_host_keychain()
        return True

    def save_host_keychain(self):
        """Moves the Mac's own Antigravity login aside during the session.
        Raises CredentialError if it cannot; then nothing is treated as the
        portable's and the Mac's item is left untouched."""
        if not self.keychain_mode:
            return
        host = keychain_get(AGY_KEYCHAIN_ACCOUNT)
        if host is not None and keychain_get(KEYCHAIN_BACKUP_ACCOUNT) is None:
            keychain_set(KEYCHAIN_BACKUP_ACCOUNT, host)
            keychain_delete(AGY_KEYCHAIN_ACCOUNT)
            if keychain_get(AGY_KEYCHAIN_ACCOUNT) is not None:
                raise portatil.CredentialError('no se pudo apartar el login del Mac en el Llavero')
        self.host_set_aside = True

    def restore_host_keychain(self):
        if not self.keychain_mode:
            return
        backup = keychain_get(KEYCHAIN_BACKUP_ACCOUNT)
        if backup is not None:
            keychain_set(AGY_KEYCHAIN_ACCOUNT, backup)
            keychain_delete(KEYCHAIN_BACKUP_ACCOUNT)
        self.host_set_aside = False

    # --- Claude on macOS ------------------------------------------------

    def configure_token(self, exe, env):
        say(self.tool, 'En macOS, Claude Code guarda /login en el Llavero del Mac y ese login no viajaria')
        say(self.tool, 'en el pendrive. El portable usa en su lugar un token de un ano (claude setup-token).')
        say(self.tool, 'Limitacion: con el token no funcionan los conectores de claude.ai ni Remote Control.')
        print('')
        say(self.tool, 'Se abre ahora "claude setup-token": autoriza en el navegador y copia el token que muestre.')
        try:
            sys.stdout.flush()
            subprocess.run(program_command(exe) + ['setup-token'], env=env)
        except OSError as e:
            err(self.tool, 'No se pudo ejecutar claude setup-token: %s' % e)
        print('')
        token = ''
        if sys.stdin.isatty():
            try:
                import getpass
                token = getpass.getpass('[%s] Pega aqui el token (no se vera; Enter en blanco cancela): ' % self.tool).strip()
            except (EOFError, KeyboardInterrupt):
                token = ''
        else:
            err(self.tool, 'No hay una terminal interactiva para pegar el token.')
        if not token:
            err(self.tool, 'Sin token no se arranca Claude Code. Repite con: claude.sh --configurar-token')
            return False
        if not token.startswith('sk-ant-'):
            err(self.tool, 'Eso no parece un token de Claude (empieza por sk-ant-).')
            return False
        self.token = token
        try:
            self.ensure_password(for_new=True)
            portatil.write_private(self.enc, portatil.protect(self.bundle(), self.password, self.spec['magic']))
        except portatil.CredentialError as e:
            err(self.tool, 'No se pudo guardar el token: %s' % e)
            return False
        say(self.tool, 'Token guardado cifrado en el portable.')
        return True

    # --- workspaces -----------------------------------------------------

    def choose_workspace(self):
        root = os.path.join(self.dir, self.spec['workspaces'])
        if self.workspace is not None:
            if not self.workspace.strip() or re.search(r'[\\/:*?"<>|]', self.workspace) or self.workspace in ('.', '..'):
                err(self.tool, 'Nombre de espacio de trabajo invalido: %s' % self.workspace)
                return False
            path = os.path.join(root, self.workspace)
            if not os.path.isdir(path):
                os.makedirs(path)
                say(self.tool, 'Carpeta creada: %s/%s' % (self.spec['workspaces'], self.workspace))
            return path
        if self.args:
            return None
        os.makedirs(root, exist_ok=True)
        existing = sorted((d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))),
                          key=lambda d: os.path.getmtime(os.path.join(root, d)), reverse=True)
        print('')
        say(self.tool, 'Espacios de trabajo (%s/):' % self.spec['workspaces'])
        print('')
        for i, name in enumerate(existing, 1):
            print('  %d) %s' % (i, name))
        new_index = len(existing) + 1
        print('  %d) Crear nuevo espacio de trabajo' % new_index)
        print('')
        print('  Enter en blanco = salir sin abrir %s' % self.spec['name'])
        while True:
            try:
                sel = input('Seleccion: ').strip()
            except (EOFError, KeyboardInterrupt):
                print('')
                sel = ''
            if not sel:
                return False
            if sel.isdigit() and 1 <= int(sel) <= len(existing):
                return os.path.join(root, existing[int(sel) - 1])
            if sel.isdigit() and int(sel) == new_index:
                while True:
                    try:
                        name = input('Nombre del espacio de trabajo: ').strip()
                    except (EOFError, KeyboardInterrupt):
                        return False
                    if not name or re.search(r'[\\/:*?"<>|]', name) or name in ('.', '..'):
                        print('  Nombre no valido (no puede estar vacio ni contener \\ / : * ? " < > |).')
                        continue
                    path = os.path.join(root, name)
                    os.makedirs(path, exist_ok=True)
                    return path
            print('  Opcion no valida. Intentalo de nuevo.')

    # --- main -----------------------------------------------------------

    def run(self):
        portatil.validate_portable_tree(self.dir)
        if self.key == 'codex':
            self.validate_codex_arguments()
        if self.key == 'antigravity' and not (self.args and all(a in INFO_ARGS for a in self.args)):
            raise portatil.CredentialError('Antigravity OAuth usa el llavero del equipo. Este modo esta bloqueado para mantener las credenciales solo en el portable.')
        informational = self.args and all(a in INFO_ARGS for a in self.args) and not self.setup_token
        if informational:
            return self.run_session()
        with portatil.session_lock(self.dir):
            return self.run_session()

    def run_session(self):
        prog = self.program_dir()
        if prog is None:
            err(self.tool, 'Falta el programa de %s para este equipo (%s %s).' % (self.spec['name'], SYSTEM, portatil.host_arch()))
            err(self.tool, 'Descargalo ejecutando actualizar.sh en la carpeta del portable (necesita internet).')
            return 1

        # Informational commands run without credentials.
        if self.args and all(a in INFO_ARGS for a in self.args) and not self.setup_token:
            exe, run_dir = self.runnable_program(prog)
            sys.stdout.flush()
            return subprocess.run(program_command(exe) + self.args, env=self.environment(run_dir), cwd=self.dir).returncode

        # A Mac session that ended abruptly leaves the Mac's login set aside.
        if self.keychain_mode and keychain_get(KEYCHAIN_BACKUP_ACCOUNT) is not None:
            live = keychain_get(AGY_KEYCHAIN_ACCOUNT)
            if live is not None:
                keychain_set(KEYCHAIN_PENDING_ACCOUNT, live)
                keychain_delete(AGY_KEYCHAIN_ACCOUNT)
            self.restore_host_keychain()

        if self.has_leftovers():
            say(self.tool, 'Hay credenciales sin cifrar de una sesion anterior.')
            if os.path.exists(self.enc):
                try:
                    self.ensure_password(for_new=False)
                    with open(self.enc, 'rb') as f:
                        previous = portatil.unprotect(f.read(), self.password, self.spec['magic'])
                except portatil.CredentialError as e:
                    err(self.tool, 'No se pudieron descifrar las credenciales: %s' % e)
                    return 2
                # The store is rewritten below: bring back what it holds
                # (files already present are newer and are kept) so nothing
                # in it is lost. Its Keychain item is older than the pending one.
                self.restore_bundle(previous)
            self.save_host_keychain()
            self.protect()
            if self.has_leftovers():
                return 1
            if self.encrypt_only:
                say(self.tool, 'Credenciales cifradas en credenciales.enc. No se arranca %s.' % self.spec['name'])
                return 0
        if self.encrypt_only:
            say(self.tool, 'No hay credenciales en claro que cifrar.')
            return 0

        keychain_secret = None
        if os.path.exists(self.enc):
            try:
                self.ensure_password(for_new=False)
                with open(self.enc, 'rb') as f:
                    plain = portatil.unprotect(f.read(), self.password, self.spec['magic'])
            except portatil.CredentialError as e:
                err(self.tool, 'No se pudieron descifrar las credenciales: %s' % e)
                err(self.tool, 'Contrasena incorrecta o archivo corrupto. Abortando.')
                return 2
            portatil.register_password(ROOT, self.password)
            keychain_secret = self.restore_bundle(plain)
        elif not self.args and not self.token_mode:
            say(self.tool, 'Este portable aun no tiene credenciales: inicia sesion con %s.' % self.spec['login'])
            say(self.tool, 'Al salir se te pedira la contrasena del portable para guardarlas cifradas.')

        exe, run_dir = self.runnable_program(prog)
        if self.token_mode and (self.setup_token or not self.token):
            if not self.configure_token(exe, self.environment(run_dir)):
                return 1
            if self.setup_token:
                return 0

        code = 0
        try:
            self.save_host_keychain()
            if keychain_secret is not None:
                keychain_set(AGY_KEYCHAIN_ACCOUNT, keychain_secret)
            workspace = self.choose_workspace()
            if workspace is False:
                say(self.tool, 'Cancelado.')
                return 0 if self.workspace is None else 1
            cmd = program_command(exe)
            if self.key == 'codex':
                # Global options: before the subcommand, never after the
                # user's arguments (they would end up in "mcp add ... -- <command>").
                cmd += self.codex_options()
                if workspace:
                    cmd += ['-C', workspace]
            cmd += self.args
            if workspace:
                say(self.tool, 'Abriendo sesion en: %s' % os.path.basename(workspace))
                print('')
            sys.stdout.flush()
            code = run_child(cmd, workspace or self.dir, self.environment(run_dir))
        finally:
            if not self.protect():
                raise portatil.CredentialError('No se pudieron proteger las credenciales del portable.')
        return code


def _noexec(path):
    """True on Linux when the file is on a file system mounted noexec."""
    if SYSTEM != 'linux':
        return False
    try:
        best, options = '', ''
        with open('/proc/self/mounts') as f:
            for line in f:
                parts = line.split()
                mount = parts[1].replace('\\040', ' ')
                if path.startswith(mount.rstrip('/') + '/') and len(mount) > len(best):
                    best, options = mount, parts[3]
        return 'noexec' in options.split(',')
    except OSError:
        return False


def program_command(exe):
    return json.loads(_TEST_PROGRAM) if _TEST_PROGRAM else [exe]


def run_child(cmd, cwd, env):
    """Runs the assistant in the foreground. Ctrl+C and closing the
    terminal reach the assistant; this process waits for it so that the
    credentials are always encrypted afterwards."""
    previous = {}
    # POSIX only: this launcher targets Linux and macOS (on Windows, used
    # just for tests, changing these handlers is not needed).
    for name in ('SIGINT', 'SIGQUIT', 'SIGTERM', 'SIGHUP') if os.name == 'posix' else ():
        sig = getattr(signal, name, None)
        if sig is not None:
            previous[sig] = signal.signal(sig, signal.SIG_IGN)
    try:
        extra = {}
        if os.name == 'posix':
            extra['preexec_fn'] = lambda: [signal.signal(s, signal.SIG_DFL) for s in previous]
        child = subprocess.Popen(cmd, cwd=cwd, env=env, **extra)
        while True:
            try:
                return child.wait()
            except InterruptedError:
                continue
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main(argv):
    if len(argv) < 2 or argv[1] not in TOOLS:
        sys.stderr.write('Uso: lanzador.py <%s> [argumentos]\n' % '|'.join(sorted(TOOLS)))
        return 1
    try:
        with open(os.path.join(ROOT, 'portatil-programa.json'), encoding='utf-8') as f:
            expected = json.load(f).get('system')
    except (OSError, ValueError):
        expected = None
    if expected and expected != SYSTEM:
        sys.stderr.write('Esta es la version del portable para %s; en este equipo (%s) usa la de %s.\n' % (expected, SYSTEM, SYSTEM))
        return 1
    try:
        return Launcher(argv[1], argv[2:]).run()
    except portatil.CredentialError as e:
        sys.stderr.write('[%s] %s\n' % (argv[1], e))
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))

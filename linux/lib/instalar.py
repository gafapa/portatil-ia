# -*- coding: utf-8 -*-
"""Installs or updates the portable assistants for Linux or macOS by
downloading them from their official sources, and verifies the result.

Usage (through instalar.sh or actualizar.sh):
    instalar.py [DEST] [--si] [--forzar] [--solo-verificar] [--arq actual|x64|arm64|todas]

Each assistant is downloaded from the source in portatil-programa.json and
checked against the hash its publisher releases before it is installed.
Only the scripts are copied from the folder of this installer. Sessions,
credentials, and the password of the destination are never touched.

After installing (and with --solo-verificar) it checks:
  - every program file matches the verified download (versiones.json)
  - no unexpected files in the program folders
  - the scripts are present and compile
  - the credential encryption works
  - the programs start on this computer and report the installed version
  - the credential state of each assistant

Exit code: 0 correct, 1 not started, 2 problems found.
Requires Python 3.8 or later; downloads use curl when available.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import portatil  # noqa: E402

ARCHES = ('x64', 'arm64')
SIZE_FACTOR = 3            # archives grow roughly 3x when unpacked
UNKNOWN_SIZE = 250 * 1024 * 1024
MARGIN = 200 * 1024 * 1024


# ----------------------------------------------------------------------
#  Output
# ----------------------------------------------------------------------

class Report:
    COLORS = {'OK': '32', 'AVISO': '33', 'FALLO': '31', 'INFO': '36'}

    def __init__(self):
        self.failures = []
        self.warnings = []
        self.color = sys.stdout.isatty() and os.environ.get('TERM') != 'dumb'

    def line(self, status, text):
        label = '[%-5s]' % status
        if self.color:
            label = '\033[%sm%s\033[0m' % (self.COLORS.get(status, '0'), label)
        print('  %s %s' % (label, text))
        if status == 'FALLO':
            self.failures.append(text)
        elif status == 'AVISO':
            self.warnings.append(text)


def fmt_size(n):
    if n >= 1024 ** 3:
        return '%.1f GB' % (n / 1024.0 ** 3)
    if n >= 1024 ** 2:
        return '%d MB' % (n // 1024 ** 2)
    return '%d KB' % (n // 1024)


def ask_yes_no(prompt, default=True):
    suffix = '[S/n]' if default else '[s/N]'
    while True:
        try:
            answer = input('%s %s ' % (prompt, suffix)).strip().lower()
        except EOFError:
            return default
        if not answer:
            return default
        if answer in ('s', 'si', 'y', 'yes'):
            return True
        if answer in ('n', 'no'):
            return False


# ----------------------------------------------------------------------
#  Manifest, inventory, files
# ----------------------------------------------------------------------

def load_manifest(root):
    with open(os.path.join(root, 'portatil-programa.json'), encoding='utf-8') as f:
        return json.load(f)


def is_portable(path):
    return os.path.isfile(os.path.join(path, 'portatil-programa.json')) and os.path.isfile(os.path.join(path, 'lib', 'lanzador.py'))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def script_files(manifest):
    files = list(manifest['rootFiles'])
    for tool in sorted(manifest['tools']):
        files += ['%s/%s' % (tool, name) for name in manifest['tools'][tool]['launchers']]
    return files


def program_files(base, tool, arch):
    """Program files of one assistant and architecture, relative to base."""
    top = os.path.join(base, tool, 'prog', arch)
    out = []
    for d, _, files in os.walk(top):
        for f in files:
            out.append(os.path.relpath(os.path.join(d, f), base).replace(os.sep, '/'))
    return sorted(out)


def read_inventory(dest):
    try:
        with open(os.path.join(dest, 'versiones.json'), encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_inventory(dest, inventory):
    data = json.dumps(inventory, indent=2, sort_keys=True, ensure_ascii=False).encode('utf-8')
    tmp = os.path.join(dest, 'versiones.json.tmp')
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, os.path.join(dest, 'versiones.json'))


def make_executable(path):
    try:
        os.chmod(path, os.stat(path).st_mode | 0o755)
    except OSError:
        pass       # exFAT/FAT: no permissions; lanzador.py handles it


# ----------------------------------------------------------------------
#  Downloads
# ----------------------------------------------------------------------

def http_get_json(url, headers=None):
    headers = headers or {}
    curl = shutil.which('curl')
    if curl:
        cmd = [curl, '-q', '-fsSL', '--retry', '3', '--retry-delay', '2', '--max-time', '60']
        for k, v in headers.items():
            cmd += ['-H', '%s: %s' % (k, v)]
        r = subprocess.run(cmd + [url], capture_output=True, env=portatil.child_environment(SOURCE))
        if r.returncode != 0:
            raise RuntimeError('no se pudo consultar %s (curl %d)' % (url, r.returncode))
        body = r.stdout
    else:
        import urllib.request
        req = urllib.request.Request(url, headers=headers)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=60) as resp:
            body = resp.read()
    text = body.decode('utf-8').strip()
    try:
        return json.loads(text)
    except ValueError:
        return text


def download(url, out):
    curl = shutil.which('curl')
    if curl:
        r = subprocess.run([curl, '-q', '-fL', '--retry', '3', '--retry-delay', '2', '--progress-bar', '-o', out, url],
                           env=portatil.child_environment(os.path.dirname(out)))
        if r.returncode != 0:
            raise RuntimeError('la descarga fallo (curl %d)' % r.returncode)
    else:
        import urllib.request
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=600) as resp, open(out, 'wb') as f:
            shutil.copyfileobj(resp, f)


def is_musl():
    if portatil.host_system() != 'linux':
        return False
    for d in ('/lib', '/usr/lib'):
        try:
            if any(n.startswith('ld-musl-') for n in os.listdir(d)):
                return True
        except OSError:
            pass
    return False


def latest_release(spec, arch, musl):
    """Latest official release: version, URL, expected hash, size."""
    src = spec['source']
    kind = src['type']
    if kind == 'claude':
        version = http_get_json('%s/%s' % (src['baseUrl'], src['channel']))
        if not isinstance(version, str) or not re.match(r'^\d+\.\d+\.\d+', version):
            raise RuntimeError('respuesta inesperada del servidor de versiones: %r' % (version,))
        manifest = http_get_json('%s/%s/manifest.json' % (src['baseUrl'], version))
        platform = (src.get('platformMusl') if musl and src.get('platformMusl') else src['platform'])[arch]
        p = manifest.get('platforms', {}).get(platform)
        if not p or not p.get('checksum'):
            raise RuntimeError('el manifiesto de %s no incluye %s' % (version, platform))
        return {'version': version, 'url': '%s/%s/%s/%s' % (src['baseUrl'], version, platform, p['binary']),
                'hash': p['checksum'].lower(), 'algorithm': 'sha256', 'size': int(p.get('size') or 0),
                'filename': p['binary']}
    if kind == 'github':
        release = http_get_json('https://api.github.com/repos/%s/releases/latest' % src['repo'],
                                {'User-Agent': 'portatil-instalar', 'Accept': 'application/vnd.github+json'})
        name = (src.get('assetMusl') if musl and src.get('assetMusl') else src['asset'])[arch]
        asset = next((a for a in release.get('assets', []) if a.get('name') == name), None)
        if not asset:
            raise RuntimeError('la ultima version de %s no incluye %s' % (src['repo'], name))
        digest = asset.get('digest') or ''
        if not re.match(r'^sha256:[0-9a-fA-F]{64}$', digest):
            raise RuntimeError('GitHub no publica el hash de %s; no se instala sin verificar' % name)
        version = release.get('tag_name', '')
        if src.get('tagPrefix') and version.startswith(src['tagPrefix']):
            version = version[len(src['tagPrefix']):]
        return {'version': version, 'url': asset['browser_download_url'], 'hash': digest[7:].lower(),
                'algorithm': 'sha256', 'size': int(asset.get('size') or 0), 'filename': name}
    if kind == 'agy':
        m = http_get_json(src['manifest'][arch])
        if not isinstance(m, dict) or not all(m.get(k) for k in ('version', 'url', 'sha512')):
            raise RuntimeError('manifiesto de Antigravity incompleto')
        return {'version': m['version'], 'url': m['url'], 'hash': m['sha512'].lower(), 'algorithm': 'sha512',
                'size': 0, 'filename': m['url'].rsplit('/', 1)[-1]}
    raise RuntimeError('tipo de fuente desconocido: %s' % kind)


def safe_extract_tar(archive, into):
    with tarfile.open(archive, 'r:gz') as tar:
        base = os.path.realpath(into)
        for member in tar.getmembers():
            target = os.path.realpath(os.path.join(into, member.name))
            if not (target == base or target.startswith(base + os.sep)):
                raise RuntimeError('el paquete contiene una ruta no valida: %s' % member.name)
            if member.issym() or member.islnk():
                raise RuntimeError('el paquete contiene enlaces, no admitidos en exFAT/FAT: %s' % member.name)
        if sys.version_info >= (3, 12):
            tar.extractall(into, filter='data')
        else:
            tar.extractall(into)


def safe_extract_zip(archive, into):
    base = os.path.realpath(into)
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            target = os.path.realpath(os.path.join(into, info.filename))
            if not (target == base or target.startswith(base + os.sep)):
                raise RuntimeError('el paquete contiene una ruta no valida: %s' % info.filename)
        for info in z.infolist():
            path = z.extract(info, into)
            mode = (info.external_attr >> 16) & 0o777
            if mode and not info.is_dir():
                try:
                    os.chmod(path, mode)
                except OSError:
                    pass


# ----------------------------------------------------------------------
#  Destination
# ----------------------------------------------------------------------

def removable_mounts():
    """Mount points that look like USB drives."""
    system = portatil.host_system()
    found = []
    if system == 'macos':
        for name in sorted(os.listdir('/Volumes')) if os.path.isdir('/Volumes') else []:
            path = os.path.join('/Volumes', name)
            if os.path.ismount(path) and os.path.realpath(path) != '/':
                found.append(path)
    else:
        user = os.environ.get('USER') or ''
        for base in ('/media/' + user, '/run/media/' + user, '/media', '/mnt'):
            if not os.path.isdir(base):
                continue
            for name in sorted(os.listdir(base)):
                path = os.path.join(base, name)
                if os.path.ismount(path) and path not in found:
                    found.append(path)
    result = []
    for path in found:
        try:
            usage = shutil.disk_usage(path)
        except OSError:
            continue
        if usage.total >= 1024 ** 3:      # skip boot partitions such as VTOYEFI
            result.append((path, usage))
    return result


def choose_destination(system_name):
    mounts = removable_mounts()
    if mounts:
        print('Unidades extraibles:')
        for i, (path, usage) in enumerate(mounts, 1):
            note = '  [ya tiene portatil]' if is_portable(os.path.join(path, 'portatil', system_name)) else ''
            print('  %d) %s  %s libres de %s%s' % (i, path, fmt_size(usage.free), fmt_size(usage.total), note))
    else:
        print('No se ha detectado ninguna unidad extraible.')
    other = len(mounts) + 1
    print('  %d) Escribir otra ruta' % other)
    print('')
    print('  Enter en blanco = salir')
    while True:
        try:
            sel = input('Seleccion: ').strip()
        except EOFError:
            sel = ''
        if not sel:
            return None
        if sel.isdigit() and 1 <= int(sel) <= len(mounts):
            suggested = os.path.join(mounts[int(sel) - 1][0], 'portatil', system_name)
            try:
                typed = input('Carpeta de instalacion [%s]: ' % suggested).strip()
            except EOFError:
                typed = ''
            return typed or suggested
        if sel.isdigit() and int(sel) == other:
            try:
                typed = input('Ruta de la carpeta de instalacion: ').strip()
            except EOFError:
                typed = ''
            if typed:
                return typed
        print('  Opcion no valida.')


def running_from(dest):
    """Processes whose executable is inside dest."""
    prefix = os.path.realpath(dest) + os.sep
    found = []
    if os.path.isdir('/proc'):
        for pid in os.listdir('/proc'):
            if pid.isdigit():
                try:
                    exe = os.readlink('/proc/%s/exe' % pid)
                except OSError:
                    continue
                if exe.startswith(prefix):
                    found.append('%s (%s)' % (exe, pid))
    elif shutil.which('ps'):
        r = subprocess.run(['ps', '-axo', 'pid=,comm='], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and os.path.realpath(parts[1]).startswith(prefix):
                found.append('%s (%s)' % (parts[1], parts[0]))
    return found


# ----------------------------------------------------------------------
#  Install
# ----------------------------------------------------------------------

def copy_scripts(manifest, dest):
    for rel in script_files(manifest):
        src = os.path.join(SOURCE, rel)
        if not os.path.isfile(src):
            continue
        dst = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if not os.path.exists(dst) or sha256_file(src) != sha256_file(dst):
            shutil.copyfile(src, dst)
        if rel.endswith('.sh'):
            make_executable(dst)


def install_tool(tool, spec, arch, release, dest, staging):
    """Downloads, verifies, unpacks, and places one assistant. Returns the
    inventory entry. Raises on any problem; the previous version stays."""
    download_path = os.path.join(staging, '%s-%s-%s' % (tool, arch, release['filename']))
    print('')
    print('Descargando %s %s (%s)%s...' % (tool, release['version'], arch,
                                         ' (%s)' % fmt_size(release['size']) if release['size'] else ''))
    download(release['url'], download_path)
    h = hashlib.new(release['algorithm'])
    with open(download_path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    if h.hexdigest().lower() != release['hash']:
        raise RuntimeError('el %s de la descarga no coincide con el publicado; posible descarga corrupta o manipulada'
                           % release['algorithm'].upper())
    print('  %s verificado.' % release['algorithm'].upper())

    tree = os.path.join(staging, tool, 'prog', arch)
    os.makedirs(tree)
    extract = spec['source']['extract']
    if extract == 'none':
        shutil.move(download_path, os.path.join(tree, spec['exe']))
    elif extract == 'targz':
        safe_extract_tar(download_path, tree)
    elif extract == 'zip':
        safe_extract_zip(download_path, tree)
    else:
        raise RuntimeError('tipo de paquete desconocido: %s' % extract)
    exe = os.path.join(tree, spec['exe'])
    if not os.path.isfile(exe):
        raise RuntimeError('el paquete descargado no contiene %s; no se instala' % spec['exe'])
    make_executable(exe)

    files = {rel: sha256_file(os.path.join(staging, rel)) for rel in program_files(staging, tool, arch)}

    # Place: copy next to the old version, then swap, so an interrupted
    # copy never leaves a half-installed program in place.
    final = os.path.join(dest, tool, 'prog', arch)
    new, old = final + '.nuevo', final + '.anterior'
    for leftover in (new, old):
        shutil.rmtree(leftover, ignore_errors=True)
    os.makedirs(os.path.dirname(final), exist_ok=True)
    shutil.copytree(tree, new)
    if os.path.exists(final):
        os.rename(final, old)
    os.rename(new, final)
    shutil.rmtree(old, ignore_errors=True)
    if portatil.host_system() == 'macos' and shutil.which('xattr'):
        subprocess.run(['xattr', '-dr', 'com.apple.quarantine', final], capture_output=True)
    print('  Instalado en %s' % final)
    return {'version': release['version'], 'source': release['url'],
            'installed': datetime.datetime.now().strftime('%Y-%m-%d %H:%M'), 'files': files}


# ----------------------------------------------------------------------
#  Verification
# ----------------------------------------------------------------------

def verify(manifest, dest, report, copied_from_source):
    portatil.validate_portable_tree(dest)
    print('')
    print('=== Verificando %s ===' % dest)
    inventory = read_inventory(dest)
    system_name = manifest['system']
    host = portatil.host_system()

    print('  Comprobando archivos (SHA-256), puede tardar un poco...')
    for tool in sorted(manifest['tools']):
        installed = [a for a in ARCHES if os.path.isdir(os.path.join(dest, tool, 'prog', a))]
        if not installed:
            report.line('FALLO', '%-12s no esta instalado' % tool)
            continue
        for arch in installed:
            key = '%s/%s' % (tool, arch)
            entry = inventory.get(key)
            if not entry:
                report.line('AVISO', '%-12s %s instalado sin inventario; ejecuta actualizar.sh' % (tool, arch))
                continue
            bad = []
            for rel, digest in entry['files'].items():
                path = os.path.join(dest, rel)
                if not os.path.isfile(path):
                    bad.append('falta ' + rel)
                elif sha256_file(path) != digest:
                    bad.append('alterado ' + rel)
            if bad:
                for b in bad:
                    report.line('FALLO', '%-12s %s' % (tool, b))
            else:
                report.line('OK', '%-12s %s %s: %d archivos identicos a la descarga verificada'
                            % (tool, entry['version'], arch, len(entry['files'])))
            for extra in (f for f in program_files(dest, tool, arch) if f not in entry['files']):
                report.line('AVISO', '%-12s sobra (no es de la version instalada): %s' % (tool, extra))

    problems = []
    for rel in script_files(manifest):
        path = os.path.join(dest, rel)
        if not os.path.isfile(path):
            problems.append('falta ' + rel)
            continue
        src = os.path.join(SOURCE, rel)
        if copied_from_source and os.path.isfile(src) and sha256_file(src) != sha256_file(path):
            problems.append('distinto del origen: ' + rel)
        if rel.endswith('.py'):
            try:
                with open(path, encoding='utf-8') as f:
                    compile(f.read(), path, 'exec')
            except SyntaxError as e:
                problems.append('error de sintaxis en %s: %s' % (rel, e))
        elif rel.endswith('.sh') and shutil.which('sh'):
            r = subprocess.run(['sh', '-n', path], capture_output=True, text=True)
            if r.returncode != 0:
                problems.append('error de sintaxis en %s: %s' % (rel, r.stderr.strip()))
    if problems:
        for p in problems:
            report.line('FALLO', 'Script ' + p)
    else:
        report.line('OK', '%d scripts correctos' % len(script_files(manifest)))

    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location('portatil_destino', os.path.join(dest, 'lib', 'portatil.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        sample = b'verificacion-portatil'
        ok = module.unprotect(module.protect(sample, 'prueba', 'PORTVF02'), 'prueba', 'PORTVF02') == sample
    except Exception:  # noqa: BLE001 - any failure means the module does not work
        ok = False
    report.line('OK' if ok else 'FALLO', 'Cifrado de credenciales operativo' if ok
                else 'El modulo de cifrado (lib/portatil.py) no funciona en el destino')

    # Programs start on this computer (only the ones it can run).
    scratch = tempfile.mkdtemp(prefix='portatil-verificar-', dir=portatil.temporary_root(dest))
    try:
        runnable = [portatil.host_arch()]
        if host == 'macos' and runnable[0] == 'arm64':
            runnable.append('x64')
        for tool in sorted(manifest['tools']):
            spec = manifest['tools'][tool]
            for arch in ARCHES:
                exe = os.path.join(dest, tool, 'prog', arch, spec['exe'])
                if not os.path.isfile(exe):
                    continue
                if host != system_name or arch not in runnable:
                    report.line('INFO', '%-12s %s no se puede ejecutar en este equipo; no se prueba' % (tool, arch))
                    continue
                env = dict(portatil.child_environment(scratch), HOME=scratch, CLAUDE_CONFIG_DIR=scratch, CODEX_HOME=scratch,
                           XDG_DATA_HOME=scratch, XDG_CONFIG_HOME=scratch, XDG_CACHE_HOME=scratch,
                           XDG_STATE_HOME=scratch, DISABLE_AUTOUPDATER='1', OPENCODE_DISABLE_AUTOUPDATE='1',
                           AGY_CLI_DISABLE_AUTO_UPDATE='1')
                env.pop('DBUS_SESSION_BUS_ADDRESS', None)
                for name in ('TEMP', 'XDG_RUNTIME_DIR'):
                    os.makedirs(env[name], mode=0o700, exist_ok=True)
                run_exe = exe
                if not os.access(exe, os.X_OK):
                    # Drive without execute permission: test a copy.
                    run_exe = os.path.join(scratch, 'exe-' + tool)
                    shutil.copyfile(exe, run_exe)
                    make_executable(run_exe)
                try:
                    r = subprocess.run([run_exe, '--version'], capture_output=True, text=True, timeout=60,
                                       env=env, stdin=subprocess.DEVNULL, cwd=scratch)
                    text = next((l.strip() for l in (r.stdout + '\n' + r.stderr).splitlines()
                                 if l.strip() and not l.startswith('WARNING:')), '')
                    expected = inventory.get('%s/%s' % (tool, arch), {}).get('version')
                    if r.returncode != 0:
                        report.line('FALLO', '%-12s %s no arranca (codigo %d): %s' % (tool, arch, r.returncode, text))
                    elif expected and expected not in text:
                        report.line('AVISO', "%-12s %s arranca pero informa '%s' en vez de %s" % (tool, arch, text, expected))
                    else:
                        report.line('OK', '%-12s %s arranca: %s' % (tool, arch, text))
                except (OSError, subprocess.TimeoutExpired) as e:
                    report.line('FALLO', '%-12s %s no arranca: %s' % (tool, arch, e))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    # Credentials state, using the destination's own launcher definitions.
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location('lanzador_destino', os.path.join(dest, 'lib', 'lanzador.py'))
        lanzador = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lanzador)
        lanzador.ROOT = dest
        any_enc = False
        for key in sorted(lanzador.TOOLS):
            launcher = lanzador.Launcher(key, [])
            launcher.dir = os.path.join(dest, launcher.tool)
            launcher.enc = os.path.join(launcher.dir, 'credenciales.enc')
            plain = launcher.secret_files()
            if plain:
                report.line('AVISO', '%-12s tiene credenciales SIN CIFRAR (%s); arrancalo y cierralo normalmente para cifrarlas'
                            % (launcher.tool, ', '.join(plain)))
            elif os.path.exists(launcher.enc):
                any_enc = True
                report.line('OK', '%-12s credenciales cifradas' % launcher.tool)
            elif key == 'antigravity':
                report.line('INFO', '%-12s instalado, pero el inicio de sesion esta bloqueado (usaria el llavero del equipo); solo --version y --help' % launcher.tool)
            else:
                report.line('OK', '%-12s sin credenciales: pedira iniciar sesion la primera vez' % launcher.tool)
        if os.path.exists(portatil.passcheck_path(dest)):
            report.line('OK', 'Contrasena comun configurada (portatil.passcheck)')
        elif any_enc:
            report.line('AVISO', 'Hay credenciales cifradas pero falta portatil.passcheck; se creara al abrir un asistente')
    except Exception as e:  # noqa: BLE001
        report.line('AVISO', 'No se pudo revisar el estado de las credenciales: %s' % e)


# ----------------------------------------------------------------------
#  Main
# ----------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='Instala o actualiza los asistentes portables desde internet.')
    parser.add_argument('destino', nargs='?', help='carpeta de instalacion')
    parser.add_argument('--si', action='store_true', help='no pedir confirmacion')
    parser.add_argument('--forzar', action='store_true', help='descargar todo aunque este al dia')
    parser.add_argument('--solo-verificar', action='store_true', help='solo verificar; sin internet ni cambios')
    parser.add_argument('--arq', default='actual', choices=('actual', 'x64', 'arm64', 'todas'),
                        help='arquitecturas a instalar (por defecto, la de este equipo)')
    args = parser.parse_args()

    manifest = load_manifest(SOURCE)
    system_name = manifest['system']
    host = portatil.host_system()
    print('')
    print('=== Instalar / actualizar los asistentes portables para %s (desde internet) ===' % system_name)
    print('')

    dest = args.destino
    if not dest:
        dest = choose_destination(system_name)
        if not dest:
            print('[instalar] Cancelado.')
            return 0
    dest = os.path.abspath(os.path.expanduser(dest))
    if os.path.ismount(dest) or dest == os.path.dirname(dest):
        dest = os.path.join(dest, 'portatil', system_name)
        print('[instalar] Se usara la carpeta %s' % dest)
    portatil.require_portable_path(dest, dest)
    if os.path.isdir(dest):
        portatil.validate_portable_tree(dest)
    self_update = os.path.realpath(dest) == os.path.realpath(SOURCE)
    update = is_portable(dest)

    if args.solo_verificar and not update:
        sys.stderr.write('[instalar] %s no contiene una instalacion portatil que verificar.\n' % dest)
        return 1
    if not update and not args.solo_verificar and os.path.isdir(dest) and os.listdir(dest):
        print('')
        print('[instalar] AVISO: %s ya existe, no esta vacia y no es una instalacion portatil.' % dest)
        print('[instalar] Se anadiran los archivos del portable sin borrar lo que hay.')
        if not args.si and not ask_yes_no('Continuar de todos modos?', False):
            print('[instalar] Cancelado.')
            return 0

    report = Report()
    if not args.solo_verificar:
        running = running_from(dest)
        if running:
            print('[instalar] Hay asistentes del destino en ejecucion; cierralos antes de continuar:')
            for r in running:
                print('  ' + r)
            return 1

        installed_arches = [a for a in ARCHES
                            if any(os.path.isdir(os.path.join(dest, t, 'prog', a)) for t in manifest['tools'])]
        if args.arq == 'todas':
            arches = list(ARCHES)
        elif args.arq == 'actual':
            if host == system_name:
                arches = [portatil.host_arch()]
                if arches[0] not in ARCHES:
                    sys.stderr.write('[instalar] Arquitectura no soportada: %s\n' % arches[0])
                    return 1
            elif installed_arches:
                arches = []      # only what is already installed (below)
            else:
                sys.stderr.write('[instalar] Este equipo no es %s: indica la arquitectura con --arq x64, arm64 o todas.\n'
                                 % system_name)
                return 1
        else:
            arches = [args.arq]
        # Keep architectures already installed up to date as well.
        for a in installed_arches:
            if a not in arches:
                arches.append(a)
        musl = is_musl()

        inventory = read_inventory(dest)
        print('Consultando las ultimas versiones oficiales%s...' % (' (musl)' if musl else ''))
        plan = []
        for tool in sorted(manifest['tools']):
            spec = manifest['tools'][tool]
            for arch in arches:
                key = '%s/%s' % (tool, arch)
                installed = inventory.get(key, {}).get('version')
                exe_present = os.path.isfile(os.path.join(dest, tool, 'prog', arch, spec['exe']))
                try:
                    release = latest_release(spec, arch, musl)
                except Exception as e:  # noqa: BLE001
                    plan.append({'tool': tool, 'arch': arch, 'action': 'error', 'error': str(e), 'installed': installed})
                    continue
                action = 'instalar'
                if installed and exe_present:
                    if installed != release['version']:
                        action = 'actualizar'
                    elif args.forzar:
                        action = 'reinstalar'
                    elif any(not os.path.isfile(os.path.join(dest, f)) for f in inventory[key]['files']):
                        action = 'reparar'
                    else:
                        action = 'al dia'
                elif exe_present:
                    action = 'actualizar'
                plan.append({'tool': tool, 'arch': arch, 'action': action, 'release': release, 'installed': installed})

        print('')
        print('  %-12s %-6s %-14s %-14s %s' % ('Asistente', 'Arq', 'Instalada', 'Disponible', 'Accion'))
        for p in plan:
            inst = p['installed'] or ('desconocida' if os.path.isdir(os.path.join(dest, p['tool'], 'prog', p['arch'])) else '-')
            if p['action'] == 'error':
                print('  %-12s %-6s %-14s %-14s ERROR: %s' % (p['tool'], p['arch'], inst, '?', p['error']))
            else:
                print('  %-12s %-6s %-14s %-14s %s' % (p['tool'], p['arch'], inst, p['release']['version'], p['action']))

        todo = [p for p in plan if p['action'] in ('instalar', 'actualizar', 'reparar', 'reinstalar')]
        scripts_changed = not self_update and any(
            os.path.isfile(os.path.join(SOURCE, r)) and (not os.path.isfile(os.path.join(dest, r)) or
                                                         sha256_file(os.path.join(SOURCE, r)) != sha256_file(os.path.join(dest, r)))
            for r in script_files(manifest))

        need_dest, need_temp = MARGIN, MARGIN
        for p in todo:
            r = p['release']
            unpacked = r['size'] if manifest['tools'][p['tool']]['source']['extract'] == 'none' else r['size'] * SIZE_FACTOR
            unpacked = unpacked or UNKNOWN_SIZE
            current = sum(os.path.getsize(os.path.join(dest, f)) for f in program_files(dest, p['tool'], p['arch']))
            need_dest += unpacked
            need_temp += unpacked + r['size']
        check_dir = dest if os.path.isdir(dest) else os.path.dirname(dest)
        while not os.path.isdir(check_dir):
            check_dir = os.path.dirname(check_dir)
        need_dest += need_temp
        if todo and shutil.disk_usage(check_dir).free < need_dest:
            sys.stderr.write('[instalar] Espacio insuficiente en el destino: hacen falta unos %s y hay %s libres.\n'
                             % (fmt_size(need_dest), fmt_size(shutil.disk_usage(check_dir).free)))
            return 1

        print('')
        if not todo and not scripts_changed and update:
            print('Todo esta al dia; solo se verificara la instalacion.')
        else:
            if self_update:
                print('Se va a actualizar ESTA carpeta (%s) desde internet.' % dest)
            elif update:
                print('Se va a ACTUALIZAR el portable de %s' % dest)
            else:
                print('Se va a INSTALAR el portable en %s' % dest)
            print('  Se conservan sus sesiones, credenciales y contrasena.' if update else
                  '  Instalacion limpia: cada asistente pedira iniciar sesion la primera vez.')
            if todo:
                size = sum(p['release']['size'] for p in todo)
                print('  Descargas: %s (%s%s)' % (', '.join('%s %s' % (p['tool'], p['arch']) for p in todo), fmt_size(size),
                                                  ' + Antigravity' if any(p['tool'] == 'antigravity' for p in todo) else ''))
            if scripts_changed:
                print('  Scripts: se copian desde %s' % SOURCE)
            print('')
            if not args.si and not ask_yes_no('Continuar?', True):
                print('[instalar] Cancelado.')
                return 0

        os.makedirs(dest, exist_ok=True)
        if not self_update:
            print('')
            print('Copiando scripts...')
            copy_scripts(manifest, dest)

        staging = tempfile.mkdtemp(prefix='portatil-descargas-', dir=portatil.temporary_root(dest))
        try:
            for p in todo:
                spec = manifest['tools'][p['tool']]
                try:
                    inventory['%s/%s' % (p['tool'], p['arch'])] = install_tool(p['tool'], spec, p['arch'], p['release'], dest, staging)
                    save_inventory(dest, inventory)
                except Exception as e:  # noqa: BLE001
                    report.line('FALLO', '%s %s: %s (se conserva la version anterior si la habia)' % (p['tool'], p['arch'], e))
                finally:
                    shutil.rmtree(os.path.join(staging, p['tool']), ignore_errors=True)
                    for f in os.listdir(staging):
                        if f.startswith('%s-%s-' % (p['tool'], p['arch'])):
                            portatil.remove_quietly(os.path.join(staging, f))
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        for p in plan:
            if p['action'] == 'error':
                report.line('FALLO', '%s %s: no se pudo consultar la ultima version: %s' % (p['tool'], p['arch'], p['error']))

    verify(manifest, dest, report, copied_from_source=not self_update)

    print('')
    if not report.failures:
        extra = ', con %d aviso(s)' % len(report.warnings) if report.warnings else ''
        print('[instalar] Todo correcto%s. El portable de %s esta listo.' % (extra, dest))
        print('[instalar] Para empezar: sh %s/claude/claude.sh (o codex/codex.sh, oc/opencode.sh).' % dest)
        print('[instalar] Para actualizarlo mas adelante: sh %s/actualizar.sh' % dest)
        print('[instalar] Cierra siempre los asistentes antes de retirar la unidad.')
        return 0
    print('[instalar] Hubo %d problema(s). Vuelve a ejecutar el instalador (con --forzar para descargar todo de nuevo).'
          % len(report.failures))
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('')
        print('[instalar] Interrumpido.')
        sys.exit(1)

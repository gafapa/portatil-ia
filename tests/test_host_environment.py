"""Regression tests for host authentication isolation.

Run with: python -B -m unittest discover -s tests -v
All credentials are dummy values; launchers run from disposable copies.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'linux' / 'lib'))
import portatil
import lanzador


HOST_VARIABLES = (
    'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN',
    'OPENAI_API_KEY', 'OPENAI_BASE_URL', 'GEMINI_API_KEY', 'GOOGLE_API_KEY',
    'GOOGLE_APPLICATION_CREDENTIALS', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY',
    'AWS_SESSION_TOKEN', 'AWS_PROFILE', 'AWS_CONFIG_FILE',
    'AWS_SHARED_CREDENTIALS_FILE', 'AZURE_CLIENT_SECRET', 'AZURE_CONFIG_DIR',
    'CLOUDSDK_CONFIG', 'KUBECONFIG', 'BOTO_CONFIG', 'BOTO_PATH',
    'GITHUB_TOKEN', 'GH_TOKEN', 'HF_TOKEN', 'SSH_AUTH_SOCK', 'SSH_ASKPASS',
    'GIT_ASKPASS', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_COUNT', 'HTTP_PROXY',
    'HTTPS_PROXY', 'ALL_PROXY', 'NODE_OPTIONS', 'PYTHONPATH', 'LD_PRELOAD',
    'DYLD_INSERT_LIBRARIES', 'OPENCODE_CONFIG', 'OPENCODE_CONFIG_CONTENT',
    'UNKNOWN_FUTURE_PROVIDER_SECRET', 'LC_PRIVATE_API_KEY',
    'PORTATIL_PASSWORD', 'CLAUDE_PASSWORD', 'CODEX_PORTABLE_PASSWORD',
    'OPENCODE_PASSWORD', 'ANTIGRAVITY_PASSWORD',
)
DUMMY_VALUE = 'audit-host-secret-must-not-cross'
PROFILE_VARIABLES = (
    'HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME',
    'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'AWS_CONFIG_FILE',
    'AWS_SHARED_CREDENTIALS_FILE', 'BOTO_CONFIG', 'BOTO_PATH',
    'CLOUDSDK_CONFIG', 'AZURE_CONFIG_DIR', 'KUBECONFIG', 'GIT_CONFIG_GLOBAL',
    'TEMP', 'TMP', 'TMPDIR', 'CLAUDE_CODE_TMPDIR', 'XDG_RUNTIME_DIR',
)
PROBE = ('import os,json,tempfile; fd,path=tempfile.mkstemp(); os.close(fd); '
         'print(json.dumps(dict(os.environ, AUDIT_CWD=os.getcwd(), AUDIT_TEMP_FILE=path))); os.remove(path)')


class EnvironmentTests(unittest.TestCase):
    def assert_isolated(self, env, portable_root):
        for name in HOST_VARIABLES:
            self.assertNotEqual(env.get(name), DUMMY_VALUE, name)
            if name not in PROFILE_VARIABLES:
                self.assertNotIn(name, env, name)
        for name in PROFILE_VARIABLES:
            path = Path(env[name]).resolve()
            self.assertIn(portable_root.resolve(), (path,) + tuple(path.parents), name)
        self.assertEqual(env['GIT_CONFIG_NOSYSTEM'], '1')
        self.assertIn('PATH', env)
        if 'AUDIT_TEMP_FILE' in env:
            self.assertIn(portable_root.resolve(), Path(env['AUDIT_TEMP_FILE']).resolve().parents)

    def test_external_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            portable_root = Path(tmp) / 'portable'
            portable_root.mkdir()
            with self.assertRaises(portatil.CredentialError):
                portatil.require_portable_path(str(portable_root), str(Path(tmp) / 'host' / 'auth.json'))

    def test_linked_host_credentials_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'portable'
            root.mkdir()
            host = Path(tmp) / 'host'
            host.mkdir()
            (host / 'auth.json').write_text('dummy host credential', encoding='utf-8')
            link = root / 'data'
            if os.name == 'nt':
                if not shutil.which('pwsh'):
                    self.skipTest('Requires PowerShell for a Windows junction')
                script = Path(tmp) / 'junction.ps1'
                script.write_text('param($LinkPath,$HostPath)\nNew-Item -ItemType Junction -Path $LinkPath -Target $HostPath | Out-Null', encoding='utf-8')
                result = subprocess.run(['pwsh', '-NoProfile', '-File', str(script), str(link), str(host)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            else:
                link.symlink_to(host, target_is_directory=True)
            try:
                with self.assertRaises(portatil.CredentialError):
                    portatil.require_portable_path(str(root), str(link / 'auth.json'))
                with self.assertRaises(portatil.CredentialError):
                    portatil.validate_portable_tree(str(root))
                self.assertEqual((host / 'auth.json').read_text(), 'dummy host credential')
            finally:
                if os.name == 'nt':
                    os.rmdir(link)  # Remove the junction itself, preserving its target.
                else:
                    link.unlink()

    @unittest.skipUnless(os.name == 'nt' and shutil.which('pwsh'), 'Requires Windows and PowerShell 7')
    def test_windows_external_state_directory_is_rejected_before_access(self):
        for tool, name in (('claude', 'claude'), ('codex', 'codex'), ('oc', 'opencode'), ('antigravity', 'antigravity')):
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'portable'
                shutil.copytree(ROOT / 'windows', root)
                host = Path(tmp) / 'host'
                host.mkdir()
                marker = host / 'auth.json'
                marker.write_text('dummy host credentials')
                result = subprocess.run(['pwsh', '-NoProfile', '-File', str(root / tool / (name + '.ps1')),
                                         '-DataDir', str(host)], capture_output=True, text=True, timeout=30)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('inside the portable folder', result.stderr)
                self.assertEqual(marker.read_text(), 'dummy host credentials')
                self.assertEqual(list(host.iterdir()), [marker])

    def test_atomic_save_preserves_previous_credentials_on_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'credentials.enc'
            original = portatil.protect(b'old dummy credentials', 'portable-password', 'PORTVF02')
            path.write_bytes(original)
            with mock.patch.object(portatil.os, 'replace', side_effect=OSError('simulated USB failure')):
                with self.assertRaises(OSError):
                    portatil.write_private(str(path), b'new dummy data')
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(Path(tmp).iterdir()), [path])

    def test_concurrent_credential_session_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with portatil.session_lock(tmp):
                with self.assertRaises(portatil.CredentialError):
                    with portatil.session_lock(tmp):
                        self.fail('Concurrent session acquired the same lock')
            with portatil.session_lock(tmp):
                pass  # The lock must become available after the first session.

    def test_host_keychain_is_not_called(self):
        with mock.patch.object(lanzador, '_TEST_SECURITY', None), mock.patch.object(lanzador.subprocess, 'run') as child:
            with self.assertRaises(portatil.CredentialError):
                lanzador.keychain_get('antigravity')
            child.assert_not_called()

    def test_noexec_drive_does_not_copy_programs_to_host(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(lanzador, 'ROOT', tmp):
            launcher = lanzador.Launcher('claude', [])
            prog = Path(tmp) / 'claude' / 'prog' / 'x64'
            prog.mkdir(parents=True)
            (prog / 'claude').write_bytes(b'dummy program')
            with mock.patch.object(lanzador, '_TEST_PROGRAM', None), \
                    mock.patch.object(lanzador, '_noexec', return_value=True), \
                    mock.patch.object(lanzador.os, 'access', return_value=True):
                with self.assertRaises(portatil.CredentialError):
                    launcher.runnable_program(str(prog))

    @unittest.skipUnless(os.name == 'nt' and shutil.which('pwsh'), 'Requires Windows and PowerShell 7')
    def test_windows_provider_and_mcp_tokens_remain_portable(self):
        for tool, name in (('oc', 'opencode'), ('codex', 'codex')):
            with self.subTest(tool=tool), tempfile.TemporaryDirectory(prefix='portable tokens ') as tmp:
                root = Path(tmp) / 'portable'
                shutil.copytree(ROOT / 'windows', root)
                launcher = root / tool / (name + '.ps1')
                binary = root / tool / 'bin' / (name + '.exe')
                binary.parent.mkdir()
                shutil.copyfile(Path(os.environ['SystemRoot']) / 'System32' / 'cmd.exe', binary)
                if tool == 'codex':
                    for rel in ('bin/codex-code-mode-host.exe', 'codex-resources/codex-command-runner.exe',
                                'codex-resources/codex-windows-sandbox-setup.exe', 'codex-path/rg.exe', 'codex-package.json'):
                        path = root / tool / rel
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(b'test support file')
                data = root / tool / 'data' / ('opencode' if tool == 'oc' else 'codex')
                data.mkdir(parents=True)
                auth = data / 'auth.json'
                mcp = data / ('mcp-auth.json' if tool == 'oc' else '.credentials.json')
                auth.write_text('{"dummy":"portable-provider-token"}', encoding='utf-8')
                mcp.write_text('{"dummy":"portable-mcp-token"}', encoding='utf-8')
                probe = root / 'probe.py'
                probe.write_text('import pathlib,json; p=pathlib.Path(%r); print(json.dumps({"auth":(p/"auth.json").exists(),"mcp":(p/%r).exists()}))' % (str(data), mcp.name), encoding='utf-8')
                batch = root / 'probe.cmd'
                batch.write_text('@echo off\n"%s" "%s"\n' % (sys.executable, probe), encoding='utf-8')
                env = dict(os.environ, PORTATIL_PASSWORD='portable-password')
                for iteration in range(2):
                    result = subprocess.run(['pwsh', '-NoProfile', '-File', str(launcher), '/c', str(batch)],
                                            env=env, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    output = next(line for line in result.stdout.splitlines() if line.startswith('{'))
                    self.assertEqual(json.loads(output), {'auth': True, 'mcp': True})
                    self.assertFalse(auth.exists())
                    self.assertFalse(mcp.exists())
                    self.assertTrue((data / 'auth.json.enc').exists())
                encrypted = (data / 'auth.json.enc').read_bytes()
                env['PORTATIL_PASSWORD'] = 'wrong-password'
                result = subprocess.run(['pwsh', '-NoProfile', '-File', str(launcher), '/c', str(batch)],
                                        env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 2)
                self.assertEqual((data / 'auth.json.enc').read_bytes(), encrypted)
                self.assertFalse(auth.exists())
                self.assertFalse(mcp.exists())

    def test_python_environment_allowlist_and_profile_paths(self):
        inherited = {name: DUMMY_VALUE for name in HOST_VARIABLES}
        inherited.update(PATH=os.environ.get('PATH', ''), LANG='C', LC_ALL='C', TERM='xterm')
        with tempfile.TemporaryDirectory() as tmp:
            env = portatil.child_environment(tmp, inherited)
            self.assert_isolated(env, Path(tmp))
            self.assertEqual(env['LC_ALL'], 'C')
            self.assertEqual(inherited['ANTHROPIC_API_KEY'], DUMMY_VALUE)

    def test_portable_macos_token_overrides_ignored_host_token(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(lanzador, 'ROOT', tmp), \
                mock.patch.object(lanzador, 'SYSTEM', 'macos'), \
                mock.patch.dict(os.environ, {'CLAUDE_CODE_OAUTH_TOKEN': DUMMY_VALUE}):
            launcher = lanzador.Launcher('claude', [])
            self.assertIsNone(launcher.token)
            self.assertNotIn('CLAUDE_CODE_OAUTH_TOKEN', launcher.environment(tmp))
            launcher.token = 'audit-portable-token'
            self.assertEqual(launcher.environment(tmp)['CLAUDE_CODE_OAUTH_TOKEN'], launcher.token)
            self.assertEqual(os.environ['CLAUDE_CODE_OAUTH_TOKEN'], DUMMY_VALUE)

    def test_python_real_child_environment_for_all_launchers(self):
        for system in ('linux', 'macos'):
            for tool in lanzador.TOOLS:
                with self.subTest(system=system, tool=tool), tempfile.TemporaryDirectory() as tmp:
                    portable_root = Path(tmp)
                    shutil.copytree(ROOT / system / 'lib', portable_root / 'lib')
                    (portable_root / 'portatil-programa.json').write_text(
                        json.dumps({'system': system}), encoding='utf-8')
                    exe = portable_root / tool / 'prog' / portatil.host_arch() / lanzador.TOOLS[tool]['exe']
                    exe.parent.mkdir(parents=True)
                    exe.write_bytes(b'simulated program')
                    env = dict(os.environ)
                    env.update({name: DUMMY_VALUE for name in HOST_VARIABLES})
                    # Do not preload fake host libraries into the test interpreter.
                    for name in ('LD_PRELOAD', 'DYLD_INSERT_LIBRARIES', 'PYTHONPATH'):
                        env.pop(name, None)
                    harness = ('import sys,json; sys.path.insert(0,sys.argv[1]); import lanzador; '
                               'lanzador.SYSTEM=sys.argv[2]; lanzador._TEST_PROGRAM=sys.argv[4]; '
                               'sys.exit(lanzador.main(["lanzador.py",sys.argv[3],"--help"]))')
                    result = subprocess.run(
                        [sys.executable, '-I', '-S', '-B', '-c', harness,
                         str(portable_root / 'lib'), system, tool, json.dumps([sys.executable, '-I', '-S', '-B', '-c', PROBE])],
                        env=env, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assert_isolated(json.loads(result.stdout.strip()), portable_root)
                    self.assertEqual(Path(json.loads(result.stdout.strip())['AUDIT_CWD']), portable_root / tool)

    def test_python_codex_overrides_precede_user_arguments(self):
        # The file-store overrides are global options; appended after the user's
        # arguments they would end up inside e.g. "codex mcp add NAME -- <command>".
        with tempfile.TemporaryDirectory() as tmp:
            portable_root = Path(tmp)
            shutil.copytree(ROOT / 'linux' / 'lib', portable_root / 'lib')
            (portable_root / 'portatil-programa.json').write_text(json.dumps({'system': 'linux'}), encoding='utf-8')
            exe = portable_root / 'codex' / 'prog' / portatil.host_arch() / lanzador.TOOLS['codex']['exe']
            exe.parent.mkdir(parents=True)
            exe.write_bytes(b'simulated program')
            user_args = ['mcp', 'add', 'server', '--', 'npx', 'package', '-c', 'x']
            harness = ('import sys,json; sys.path.insert(0,sys.argv[1]); import lanzador; '
                       'lanzador.SYSTEM="linux"; lanzador._TEST_PROGRAM=sys.argv[2]; '
                       'sys.exit(lanzador.main(["lanzador.py","codex"]+json.loads(sys.argv[3])))')
            probe = 'import sys,json; print("ARGV=" + json.dumps(sys.argv[1:]))'
            env = {k: v for k, v in os.environ.items() if not k.endswith('_PASSWORD')}
            result = subprocess.run(
                [sys.executable, '-I', '-S', '-B', '-c', harness, str(portable_root / 'lib'),
                 json.dumps([sys.executable, '-I', '-S', '-B', '-c', probe]), json.dumps(user_args)],
                env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            argv = json.loads(next(l for l in result.stdout.splitlines() if l.startswith('ARGV='))[5:])
            self.assertEqual(argv, ['-c', 'cli_auth_credentials_store="file"',
                                    '-c', 'mcp_oauth_credentials_store="file"'] + user_args)

    def test_host_variables_cannot_replace_launcher_program_or_keychain(self):
        env = dict(os.environ, PORTATIL_PRUEBA_SISTEMA='fake-system',
                   PORTATIL_PRUEBA_PROGRAMA='["host-program"]', PORTATIL_PRUEBA_SECURITY='["host-keychain-helper"]')
        script = ('import sys,json; sys.path.insert(0,sys.argv[1]); import lanzador,portatil; '
                  'print(json.dumps([lanzador.SYSTEM==portatil.host_system(), '
                  'lanzador._TEST_PROGRAM is None, lanzador._TEST_SECURITY is None]))')
        result = subprocess.run([sys.executable, '-I', '-S', '-B', '-c', script, str(ROOT / 'linux' / 'lib')],
                                env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [True, True, True])

    def test_linux_macos_script_parity(self):
        for path in (ROOT / 'linux').rglob('*'):
            if path.suffix in ('.py', '.sh'):
                self.assertEqual(path.read_bytes(), (ROOT / 'macos' / path.relative_to(ROOT / 'linux')).read_bytes())

    @unittest.skipUnless(os.name == 'nt' and shutil.which('pwsh'), 'Requires Windows and PowerShell 7')
    def test_windows_real_child_environment_for_all_launchers(self):
        names = {'claude': 'claude', 'codex': 'codex', 'oc': 'opencode', 'antigravity': 'antigravity'}
        for tool, name in names.items():
            with self.subTest(tool=tool), tempfile.TemporaryDirectory(prefix='portable environment ') as tmp:
                portable_root = Path(tmp)
                shutil.copyfile(ROOT / 'windows' / 'portable-crypto.ps1', portable_root / 'portable-crypto.ps1')
                shutil.copyfile(ROOT / 'windows' / 'portable-keyring.ps1', portable_root / 'portable-keyring.ps1')
                launcher = portable_root / tool / (name + '.ps1')
                launcher.parent.mkdir()
                shutil.copyfile(ROOT / 'windows' / tool / (name + '.ps1'), launcher)
                exe_name = 'agy' if tool == 'antigravity' else name
                exe = launcher.parent / 'bin' / (exe_name + '.exe')
                exe.parent.mkdir()
                shutil.copyfile(Path(os.environ['SystemRoot']) / 'System32' / 'cmd.exe', exe)
                if tool == 'codex':
                    for rel in ('bin/codex-code-mode-host.exe', 'codex-resources/codex-command-runner.exe',
                                'codex-resources/codex-windows-sandbox-setup.exe', 'codex-path/rg.exe',
                                'codex-package.json'):
                        path = launcher.parent / rel
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(b'test support file')
                probe = portable_root / 'probe.py'
                probe.write_text(PROBE, encoding='utf-8')
                batch = portable_root / 'probe.cmd'
                batch.write_text('@echo off\n"%s" "%s"\n' % (sys.executable, probe), encoding='utf-8')
                env = dict(os.environ)
                env.update({key: DUMMY_VALUE for key in HOST_VARIABLES})
                env.pop('PYTHONPATH', None)
                arguments = ['/c', str(batch)]
                result = subprocess.run(['pwsh', '-NoProfile', '-File', str(launcher)] + arguments,
                                        env=env, capture_output=True, text=True, timeout=45)
                if tool == 'antigravity':
                    self.assertEqual(result.returncode, 1)
                    self.assertIn('bloqueado', result.stderr)
                    self.assertNotIn('{', result.stdout)
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                output = next(line for line in result.stdout.splitlines() if line.startswith('{'))
                self.assert_isolated(json.loads(output), portable_root)
                self.assertEqual(Path(json.loads(output)['AUDIT_CWD']), portable_root / tool)

    @unittest.skipUnless(os.name == 'nt' and shutil.which('pwsh'), 'Requires Windows and PowerShell 7')
    def test_windows_assistant_flags_are_not_taken_by_launchers(self):
        # A param() block let PowerShell match abbreviations: Claude's -p/-c/-d and
        # Codex's -p/-c became -Password/-CmdArgs/-DataDir. Codex's own file-store
        # overrides must not be appended after the user's arguments either.
        user_args = ['-p', 'uno', '-c', 'dos', '-d', 'tres', '-e', '-w', 'mcp', 'add', 'x', '--', 'npx', 'srv']
        names = {'claude': 'claude', 'codex': 'codex', 'oc': 'opencode'}
        for tool, name in names.items():
            with self.subTest(tool=tool), tempfile.TemporaryDirectory(prefix='portable flags ') as tmp:
                portable_root = Path(tmp)
                shutil.copyfile(ROOT / 'windows' / 'portable-crypto.ps1', portable_root / 'portable-crypto.ps1')
                launcher = portable_root / tool / (name + '.ps1')
                launcher.parent.mkdir()
                shutil.copyfile(ROOT / 'windows' / tool / (name + '.ps1'), launcher)
                exe = launcher.parent / 'bin' / (name + '.exe')
                exe.parent.mkdir()
                shutil.copyfile(Path(os.environ['SystemRoot']) / 'System32' / 'cmd.exe', exe)
                if tool == 'codex':
                    for rel in ('bin/codex-code-mode-host.exe', 'codex-resources/codex-command-runner.exe',
                                'codex-resources/codex-windows-sandbox-setup.exe', 'codex-path/rg.exe',
                                'codex-package.json'):
                        path = launcher.parent / rel
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(b'test support file')
                probe = portable_root / 'probe.py'
                probe.write_text('import sys,json,os; print("ARGV=" + json.dumps(sys.argv[1:])); print("CWD=" + os.getcwd())',
                                 encoding='utf-8')
                batch = portable_root / 'probe.cmd'
                batch.write_text('@echo off\n"%s" "%s" %%*\n' % (sys.executable, probe), encoding='utf-8')
                env = {k: v for k, v in os.environ.items() if not k.endswith('_PASSWORD')}
                for launcher_options, workspace in (([], None), (['-Workspace', 'w1'], 'w1')):
                    result = subprocess.run(['pwsh', '-NoProfile', '-File', str(launcher)] + launcher_options
                                            + ['/c', str(batch)] + user_args,
                                            env=env, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    argv = json.loads(next(l for l in result.stdout.splitlines() if l.startswith('ARGV='))[5:])
                    self.assertEqual(argv, user_args)
                    if workspace:
                        cwd = Path(next(l for l in result.stdout.splitlines() if l.startswith('CWD='))[4:])
                        self.assertEqual(cwd.name, workspace)


if __name__ == '__main__':
    unittest.main()

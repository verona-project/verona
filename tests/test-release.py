"""Release packaging and installer contract tests (no native toolchain needed)."""
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release', ROOT / 'scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_package_and_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            llvm = root / 'llvm'
            llvm.mkdir()
            (llvm / 'llvm.asd').touch()

            def build(*args, cwd):
                cwd = Path(cwd)
                if args == ('make', 'build'):
                    self.assertIn(':version "2.3.4"', (cwd / 'verona.asd').read_text())
                    self.assertIn('[2.3.4]', (cwd / 'configure.ac').read_text())
                    for file in ('verona', 'verona-server', 'project/verona-project', 'formatter/verona-fmt'):
                        path = cwd / 'build' / file
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_text('#!/bin/sh\nexit 0\n')
                        path.chmod(0o755)
                    for package in (*release.LIBRARIES, 'project', 'formatter'):
                        self.assertIn('(version "2.3.4")',
                                      (cwd / 'projects' / package / 'verona.build').read_text())
                else:
                    self.assertIn(args, (('autoreconf', '-fi'), ('./configure',)))

            original_output = subprocess.check_output

            def output(command, **kwargs):
                if command[-1] == '--version':
                    return '2.3.4\n'
                return original_output(command, **kwargs)

            with patch.object(release.subprocess, 'check_output', side_effect=output), \
                 patch.object(release, 'run', side_effect=build), \
                 patch.object(release.shutil, 'which', return_value='/mock/tool'), \
                 patch.dict(os.environ, VERONA_CL_LLVM=str(llvm)):
                printed = io.StringIO()
                with redirect_stdout(printed):
                    release.release('2.3.4', root / 'output')
                with self.assertRaisesRegex(RuntimeError, 'already exists'):
                    release.release('2.3.4', root / 'output')
            archive, = (root / 'output').glob('verona-2.3.4-*.zip')
            data = archive.read_bytes()
            expected = [str(archive)] + [
                f'{name.upper()}: {hashlib.new(name, data).hexdigest()}  {archive.name}'
                for name in ('md5', 'sha1', 'sha256')]
            self.assertEqual(printed.getvalue().splitlines(), expected)
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(root / 'extracted')
            payload, = (root / 'extracted').iterdir()
            self.assertEqual((payload / 'VERSION').read_text(), '2.3.4\n')
            self.assertFalse((payload / 'lib').exists())
            self.assertEqual(list(payload.rglob('*.a')), [])
            for package in release.LIBRARIES:
                self.assertTrue((payload / 'source' / package / 'src').is_dir())
                self.assertTrue((payload / 'source' / package / 'verona.build').is_file())
            for shell in ('bash', 'zsh'):
                destination = root / f'{shell} installation with spaces'
                env = dict(os.environ, VERONA_SOURCE_DIR=str(destination / 'source'),
                           VERONA_LIBRARY_DIR=str(destination / 'lib'))
                command = [shell, str(payload / 'install.sh'), str(destination / 'bin')]
                subprocess.run(command, env=env, check=True, capture_output=True)
                self.assertTrue(os.access(destination / 'bin/verona', os.X_OK))
                self.assertEqual(list((destination / 'lib').rglob('*.a')), [])
                self.assertTrue((destination / 'source/base/src').is_dir())
                self.assertTrue((destination / 'source/compiler/verona.asd').is_file())
                self.assertEqual((destination / 'lib/VERSION').read_text(), '2.3.4\n')
                env['VERONA_SOURCE_DIR'] = 'relative'
                self.assertNotEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)
                del env['VERONA_SOURCE_DIR']
                self.assertNotEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)

            (payload / 'source/base/verona.build').unlink()
            destination = root / 'incomplete installation'
            env = dict(os.environ, VERONA_SOURCE_DIR=str(destination / 'source'),
                       VERONA_LIBRARY_DIR=str(destination / 'lib'))
            for shell in ('bash', 'zsh'):
                result = subprocess.run([shell, str(payload / 'install.sh'),
                                         str(destination / 'bin')], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())

    def test_invalid_version(self):
        with self.assertRaises(ValueError):
            release.release('../bad', Path('/unused'))


if __name__ == '__main__':
    unittest.main()

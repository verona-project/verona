#!/usr/bin/env python3
"""Build a versioned release from an isolated copy of the working tree."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
LIBRARIES = ('base', 'libc', 'foundation', 'testing')


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True)


def stamp(path, pattern, version):
    text, count = re.subn(pattern, lambda m: m[1] + version + m[2], path.read_text())
    if not count:
        raise RuntimeError(f'No version found in {path}')
    path.write_text(text)


def print_checksums(path):
    digests = {name: hashlib.new(name) for name in ('md5', 'sha1', 'sha256')}
    with path.open('rb') as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b''):
            for digest in digests.values():
                digest.update(chunk)
    for name, digest in digests.items():
        print(f'{name.upper()}: {digest.hexdigest()}  {path.name}')


def release(version, output):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?', version):
        raise ValueError('VERSION must be X.Y.Z with an optional prerelease/build suffix')
    for command in ('git', 'autoreconf', 'make', 'sbcl'):
        if not shutil.which(command):
            raise RuntimeError(f'{command} is required; run inside nix develop')
    llvm = Path(os.environ.get('VERONA_CL_LLVM', ''))
    if not llvm.is_absolute() or not (llvm / 'llvm.asd').is_file():
        raise RuntimeError('VERONA_CL_LLVM must name an absolute CL-LLVM source directory')
    for package in (*LIBRARIES, 'project', 'formatter'):
        if not (ROOT / 'projects' / package / 'verona.build').is_file():
            raise RuntimeError(f'Initialize the projects/{package} submodule first')
    revision = subprocess.check_output(
        ['git', 'rev-parse', '--short=12', 'HEAD'], cwd=ROOT, text=True).strip()
    name = f'verona-{version}-{revision}'
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'{name}.zip'
    if archive.exists():
        raise RuntimeError(f'Release already exists: {archive}')
    with tempfile.TemporaryDirectory(prefix='verona-release-') as temporary:
        work = Path(temporary) / 'work'
        work.mkdir()
        # Copy explicit inputs only: no local builds, Git metadata, or generated configure state.
        for entry in ('src', 'scripts', 'projects', 'vendor'):
            shutil.copytree(ROOT / entry, work / entry, ignore_dangling_symlinks=True, ignore=shutil.ignore_patterns(
                '.git', '.DS_Store', '__pycache__', 'build', '*.fasl', '*.o', '*.a', '*.so', '*.dylib'))
        for entry in ('verona.asd', 'configure.ac', 'Makefile.am', 'readme.md', 'license'):
            shutil.copy2(ROOT / entry, work / entry)
        stamp(work / 'configure.ac', r'(AC_INIT\(\[Verona\], \[)[^]]+(\])', version)
        stamp(work / 'verona.asd', r'(:version ")[^"]+(")', version)
        for package in (*LIBRARIES, 'project', 'formatter'):
            stamp(work / 'projects' / package / 'verona.build', r'(\(version ")[^"]+("\))', version)
        run('autoreconf', '-fi', cwd=work)
        run('./configure', cwd=work)
        run('make', 'build', cwd=work)
        actual_version = subprocess.check_output(
            [str(work / 'build/verona'), '--version'], cwd=work, text=True).strip()
        if actual_version != version:
            raise RuntimeError(f'Compiler version {actual_version!r} does not match {version!r}')
        payload = Path(temporary) / name
        (payload / 'bin').mkdir(parents=True)
        (payload / 'source').mkdir()
        for relative in ('verona', 'verona-server', 'project/verona-project', 'formatter/verona-fmt'):
            shutil.copy2(work / 'build' / relative, payload / 'bin' / Path(relative).name)
        for package in LIBRARIES:
            shutil.copytree(work / 'projects' / package, payload / 'source' / package)
        # The IDE launcher loads compiler sources at runtime.
        compiler = payload / 'compiler'
        compiler.mkdir()
        shutil.copytree(work / 'src', compiler / 'src')
        shutil.copy2(work / 'verona.asd', compiler / 'verona.asd')
        shutil.copytree(work / 'vendor/CL-LLVM', payload / 'CL-LLVM')
        for entry in ('readme.md', 'license'):
            shutil.copy2(work / entry, payload / entry)
        shutil.copy2(work / 'scripts/install.sh', payload / 'install.sh')
        (payload / 'VERSION').write_text(version + '\n')
        (payload / 'GIT_HASH').write_text(revision + '\n')
        # Write atomically so a failed archive never looks like a finished release.
        pending = Path(temporary) / 'release.zip'
        with zipfile.ZipFile(pending, 'w', zipfile.ZIP_DEFLATED) as bundle:
            for path in sorted(payload.rglob('*')):
                if path.is_file():
                    bundle.write(path, path.relative_to(payload.parent))
        with tempfile.NamedTemporaryFile(dir=output, prefix='.verona-', suffix='.zip') as staged:
            with pending.open('rb') as source:
                shutil.copyfileobj(source, staged)
            staged.flush()
            # A hard link publishes the finished file atomically without overwriting.
            os.link(staged.name, archive)
    print(archive)
    print_checksums(archive)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/releases')
    args = parser.parse_args()
    try:
        release(args.version, args.output.resolve())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release failed: {error}\n')

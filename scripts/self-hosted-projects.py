#!/usr/bin/env python3
"""Build and validate project manifests using an explicitly selected self-hosted compiler."""
import argparse
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
POLICY = Path(__file__).with_suffix('.json')
KINDS = {'executable', 'static-library', 'shared-library'}
CHECKS = {'command', 'compiler', 'formatter', 'project', 'llvm-object', 'c-client'}
SOURCE_SUFFIXES = {'.vrn', '.py', '.json', '.c'}

class AuditFailure(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise AuditFailure(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inside(root, value):
    path = (Path(root) / value).resolve()
    require(path.is_relative_to(Path(root).resolve()), f'path escapes isolated workspace: {value}')
    return path


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        require(name not in result, f'duplicate policy key: {name}')
        result[name] = value
    return result


def load_policy(path):
    value = json.loads(Path(path).read_text(), object_pairs_hook=unique_object)
    require(value.get('version') == 1, 'unsupported audit policy version')
    require(isinstance(value.get('targets'), dict), 'policy requires a target map')
    return value['targets']


def snapshot(root, workspace):
    """Copy source inputs, never artifacts or an existing output directory."""
    original = root / 'projects'
    require(original.is_dir(), 'projects source directory is missing')
    hashes = {}
    for source in sorted(original.rglob('*')):
        relative = source.relative_to(original)
        if any(part in {'.git', '.cache', '.direnv', 'build', 'dist', '__pycache__'}
               for part in relative.parts[1:-1]):
            continue
        if not source.is_file() or not (source.name == 'verona.build' or source.suffix in SOURCE_SUFFIXES):
            continue
        require(source.resolve().is_relative_to(original.resolve()), f'external source symlink: {source}')
        data = source.read_bytes()
        # A misleading source suffix must not smuggle a native artifact in.
        require(not native_magic(data), f'native artifact among source inputs: {source}')
        destination = workspace / 'projects' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        hashes[str(destination.relative_to(workspace))] = hashlib.sha256(data).hexdigest()
    require(any(name.endswith('/verona.build') for name in hashes), 'no project manifests found')
    return hashes


def unchanged(workspace, hashes):
    return all((workspace / name).is_file() and digest(workspace / name) == expected
               for name, expected in hashes.items())


def native_magic(data):
    if data.startswith(b'!<arch>\n'):
        return 'archive'
    if data.startswith(b'\x7fELF') or data[:4] in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe',
          b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        return 'object'
    return None


def inventory(text, source, manifest):
    """Read only identity metadata from the compiler's indexed reader output."""
    lines = text.splitlines()
    require(lines and re.fullmatch(r'roots=\[([ 0-9]*)\]', lines[0]), f'{manifest}: invalid reader roots')
    roots = [int(x) for x in lines[0].split('[', 1)[1].rstrip(']').split()]
    nodes = {}
    for line in lines[1:]:
        match = re.match(r'^(\d+) (\S+) file=\d+ bytes=(\d+)\.\.(\d+) name=\d+ at=\d+:\d+(.*)$', line)
        if not match:
            continue  # Literal spellings may contain newlines; identities use byte spans.
        node, kind, start, end, tail = match.groups()
        node = int(node)
        require(node not in nodes, f'{manifest}: duplicate indexed reader node')
        start, end = int(start), int(end)
        require(0 <= start <= end <= len(source), f'{manifest}: invalid reader span')
        children = []
        if kind == 'list':
            child = re.fullmatch(r' children=\[([ 0-9]*) \]', tail)
            require(child, f'{manifest}: invalid indexed children')
            children = [int(x) for x in child[1].split()]
        nodes[node] = (kind, source[start:end].decode('ascii') if kind == 'identifier' else '', children)
    result = []
    seen = set()
    for node in roots:
        require(node in nodes and nodes[node][0] == 'list' and len(nodes[node][2]) >= 2,
                f'{manifest}: expected a named artifact declaration')
        head, name = nodes[node][2][:2]
        require(head in nodes and name in nodes and nodes[head][0] == nodes[name][0] == 'identifier',
                f'{manifest}: artifact kind and target name must be identifiers')
        kind, target = nodes[head][1], nodes[name][1]
        key = manifest + '::' + target
        require(key not in seen, f'duplicate manifest target: {key}')
        seen.add(key)
        result.append(dict(id=key, manifest=manifest, name=target, kind=kind))
    return result


def validate_policy(targets, policies):
    discovered = {t['id']: t for t in targets}
    issues = []
    for key in discovered.keys() - policies.keys():
        discovered[key]['status'] = 'policy-required'
        issues.append(f'new target needs an audit policy: {key}')
    for key in policies.keys() - discovered.keys():
        issues.append(f'policy target no longer exists: {key}')
    for key, target in discovered.items():
        if target['kind'] not in KINDS:
            target['status'] = 'unsupported-artifact'
            issues.append(f'unsupported artifact kind {target["kind"]}: {key}')
    outputs = set()
    for key, value in policies.items():
        if key not in discovered:
            continue
        target = discovered[key]
        if set(value) - {'kind', 'mode', 'output', 'depends_on', 'checks', 'reason', 'failure'}:
            issues.append(f'unknown policy field: {key}')
        if value.get('kind') != target['kind']:
            issues.append(f'artifact kind changed: {key}')
        mode = value.get('mode')
        if mode not in {'run', 'library', 'negative', 'build-only'}:
            issues.append(f'invalid validation mode: {key}')
        if mode == 'run' and (target['kind'] != 'executable' or not value.get('checks')):
            issues.append(f'executable needs runtime checks: {key}')
        if mode == 'library' and target['kind'] == 'executable':
            issues.append(f'library policy on executable: {key}')
        if mode == 'build-only' and not value.get('reason'):
            issues.append(f'build-only policy needs a reason: {key}')
        if mode == 'negative' and value.get('failure', {}).get('phase') not in {'analysis', 'link'}:
            issues.append(f'negative fixture needs an expected phase: {key}')
        if any(c.get('type', 'command') not in CHECKS for c in value.get('checks', [])):
            issues.append(f'unknown runtime check: {key}')
        for check in value.get('checks', []):
            allowed = {'type', 'args', 'stdin', 'stdin_hex', 'exit', 'stdout', 'stderr', 'stdout_regex',
                       'stderr_regex', 'stdout_contains', 'stderr_contains', 'cwd', 'files', 'env', 'source', 'methods'}
            if set(check) - allowed:
                issues.append(f'unknown runtime check field: {key}')
            if 'stdin' in check and 'stdin_hex' in check:
                issues.append(f'conflicting runtime input: {key}')
            for field in ('stdout_regex', 'stderr_regex'):
                try:
                    if field in check: re.compile(check[field])
                except re.error:
                    issues.append(f'invalid {field}: {key}')
            if check.get('type') == 'compiler' and not check.get('methods'):
                issues.append(f'compiler check needs explicit test methods: {key}')
            if check.get('type') == 'c-client' and not check.get('source'):
                issues.append(f'C client check needs source: {key}')
        if mode == 'negative':
            failure = value.get('failure', {})
            required = {'diagnostic', 'source', 'token'} if failure.get('phase') == 'analysis' else {'diagnostic', 'library'}
            if not required.issubset(failure):
                issues.append(f'incomplete expected failure: {key}')
        for dependency in value.get('depends_on', []):
            if dependency not in discovered or policies.get(dependency, {}).get('mode') == 'negative':
                issues.append(f'invalid dependency {dependency}: {key}')
        filenames = ([target['name']] if target['kind'] == 'executable' else
                     ['lib'+target['name']+suffix for suffix in ('.a', '.so', '.dylib', '.h')])
        for filename in filenames:
            location = (value.get('output', ''), filename)
            if location in outputs:
                issues.append(f'target output collision: {key}')
            outputs.add(location)
        if not value.get('output') or Path(value['output']).is_absolute() or '..' in Path(value['output']).parts:
            issues.append(f'output must be inside the isolated workspace: {key}')
    # Validate the complete graph before invoking any build.
    visited, active = set(), set()
    def visit(key):
        if key in active:
            issues.append(f'dependency cycle: {key}')
            return
        if key in visited or key not in discovered:
            return
        active.add(key)
        for dependency in policies.get(key, {}).get('depends_on', []):
            visit(dependency)
        active.remove(key)
        visited.add(key)
    for key in discovered:
        visit(key)
    return issues


def phase_matches(result, events, expected, project):
    if result['status'] != 'completed' or result['returncode'] != 2:
        return False
    if not re.search(expected['diagnostic'], result['stderr']):
        return False
    if expected['phase'] == 'analysis':
        source = project / expected['source']
        lines = source.read_text().splitlines()
        positions = [i + 1 for i, line in enumerate(lines) if expected['token'] in line]
        return not events and any(re.search(re.escape(str(source)) + rf':{line}:\d+:', result['stderr'])
                                  for line in positions)
    return any(e['tool'] == 'cc' and e['returncode'] != 0 and
               '-l' + expected['library'] in e['arguments'] for e in events)


class Recorder:
    def __init__(self, output):
        self.output = output
        self.lock = threading.Lock()
        self.data = dict(status='running', stage='initialization', commands=[], targets=[])
        (output / 'commands').mkdir()

    def save(self):
        with self.lock:
            atomic_json(self.output / 'results.json', self.data)
            rows = ['# Self-hosted project audit', '', 'Status: ' + self.data['status'], '']
            if self.data.get('reason'):
                rows += [self.data['reason'], '']
            rows += ['| Target | Kind | Build | Checks |', '| --- | --- | --- | --- |']
            rows += [f"| {t['id']} | {t['kind']} | {t.get('status', 'pending')} | {t.get('checks_status', 'pending')} |"
                     for t in self.data['targets']]
            rows += ['', 'Full commands, stdout, stderr, and timings are in `results.json` and `commands/`.', '']
            (self.output / 'REPORT.md').write_text('\n'.join(rows))

    def command(self, label, command, cwd, env, timeout=60, stdin=None):
        command = list(map(str, command))
        with self.lock:
            number = len(self.data['commands'])
            value = dict(id=number, label=label, command=command, cwd=str(cwd), timeout=timeout,
                         status='running', returncode=None, stdout='', stderr='',
                         stdin_hex=(stdin.encode() if isinstance(stdin, str) else stdin).hex() if stdin is not None else None,
                         environment={k: env.get(k) for k in ('VERONA_CORE_CLANG', 'VERONA_CORE_AR',
                           'VERONA_AUDIT_TOOL_LOG', 'VERONA_SOURCE_DIR', 'VERONA_LIBRARY_DIR',
                           'DYLD_LIBRARY_PATH', 'LD_LIBRARY_PATH')})
            self.data['commands'].append(value)
        start = time.monotonic()
        try:
            process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                stdout, stderr = process.communicate(stdin.encode() if isinstance(stdin, str) else stdin, timeout=timeout)
                status = 'completed'
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                stdout, stderr = process.communicate()
                status = 'timeout'
            update = dict(status=status, returncode=process.returncode,
                          stdout=stdout.decode('utf-8', 'replace'), stderr=stderr.decode('utf-8', 'replace'))
        except OSError as error:
            update = dict(status='tool-failure', error=str(error))
        with self.lock:
            value.update(update, seconds=round(time.monotonic()-start, 3))
            atomic_json(self.output/'commands'/f'{number:05d}.json', value)
        self.save()
        return value


def tool_path(value):
    resolved = shutil.which(value)
    require(resolved, f'host tool not found: {value}')
    # Preserve argv[0] for compiler wrappers and multi-call LLVM tools.
    return str(Path(resolved).absolute())


def native_tools():
    require(os.environ.get('VERONA_CL_LLVM'), 'enter the pinned Nix development shell first')
    llvm = tool_path('llvm-config')
    version = subprocess.check_output([llvm, '--version'], text=True).strip()
    require(version.split('.')[0] == '23', 'LLVM 23 is required')
    return dict(cc=tool_path(os.environ.get('VERONA_CORE_CLANG') or os.environ.get('VERONA_LINKER') or 'clang'),
                ar=tool_path(os.environ.get('VERONA_CORE_AR') or os.environ.get('VERONA_AR') or 'ar'),
                inspect=tool_path('llvm-readobj'), llvm_config=llvm, llvm_version=version)


def wrappers(output, tools):
    paths = {}
    for kind in ('cc', 'ar'):
        path = output / ('native-' + kind)
        path.write_text('#!/usr/bin/env python3\n' +
            'import json, os, subprocess, sys\n' +
            'command = ' + repr([tools[kind]]) + ' + sys.argv[1:]\n' +
            'result = subprocess.run(command, capture_output=True)\n' +
            'event = dict(tool=' + repr(kind) + ', arguments=sys.argv[1:], command=command, returncode=result.returncode, stdout=result.stdout.decode("utf-8","replace"), stderr=result.stderr.decode("utf-8","replace"))\n' +
            'with open(os.environ["VERONA_AUDIT_TOOL_LOG"],"a") as log: log.write(json.dumps(event)+"\\n")\n' +
            'sys.stdout.buffer.write(result.stdout)\nsys.stderr.buffer.write(result.stderr)\nsys.exit(result.returncode)\n')
        path.chmod(0o755)
        paths[kind] = str(path)
    return paths


def successful(result, expected=0):
    require(result['status'] == 'completed' and result['returncode'] == expected,
            f"{result['label']}: {result['status']}, exit {result['returncode']}; {result['stderr'][-1500:]}")


def schedule(targets, policies, build, jobs, completed=None):
    """Continue independent targets after failure; block only their consumers."""
    pending = {t['id']: t for t in targets}
    results = {}
    running = {}
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        while pending or running:
            progressed = False
            for key, target in list(pending.items()):
                dependencies = policies[key].get('depends_on', [])
                if not all(d in results for d in dependencies):
                    continue
                if any(results[d]['status'] != 'built' for d in dependencies):
                    results[key] = dict(target, status='blocked', reason='dependency build failed', checks_status='blocked')
                    del pending[key]
                    progressed = True
                    if completed: completed(results[key])
                elif len(running) < jobs:
                    running[pool.submit(build, target, policies[key])] = key
                    del pending[key]
            if running:
                finished, _ = wait(running, return_when=FIRST_COMPLETED)
                for future in finished:
                    key = running.pop(future)
                    try:
                        results[key] = future.result()
                    except Exception as error:
                        results[key] = dict(next(t for t in targets if t['id'] == key), status='failed',
                                            reason=str(error), checks_status='blocked')
                    if completed: completed(results[key])
            elif not progressed:
                require(not pending, 'unresolved audit dependencies')
    return [results[t['id']] for t in targets]


class Runner:
    def __init__(self, root, compiler, output, policies, jobs=2, build_timeout=1200, tools=None):
        self.root, self.compiler, self.output = root, compiler, output
        self.workspace = output / 'workspace'
        self.policies, self.jobs, self.build_timeout = policies, jobs, build_timeout
        self.tools = tools
        self.record = Recorder(output)
        self.environment = dict(os.environ)
        self.built = {}

    def environment_for(self, label):
        env = dict(self.environment)
        log = self.output / 'commands' / (hashlib.sha256(label.encode()).hexdigest() + '.native.jsonl')
        env.update(VERONA_CORE_CLANG=self.wrappers['cc'], VERONA_CORE_AR=self.wrappers['ar'],
                   VERONA_AUDIT_TOOL_LOG=str(log), VERONA_SOURCE_DIR=str(self.workspace/'projects'),
                   VERONA_LIBRARY_DIR=str(self.workspace/'build'))
        for key in ('LD_PRELOAD', 'DYLD_INSERT_LIBRARIES'):
            env.pop(key, None)
        folders = sorted({str(Path(path).parent) for path in self.built.values() if Path(path).suffix in {'.so', '.dylib'}})
        key = 'DYLD_LIBRARY_PATH' if sys.platform == 'darwin' else 'LD_LIBRARY_PATH'
        existing = [p for p in env.get(key, '').split(os.pathsep) if p and
                    not Path(p).resolve().is_relative_to(self.root/'build')]
        env[key] = os.pathsep.join(folders + existing)
        return env, log

    def command(self, label, args, cwd=None, expected=0, timeout=60, stdin=None, changes=None):
        env, _ = self.environment_for(label)
        for key, value in (changes or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
        result = self.record.command(label, args, cwd or self.workspace, env, timeout, stdin)
        successful(result, expected)
        return result

    def build(self, target, policy):
        key = target['id']
        project = self.workspace / Path(target['manifest']).parent
        folder = inside(self.workspace, policy['output'])
        name = target['name']
        candidates = [folder/name, folder/('lib'+name+'.a'), folder/('lib'+name+'.so'),
                      folder/('lib'+name+'.dylib'), folder/('lib'+name+'.h')]
        require(not any(p.exists() or p.is_symlink() for p in candidates), f'stale artifact before build: {key}')
        env, log = self.environment_for(key)
        result = self.record.command(key, [self.compiler, 'build', name, folder], project, env, self.build_timeout)
        events = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        value = dict(target, checks_status='pending', native_tools=events)
        if policy['mode'] == 'negative':
            require(phase_matches(result, events, policy['failure'], project), f'wrong failure phase or diagnostic: {key}')
            require(not any(p.exists() or p.is_symlink() for p in candidates), f'failed build left an artifact: {key}')
            value.update(status='expected-'+policy['failure']['phase']+'-failure', checks_status='not-applicable')
        else:
            successful(result)
            require(len(result['stdout'].strip().splitlines()) == 1, f'build did not return one artifact path: {key}')
            artifact = Path(result['stdout'].strip())
            require(artifact.is_absolute() and artifact.resolve().is_relative_to(folder) and not artifact.is_symlink(),
                    f'artifact is outside its isolated output directory: {key}')
            require(artifact in candidates[:4] and artifact.is_file(), f'missing or misnamed artifact: {key}')
            magic = native_magic(artifact.read_bytes()[:8])
            require(magic == ('archive' if target['kind'] == 'static-library' else 'object'), f'invalid artifact: {key}')
            require(any(e['tool'] == ('ar' if target['kind'] == 'static-library' else 'cc') and e['returncode'] == 0
                        for e in events), f'build did not complete its native tool: {key}')
            value.update(status='built', artifact=str(artifact), sha256=digest(artifact))
            if target['kind'] != 'executable':
                header = artifact.with_suffix('.h')
                require(header.is_file() and not header.is_symlink(), f'missing generated header: {key}')
                value.update(header=str(header), header_sha256=digest(header))
        print(f"{key}: {value['status']}", flush=True)
        return value

    def ordinary_check(self, target, check, index):
        key = target['id'] + f'/check-{index}'
        artifact = self.built[target['id']]
        cwd = inside(self.workspace, check.get('cwd', 'checks/'+hashlib.sha256(key.encode()).hexdigest()[:12]))
        cwd.mkdir(parents=True, exist_ok=True)
        for name, content in check.get('files', {}).items():
            path = inside(cwd, name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        result = self.command(key, [artifact, *check.get('args', [])], cwd,
                    expected=check.get('exit', 0), stdin=bytes.fromhex(check['stdin_hex']) if 'stdin_hex' in check else check.get('stdin'), changes=check.get('env'))
        for stream in ('stdout', 'stderr'):
            if stream in check:
                require(result[stream] == check[stream], f'{key}: unexpected {stream}: {result[stream]!r}')
            if stream+'_regex' in check:
                require(re.search(check[stream+'_regex'], result[stream]), f'{key}: unexpected {stream}')
            for text in check.get(stream+'_contains', []):
                require(text in result[stream], f'{key}: missing {text!r} in {stream}')

    def special_check(self, target, check, index):
        key = target['id'] + f'/check-{index}'
        artifact = Path(self.built[target['id']])
        directory = self.workspace/'checks'/hashlib.sha256(key.encode()).hexdigest()[:12]
        directory.mkdir(parents=True, exist_ok=True)
        kind = check['type']
        if kind == 'compiler':
            tests = self.workspace/'projects/compiler/tests'
            require(not (self.workspace/'build/verona').exists(), 'a reference compiler appeared in the isolated tree')
            self.command(key+'/focused', [sys.executable, tests/'test_core.py', artifact, *check['methods']], timeout=600)
            self.command(key+'/shared', [sys.executable, tests/'shared_suite.py', artifact, '--output', directory/'shared'], timeout=600)
        elif kind == 'formatter':
            original = '(foo   bar)\n'
            formatted = self.command(key+'/stdin', [artifact], stdin=original)['stdout']
            require(formatted == '(foo bar)\n', 'formatter stdin smoke check failed')
            sample = directory/'sample.vrn'
            sample.write_text(formatted)
            self.command(key+'/check', [artifact, '--check', sample])
            again = self.command(key+'/idempotence', [artifact], stdin=formatted)['stdout']
            require(again == formatted, 'formatter output is not idempotent')
        elif kind == 'project':
            self.command(key+'/help', [artifact, '--help'])
            self.command(key+'/new', [artifact, 'new', 'audit-app'], cwd=directory)
            require((directory/'audit-app/verona.build').is_file() and (directory/'audit-app/src/main.vrn').is_file(),
                    'project tool did not create its source/manifest')
            self.command(key+'/refuse-existing', [artifact, 'new', 'audit-app'], cwd=directory, expected=1)
            result = self.command(key+'/libraries', [artifact, 'libraries'])
            require(all(name+':' in result['stdout'] for name in ('base', 'foundation', 'libc', 'testing')),
                    'project library listing is incomplete')
        elif kind == 'llvm-object':
            obj = directory/'native.o'
            self.command(key+'/emit', [artifact, obj, directory/'missing-parent/bad.o'])
            require(obj.is_file() and native_magic(obj.read_bytes()[:8]) == 'object', 'LLVM test did not emit a native object')
            binary = directory/'llvm-client'
            self.command(key+'/link', [self.wrappers['cc'], obj, '-o', binary])
            self.command(key+'/run', [binary], expected=42)
        elif kind == 'c-client':
            header = artifact.with_suffix('.h')
            source = directory/'client.c'
            source.write_text('#include "'+str(header)+'"\n'+check['source']+'\n')
            binary = directory/'client'
            self.command(key+'/link', [self.wrappers['cc'], source, artifact, '-o', binary])
            self.command(key+'/run', [binary])

    def check_dependencies(self, target, policy):
        if not policy.get('depends_on'):
            return
        artifact = self.built[target['id']]
        result = self.command(target['id']+'/native-dependencies', [self.tools['inspect'], '--needed-libs', artifact])
        for key in policy['depends_on']:
            dependency = Path(self.built[key])
            if dependency.suffix not in {'.so', '.dylib'}:
                continue
            lines = [line.strip() for line in result['stdout'].splitlines() if dependency.name in line]
            require(lines, f'missing native dependency: {key}')
            for name in lines:
                if name.startswith('/'):
                    require(Path(name).resolve() == dependency.resolve(), f'native dependency escaped fresh outputs: {name}')
            # ELF DT_NEEDED may be a basename. The runtime environment puts the
            # verified fresh library directory first, before native loader paths.

    def run(self):
        try:
            require(self.compiler.is_file() and os.access(self.compiler, os.X_OK), 'explicit self-hosted compiler is missing or not executable')
            require(not self.output.is_relative_to(self.root/'projects'), 'audit output cannot be inside project sources')
            self.seed_hash = digest(self.compiler)
            self.tools = self.tools or native_tools()
            self.wrappers = wrappers(self.output, self.tools)
            self.record.data.update(compiler=dict(path=str(self.compiler), sha256=self.seed_hash),
                runner_sha256=digest(Path(__file__)), native_tools=self.tools,
                policy=self.policies, host=dict(platform=sys.platform, python=sys.version),
                environment={k: os.environ.get(k) for k in ('VERONA_CL_LLVM', 'VERONA_LINKER', 'VERONA_AR',
                  'VERONA_CORE_CLANG', 'VERONA_CORE_AR', 'NIX_LDFLAGS', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET')})
            for label, args in [('revision', ['git', 'rev-parse', 'HEAD']),
                                ('working_tree', ['git', 'status', '--porcelain']),
                                ('submodules', ['git', 'submodule', 'status', '--recursive'])]:
                value = subprocess.run(args, cwd=self.root, capture_output=True, text=True)
                self.record.data[label] = dict(returncode=value.returncode, stdout=value.stdout, stderr=value.stderr)
            self.record.data['stage'] = 'snapshot'
            self.record.data['source_sha256'] = snapshot(self.root, self.workspace)
            self.record.data['stage'] = 'inventory'
            targets = []
            for path in sorted(self.workspace.glob('projects/**/verona.build')):
                manifest = str(path.relative_to(self.workspace))
                result = self.command('inventory/'+manifest, [self.compiler, 'read', path])
                targets += inventory(result['stdout'], path.read_bytes(), manifest)
                self.record.data['targets'] = targets
                self.record.save()
            self.record.data['targets'] = targets
            issues = validate_policy(targets, self.policies)
            require(not issues, '\n'.join(issues))
            self.record.data['stage'] = 'builds'
            self.record.save()
            def completed(value):
                with self.record.lock:
                    self.record.data['targets'] = [value if t['id'] == value['id'] else t
                                                  for t in self.record.data['targets']]
                self.record.save()
            results = schedule(targets, self.policies, self.build, self.jobs, completed)
            self.record.data['targets'] = results
            self.built = {t['id']: t['artifact'] for t in results if t['status'] == 'built'}
            self.record.save()
            self.record.data['stage'] = 'runtime checks'
            for target in results:
                policy = self.policies[target['id']]
                if target['status'] != 'built':
                    continue
                if policy['mode'] == 'build-only':
                    target.update(checks_status='build-only', reason=policy['reason'])
                    continue
                try:
                    self.check_dependencies(target, policy)
                    if policy['mode'] == 'library':
                        self.command(target['id']+'/header', [self.wrappers['cc'], '-x', 'c', '-fsyntax-only',
                                     '-include', target['header'], '/dev/null'])
                    for index, check in enumerate(policy.get('checks', [])):
                        if check.get('type', 'command') == 'command':
                            self.ordinary_check(target, check, index)
                        else:
                            self.special_check(target, check, index)
                    target['checks_status'] = 'passed'
                except (AuditFailure, OSError, ValueError) as error:
                    target.update(checks_status='failed', reason=str(error))
                self.record.save()
                print(target['id']+': checks '+target['checks_status'], flush=True)
            require(unchanged(self.workspace, self.record.data['source_sha256']), 'isolated source inputs changed during audit')
            require(digest(self.compiler) == self.seed_hash, 'selected compiler changed during audit')
            require(all(t['status'] in {'built', 'expected-analysis-failure', 'expected-link-failure'} and
                        t['checks_status'] in {'passed', 'not-applicable', 'build-only'} for t in results),
                    'one or more project builds or checks failed')
            self.record.data.update(status='passed', stage='complete')
            return 0
        except Exception as error:
            self.record.data.update(status='failed', reason=str(error))
            print(str(error), file=sys.stderr)
            return 1
        finally:
            self.record.save()
            print('Evidence: '+str(self.output), flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, required=True, help='explicit self-hosted compiler; no bootstrap or fallback is performed')
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--policy', type=Path, default=POLICY)
    parser.add_argument('--output', type=Path, default=ROOT/'build/self-hosted-projects')
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--build-timeout', type=float, default=1200)
    args = parser.parse_args(argv)
    if args.jobs < 1 or args.build_timeout <= 0:
        parser.error('--jobs and --build-timeout must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=args.output)).resolve()
    try:
        policies = load_policy(args.policy)
    except (AuditFailure, OSError, ValueError) as error:
        record = Recorder(output)
        record.data.update(status='failed', reason=str(error))
        record.save()
        print(str(error)+'\nEvidence: '+str(output), file=sys.stderr)
        return 1
    return Runner(args.root.resolve(), args.compiler.resolve(), output, policies,
                  args.jobs, args.build_timeout).run()


if __name__ == '__main__':
    sys.exit(main())

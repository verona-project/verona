"""Audit discovery, isolation, failure-phase, and no-fallback contracts."""
import copy
from contextlib import redirect_stdout, redirect_stderr
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import Mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('project_audit', ROOT/'scripts/self-hosted-projects.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def indexed(kinds=('executable',), names=('app',)):
    source = b''
    nodes, roots = [], []
    for kind, name in zip(kinds, names):
        spelling = f'({kind} {name} (root main))'.encode()
        start = len(source)
        source += spelling + b'\n'
        node = len(nodes)
        roots.append(node)
        head = start + 1
        target = head + len(kind) + 1
        nodes.extend([
          f'{node} list file=1 bytes={start}..{start+len(spelling)} name=0 at=1:1 children=[ {node+1} {node+2} ]',
          f'{node+1} identifier file=1 bytes={head}..{head+len(kind)} name=0 at=1:2 spelling={kind}',
          f'{node+2} identifier file=1 bytes={target}..{target+len(name)} name=0 at=1:3 spelling={name}',
        ])
    return source, 'roots=[ '+ ' '.join(map(str,roots)) +' ]\n'+'\n'.join(nodes)+'\n'


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='verona audit tests ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.output = self.root/'evidence'
        self.output.mkdir()
        self.project = self.root/'projects/example'
        (self.project/'src').mkdir(parents=True)
        (self.project/'src/main.vrn').write_text('(%function main () i32 0)')
        self.source, self.flat = indexed()
        (self.project/'verona.build').write_bytes(self.source)
        self.target = dict(id='projects/example/verona.build::app', manifest='projects/example/verona.build', name='app', kind='executable')
        self.policy = {self.target['id']:dict(kind='executable',mode='run',output='build/example',checks=[dict(exit=0)])}
        self.tools = dict(cc='/usr/bin/true', ar='/usr/bin/true', inspect='/usr/bin/true')

    def test_inventory_uses_source_spans_and_keeps_manifest_identity(self):
        source, flat = indexed(('executable','static-library'), ('app','lib'))
        targets = audit.inventory(flat, source, 'projects/foo/verona.build')
        self.assertEqual([t['name'] for t in targets], ['app','lib'])
        self.assertEqual(targets[1]['id'], 'projects/foo/verona.build::lib')
        with self.assertRaises(audit.AuditFailure):
            audit.inventory(flat.replace('bytes=1..11','bytes=1..999999'), source, 'x')
        with self.assertRaises(audit.AuditFailure):
            audit.inventory('unsupported reader protocol',source,'x')

    def test_unicode_comments_do_not_change_inventory_identity(self):
        source, flat = indexed()
        # The reader's list span includes comments; only identity tokens need
        # ASCII decoding. No second lexer should interpret the comment bytes.
        source += b'; ' + '\u2192'.encode() + b'\n'
        # Extend the actual list span independent of the fixture's exact size.
        flat = audit.re.sub(r'(^0 list file=1 bytes=0\.\.)[0-9]+',
                            lambda m:m[1]+str(len(source)), flat, flags=audit.re.M)
        result=audit.inventory(flat,source,'projects/example/verona.build')
        self.assertEqual(result[0]['name'],'app')

    def test_new_removed_and_unsupported_targets_fail_policy_validation(self):
        policies=copy.deepcopy(self.policy)
        policies['stale'] = policies.pop(self.target['id'])
        issues=audit.validate_policy([self.target],policies)
        self.assertTrue(any('needs an audit policy' in i for i in issues))
        self.assertTrue(any('no longer exists' in i for i in issues))
        unknown=dict(self.target,kind='future-library')
        issues=audit.validate_policy([unknown],self.policy)
        self.assertEqual(unknown['status'],'unsupported-artifact')
        self.assertTrue(any('unsupported artifact' in i for i in issues))

    def test_policy_cycles_unknown_checks_and_typos_fail_before_builds(self):
        policies=copy.deepcopy(self.policy)
        policies[self.target['id']].update(depends_on=[self.target['id']],checks=[dict(type='unknown')],typo=True)
        issues=audit.validate_policy([self.target],policies)
        for text in ('cycle','unknown runtime check','unknown policy field'):
            self.assertTrue(any(text in i for i in issues),issues)

    def test_policy_output_collision_and_unsafe_paths(self):
        other=dict(self.target,id='other',name='libapp.a')
        policy=copy.deepcopy(self.policy)
        policy[self.target['id']].update(kind='static-library',mode='library')
        original=dict(self.target,kind='static-library')
        policy['other']=dict(kind='executable',mode='run',output='build/example',checks=[{}])
        self.assertTrue(any('collision' in i for i in audit.validate_policy([original,other],policy)))
        with self.assertRaises(audit.AuditFailure):
            audit.inside(self.root,'../escape')

    def test_snapshot_copies_inputs_but_no_native_artifacts(self):
        (self.project/'old.a').write_bytes(b'!<arch>\n')
        (self.project/'dist').mkdir()
        (self.project/'dist/generated.vrn').write_text('old output')
        (self.root/'build').mkdir()
        (self.root/'build/verona').write_text('host compiler')
        workspace=self.output/'workspace'
        hashes=audit.snapshot(self.root,workspace)
        self.assertTrue((workspace/'projects/example/src/main.vrn').exists())
        self.assertFalse((workspace/'build').exists())
        self.assertFalse((workspace/'projects/example/old.a').exists())
        self.assertFalse((workspace/'projects/example/dist/generated.vrn').exists())
        self.assertTrue(audit.unchanged(workspace,hashes))
        (workspace/'projects/example/src/main.vrn').write_text('changed')
        self.assertFalse(audit.unchanged(workspace,hashes))

    def test_snapshot_rejects_external_source_links(self):
        external=self.root/'outside.vrn'
        external.write_text('external')
        (self.project/'src/linked.vrn').symlink_to(external)
        with self.assertRaisesRegex(audit.AuditFailure,'external source symlink'):
            audit.snapshot(self.root,self.output/'workspace')

    def test_expected_failures_must_reach_the_correct_phase(self):
        source=self.project/'src/broken.vrn'
        source.write_text('(%function main () i32\n  missing-value)\n')
        expected=dict(phase='analysis',diagnostic='unknown local name',source='src/broken.vrn',token='missing-value')
        result=dict(status='completed',returncode=2,stderr=str(source)+':2:3: unknown local name')
        self.assertTrue(audit.phase_matches(result,[],expected,self.project))
        events=[dict(tool='cc',returncode=1,arguments=['-lmissing'])]
        self.assertFalse(audit.phase_matches(result,events,expected,self.project))
        link=dict(phase='link',diagnostic='missing',library='missing')
        result['stderr']='library missing'
        self.assertFalse(audit.phase_matches(result,[],link,self.project))
        self.assertTrue(audit.phase_matches(result,events,link,self.project))
        result['status']='timeout'
        self.assertFalse(audit.phase_matches(result,events,link,self.project))

    def test_missing_compiler_never_starts_a_bootstrap(self):
        runner=audit.Runner(self.root,self.root/'missing',self.output,self.policy,tools=self.tools)
        with redirect_stdout(io.StringIO()),redirect_stderr(io.StringIO()):
            self.assertEqual(runner.run(),1)
        report=json.loads((self.output/'results.json').read_text())
        self.assertEqual(report['status'],'failed')
        self.assertEqual(report['commands'],[])
        self.assertTrue((self.output/'REPORT.md').exists())

    def test_missing_tool_and_timeout_retain_diagnostics(self):
        record=audit.Recorder(self.output)
        missing=record.command('missing',[self.root/'not-a-tool'],self.root,dict(os.environ),1)
        self.assertEqual(missing['status'],'tool-failure')
        timed=record.command('timeout',[sys.executable,'-c','import time; print("started",flush=True); time.sleep(30)'],
                             self.root,dict(os.environ),1)
        self.assertEqual(timed['status'],'timeout')
        self.assertLess(timed['seconds'],5)
        self.assertIn('started',timed['stdout'])
        self.assertEqual(len(list((self.output/'commands').glob('*.json'))),2)

    def test_dependency_failures_block_consumers_but_not_independent_targets(self):
        targets=[dict(id=k) for k in ('c','b','a','independent')]
        policies={k:dict(depends_on=d) for k,d in [('a',[]),('b',['a']),('c',['b']),('independent',[])]}
        called=[]
        def build(target,policy):
            called.append(target['id'])
            return dict(target,status='failed' if target['id']=='a' else 'built')
        results=audit.schedule(targets,policies,build,2)
        self.assertEqual(set(called),{'a','independent'})
        self.assertEqual([t['status'] for t in results],['blocked','blocked','failed','built'])

    def test_stale_and_missing_artifacts_cannot_satisfy_a_build(self):
        runner=audit.Runner(self.root,self.root/'compiler',self.output,self.policy,tools=self.tools)
        runner.wrappers=dict(cc='cc',ar='ar')
        runner.workspace.mkdir()
        folder=runner.workspace/'build/example'
        folder.mkdir(parents=True)
        artifact=folder/'app'
        artifact.write_bytes(b'\x7fELFfake')
        runner.record.command=Mock()
        with self.assertRaisesRegex(audit.AuditFailure,'stale artifact'):
            runner.build(self.target,self.policy[self.target['id']])
        runner.record.command.assert_not_called()
        artifact.unlink()
        runner.record.command.return_value=dict(status='completed',returncode=0,stdout=str(artifact)+'\n',stderr='',label='fake')
        with self.assertRaisesRegex(audit.AuditFailure,'missing or misnamed artifact'):
            runner.build(self.target,self.policy[self.target['id']])

    def test_reader_rejection_is_reported_without_host_fallback(self):
        seed=self.root/'compiler'
        seed.write_text('#!/usr/bin/env python3\nimport sys\nprint("read unsupported",file=sys.stderr)\nsys.exit(2)\n')
        seed.chmod(0o755)
        runner=audit.Runner(self.root,seed,self.output,self.policy,tools=self.tools)
        with redirect_stdout(io.StringIO()),redirect_stderr(io.StringIO()):
            self.assertEqual(runner.run(),1)
        report=json.loads((self.output/'results.json').read_text())
        self.assertEqual(report['stage'],'inventory')
        self.assertEqual(len(report['commands']),1)
        self.assertEqual(report['commands'][0]['command'][0],str(seed))
        self.assertEqual(report['commands'][0]['command'][1],'read')
        self.assertIn('read unsupported',report['commands'][0]['stderr'])

    def test_native_wrappers_record_real_invocation_and_status(self):
        paths=audit.wrappers(self.output,self.tools)
        log=self.output/'native.jsonl'
        result=audit.subprocess.run([paths['cc'],'argument with spaces'],env=dict(os.environ,VERONA_AUDIT_TOOL_LOG=str(log)),capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        event=json.loads(log.read_text())
        self.assertEqual(event['arguments'],['argument with spaces'])
        self.assertEqual(event['returncode'],0)

    def test_duplicate_policy_json_keys_are_rejected(self):
        path=self.root/'policy.json'
        path.write_text('{"version":1,"version":1,"targets":{}}')
        with self.assertRaisesRegex(audit.AuditFailure,'duplicate policy key'):
            audit.load_policy(path)

    def test_real_policy_covers_the_current_discovery_contract(self):
        policies=audit.load_policy(ROOT/'scripts/self-hosted-projects.json')
        self.assertTrue(policies)
        targets=[dict(id=key,manifest=key.split('::')[0],name=key.split('::')[1],kind=value['kind'])
                 for key,value in policies.items()]
        self.assertEqual(audit.validate_policy(targets,policies),[])


if __name__=='__main__':
    unittest.main()

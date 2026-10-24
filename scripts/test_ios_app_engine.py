#!/usr/bin/env python3
"""Check resource integrity and copy boundaries with synthetic app directories."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('engine_copy',ROOT/'scripts/copy-ios-app-engine.py')
copy=importlib.util.module_from_spec(spec);spec.loader.exec_module(copy)
sha=lambda data:hashlib.sha256(data).hexdigest()


class EngineCopyTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='msl-engine-copy-')
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name);self.app=self.root/'Fixture.app';self.app.mkdir()
        self.prepared=self.root/'prepared';self.prepared.mkdir()
        self.bundle=self.prepared/'bundle';(self.bundle/'engine').mkdir(parents=True)
        (self.bundle/'engine/one.jar').write_bytes(b'project-owned fixture data')
        (self.prepared/'native').mkdir();(self.prepared/'native/libfixture.a').write_bytes(b'owned archive descriptor fixture')
        (self.prepared/'Engine.xcconfig').write_text('fixture build settings\n')
        self.inputs=self.prepared/'EngineInputs.json'
        self.record={'path':'engine/one.jar','bytes':len(b'project-owned fixture data'),'sha256':sha(b'project-owned fixture data')}
        self.manifest={'format':1,'passed':True,'bundle_files':[self.record],
                       'native_libraries':[{'path':'native/libfixture.a','bytes':len(b'owned archive descriptor fixture'),'sha256':sha(b'owned archive descriptor fixture')}],
                       'xcconfig_sha256':sha(b'fixture build settings\n')}
        self.write()
    def write(self): self.inputs.write_text(json.dumps(self.manifest))
    def test_exact_bytes_are_copied_and_collisions_are_rejected(self):
        self.assertEqual(copy.copy_engine(self.inputs,self.app),1)
        self.assertEqual((self.app/'engine/one.jar').read_bytes(),b'project-owned fixture data')
        with self.assertRaises(ValueError):copy.copy_engine(self.inputs,self.app)
    def test_mutated_payload_is_rejected_before_any_copy(self):
        (self.bundle/'engine/one.jar').write_bytes(b'tampered')
        with self.assertRaises(ValueError):copy.copy_engine(self.inputs,self.app)
        self.assertEqual(list(self.app.iterdir()),[])
    def test_changed_native_or_link_settings_fail_preflight(self):
        (self.prepared/'native/libfixture.a').write_bytes(b'changed')
        with self.assertRaises(ValueError):copy.verify_inputs(self.inputs)
        (self.prepared/'native/libfixture.a').write_bytes(b'owned archive descriptor fixture')
        (self.prepared/'Engine.xcconfig').write_text('changed')
        with self.assertRaises(ValueError):copy.verify_inputs(self.inputs)
    def test_paths_links_and_duplicates_are_rejected(self):
        for path in ['../outside','/outside','engine\\outside']:
            self.record['path']=path;self.write()
            with self.assertRaises(ValueError):copy.copy_engine(self.inputs,self.app)
        self.record['path']='engine/one.jar';self.manifest['bundle_files']=[self.record,self.record];self.write()
        with self.assertRaises(ValueError):copy.copy_engine(self.inputs,self.app)
        self.manifest['bundle_files']=[self.record];self.write()
        (self.bundle/'engine/one.jar').unlink();(self.bundle/'engine/one.jar').symlink_to(self.prepared/'Engine.xcconfig')
        with self.assertRaises(ValueError):copy.copy_engine(self.inputs,self.app)
    def test_signed_apps_cannot_receive_new_resources(self):
        (self.app/'_CodeSignature').mkdir()
        with self.assertRaises(ValueError):copy.copy_engine(self.inputs,self.app)


if __name__=='__main__':
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(EngineCopyTests))
    report={'passed':result.wasSuccessful(),'tests':result.testsRun,
            'scope':'Synthetic engine resource copy/integrity boundaries only; no app, JVM, code linking or iOS execution.',
            'inputs_sha256':{str(p.relative_to(ROOT)):sha(p.read_bytes()) for p in [Path(__file__),ROOT/'scripts/copy-ios-app-engine.py']}}
    (ROOT/'validation/ios-app-engine-copy-host.json').write_text(json.dumps(report,indent=2)+'\n')
    raise SystemExit(0 if result.wasSuccessful() else 1)

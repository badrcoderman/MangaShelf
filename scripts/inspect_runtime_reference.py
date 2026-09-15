#!/usr/bin/env python3
"""Select traceable runtime evidence from the organized static extraction."""
import argparse,json,re
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('extraction',type=Path);a=p.parse_args();root=a.extraction
images=json.loads((root/'04-iOS-Bridge/native/macho.json').read_text())
main=next(x for x in images if x['path']=='Tachimanga')
methods=json.loads((root/'04-iOS-Bridge/native/objc-methods.json').read_text())['methods']
literals=json.loads((root/'05-Provenance/previous-verified-evidence/native-launch-literal-refs.json').read_text())
result={'source':'User-supplied Tachimanga IPA, static extraction','runtime_symbols':[s for s in main['symbols'] if s['name']=='_J9_CreateJavaVM' or s['name'].startswith('_JNI_OnLoad_')], 'launcher_methods':[m for m in methods if m['class']=='JavaLauncher'],'launch_literals':literals,'linked_runtime_libraries':[l for l in main['libraries'] if re.search('jvm|openj9|j9vm',l,re.I)],'module_count':sum(1 for l in (root/'02-Repositories-JAR/jvm/jre-module-index.txt').read_text().splitlines() if l.startswith('Module: ')),'limits':['Launch literals are from previously captured ARM64 analysis, not a live launch trace.','Defined symbols support embedded/static-linkage inference, not a recovered link map.','No claim that all library modules are needed.','iOS OpenJ9 SDK source and exact upstream patch set not recovered.']}
dest=Path(__file__).resolve().parents[1]/'docs/RUNTIME-REFERENCE.json';dest.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print('Saved',dest.name,'symbols',len(result['runtime_symbols']),'launcher methods',len(result['launcher_methods']))

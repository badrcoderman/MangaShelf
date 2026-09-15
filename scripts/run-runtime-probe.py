#!/usr/bin/env python3
"""Build only project-owned Java fixtures and exercise the selected host VM in interpreter mode."""
from pathlib import Path
import argparse, subprocess, zipfile, json
p=argparse.ArgumentParser();p.add_argument('--java',default='java');args=p.parse_args()
root=Path(__file__).resolve().parents[1];out=root/'build/runtime-probe';out.mkdir(parents=True,exist_ok=True)
for name,source in [('main','src'),('plugin','plugin')]:
 dest=out/name;dest.mkdir(exist_ok=True)
 subprocess.run([args.java,'-m','jdk.compiler/com.sun.tools.javac.Main','--release','17','-encoding','UTF-8','-d',str(dest),*[str(x) for x in sorted((root/'runtime-probe'/source).rglob('*.java'))]],check=True)
 with zipfile.ZipFile(out/(name+'.jar'),'w',zipfile.ZIP_DEFLATED) as z:
  for f in sorted(dest.rglob('*.class')):z.write(f,f.relative_to(dest))
cmd=[args.java,'-Xint','-cp',str(out/'main.jar'),'mangashelf.probe.RuntimeProbe',str(out/'plugin.jar'),str(out)]
r=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
result={'exit_code':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'scope':'Host VM only; does not verify iOS, JNI, or real extensions.'}
(out/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));raise SystemExit(r.returncode)

#!/usr/bin/env python3
"""Compile our JNI bridge against provided JDK headers and a linked host VM. No specimen code."""
import argparse,json,os,platform,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--jni-headers',type=Path,required=True);p.add_argument('--jni-platform-headers',type=Path,required=True);p.add_argument('--java-home',type=Path,required=True);p.add_argument('--cc',default='cc');args=p.parse_args()
root=Path(__file__).resolve().parents[1];out=root/'build/runtime-probe';out.mkdir(parents=True,exist_ok=True)
for path in [args.jni_headers/'jni.h',args.jni_platform_headers/'jni_md.h',out/'main.jar',out/'plugin.jar']:
 if not path.is_file():p.error('Missing required input: '+str(path))
lib=args.java_home/'lib/server';exe=out/'jni-host-probe'
cmd=[args.cc,'-std=c11','-Wall','-Wextra','-Werror','-I'+str(args.jni_headers),'-I'+str(args.jni_platform_headers),str(root/'runtime-native/MSJavaRuntime.c'),str(root/'runtime-native/host_probe.c'),'-L'+str(lib),'-Wl,-rpath,'+str(lib),'-ljvm','-lpthread','-o',str(exe)]
subprocess.run(cmd,check=True)
r=subprocess.run([str(exe),str(out/'main.jar'),str(args.java_home),str(out/'plugin.jar'),str(out)],capture_output=True,text=True,timeout=60)
result={'platform':platform.system(),'exit_code':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'checks':['JNI VM creation','native thread attach/detach','separate JAR and reflection','Java exception recovery'],'scope':'Host JNI integration; no claim of iOS runtime or real extension support.'}
(out/'jni-result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));raise SystemExit(r.returncode)

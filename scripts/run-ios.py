#!/usr/bin/env python3
"""Run a build-for-testing harness on an explicitly enrolled agent-only device.
No discovery of personal devices and no default destination. No Apple credentials.
"""
import argparse, base64, json, os, pathlib, plistlib, subprocess, sys, tempfile
p=argparse.ArgumentParser()
p.add_argument('--xctestrun',required=True);p.add_argument('--recipe',required=True)
p.add_argument('--device-id',required=True);p.add_argument('--enrollment',required=True)
p.add_argument('--result',required=True);p.add_argument('--prepare-only',action='store_true')
a=p.parse_args()
enrollment=json.loads(pathlib.Path(a.enrollment).read_text())
if enrollment.get('purpose')!='messagepilot-agent-device' or enrollment.get('deviceId')!=a.device_id:
    sys.exit('Device is not explicitly enrolled for agent automation')
recipe=json.loads(pathlib.Path(a.recipe).read_text())
if recipe.get('bundleId') not in enrollment.get('allowedBundles',[]):sys.exit('Bundle is not enrolled')
if not 1 <= len(recipe.get('actions',[])) <=100:sys.exit('Recipe needs 1-100 actions')
source=pathlib.Path(a.xctestrun).resolve()
data=plistlib.loads(source.read_bytes());encoded=base64.b64encode(json.dumps(recipe).encode()).decode()
matched=0
# Xcode has used both top-level target dictionaries and format-2 TestConfigurations.
def visit(value):
    global matched
    if isinstance(value,dict):
        if 'TestBundlePath' in value and 'MessagePilotHarness' in str(value['TestBundlePath']):
            value.setdefault('EnvironmentVariables',{})['MESSAGEPILOT_RECIPE_BASE64']=encoded;matched+=1
        for child in value.values():visit(child)
    elif isinstance(value,list):
        for child in value:visit(child)
visit(data)
if not matched:sys.exit('No MessagePilotHarness target found in xctestrun')
# Keep __TESTROOT__ resolution unchanged by placing the patched file beside the source.
fd,name=tempfile.mkstemp(prefix='messagepilot-',suffix='.xctestrun',dir=source.parent)
try:
    os.fchmod(fd,0o600)
    with os.fdopen(fd,'wb') as f:plistlib.dump(data,f)
    if a.prepare_only:
        print(json.dumps({'prepared':True,'targets':matched,'deviceId':a.device_id}));sys.exit(0)
    result=pathlib.Path(a.result).resolve()
    if result.exists():sys.exit('Result path exists; choose a fresh path')
    command=['/usr/bin/xcodebuild','test-without-building','-xctestrun',name,'-destination','id='+a.device_id,'-resultBundlePath',str(result),'-only-testing:MessagePilotHarness/MessagePilotHarness/testRecipe']
    sys.exit(subprocess.run(command,check=False,timeout=540).returncode)
finally:
    pathlib.Path(name).unlink(missing_ok=True)

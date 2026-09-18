import os,pathlib,subprocess,json,time
root=pathlib.Path.cwd(); lab=root/'.test-hold-validation'; env=os.environ.copy()
for k in list(env):
 if k.endswith('API_KEY') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID','FM_SUPERVISION_ACTOR']: env.pop(k,None)
env.update(FM_HOME=str(lab/'pi-home'),FM_STATE_OVERRIDE=str(lab/'pi-home/state'),FM_ROOT_OVERRIDE=str(root),PI_CODING_AGENT_DIR=str(lab/'pi-agent'),PI_OFFLINE='1',FM_GATE_REFUSE_BYPASS='1',PATH=str(lab/'pi-fakebin')+':'+str(lab/'node-v24.13.0-linux-x64/bin')+':'+env['PATH'])
args=['pi','--offline','--approve','--no-extensions','--no-skills','--no-prompt-templates','--no-themes','--no-context-files','--mode','rpc','--no-session','--provider','openai-codex','--model','gpt-6-astra','--thinking','high','-e',str(root/'.pi/extensions/fm-branch-supervision.ts'),'-e',str(lab/'pi-probe.ts')]
p=subprocess.Popen(args,cwd=lab,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
try:
 for line in p.stdout:
  print(line,end='',flush=True)
  if '"ready":true' in line:
   p.stdin.write(json.dumps({'type':'prompt','message':'/hold-validation'})+'\n');p.stdin.flush()
  if (lab/'pi-home/result.json').exists():
   p.stdin.close()
   break
 p.wait(timeout=15)
 print('PI_EXIT',p.returncode)
 result=json.loads((lab/'pi-home/result.json').read_text()); assert result['pass'],result
finally:
 if p.poll() is None:p.kill();p.wait()

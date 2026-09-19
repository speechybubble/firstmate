import os, pathlib, subprocess, json, hashlib
root=pathlib.Path.cwd(); area=root/'.test-phase'; ev=pathlib.Path('/home/denni/.no-mistakes/evidence/01M2VVKQWXBN90TPW34R58VBCD'); log=[]
env=os.environ.copy()
for k in ['FM_HOME','FM_STATE_OVERRIDE','FM_BACKEND','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']: env.pop(k,None)
env.update(FM_GATE_REFUSE_BYPASS='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(area/'tmp'))
def run(args,cwd=root,check=True,e=None):
 p=subprocess.run([str(a) for a in args],cwd=cwd,env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.append('$ '+ ' '.join(str(a) for a in args)+'\n'+p.stdout+f'[exit {p.returncode}]\n'); (ev/'live-cleanup.log').write_text('\n'.join(log))
 if check and p.returncode: raise RuntimeError(p.stdout)
 return p
socket=area/'tmux.sock'
run(['tmux','-S',socket,'new-session','-d','-s','validation','-n','control','-c',area])
env['TMUX']=f'{socket},0,0'
try:
 for mode in ['alias','physical','duplicate-local','duplicate-home','symlink-meta','hardlink-meta','dirty','unmerged']:
  d=area/mode; proj=d/'project'; home=d/'home'; state=d/'physical-state'
  for p in [proj,home/'data/task',home/'config',state]: p.mkdir(parents=True,exist_ok=True)
  if mode=='physical': (home/'state').mkdir()
  else: (home/'state').symlink_to('../physical-state')
  (proj/'treehouse.toml').write_text('max_trees = 1\nroot = "./"\n')
  (proj/'payload').write_text('saved project\n')
  run(['git','init','-q','-b','main'],proj); run(['git','add','.'],proj); run(['git','-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','initial'],proj)
  wt=pathlib.Path(run(['treehouse','get','--lease','--lease-holder','task'],proj).stdout.strip().splitlines()[-1])
  assert wt.is_relative_to(area),wt
  report=home/'data/task/report.md'; report.write_text('Completed investigation.\n')
  conversation=home/'data/task/conversation.jsonl'; conversation.write_text('{"role":"user","content":"saved conversation"}\n')
  saved=conversation.read_bytes()
  meta=state/'task.meta'
  kind='ship' if mode in ['dirty','unmerged'] else 'scout'
  meta.write_text(f'window=validation:fm-task\nendpoint_task_id=task\nbackend=tmux\nworktree={wt}\nproject={proj}\nkind={kind}\nmode=local-only\ndecisions_reviewed=1\ndecision_keys=\n')
  run(['tmux','new-window','-d','-t','validation','-n','fm-task','-c',area])
  if mode=='duplicate-local': (state/'other.meta').write_bytes(meta.read_bytes())
  if mode=='duplicate-home':
   other=d/'other-home'; (other/'state').mkdir(parents=True); (other/'data').mkdir()
   (other/'state/task.meta').write_bytes(meta.read_bytes())
   (home/'data/secondmates.md').write_text(f'- mate - fixture (home: {other}; scope: test; projects: project; added 2026-01-01)\n')
  if mode=='symlink-meta': meta.rename(d/'saved.meta'); meta.symlink_to('../saved.meta')
  if mode=='hardlink-meta': os.link(meta,state/'other.meta')
  if mode in ['dirty','unmerged']:
   (wt/'payload').write_text('unmerged precious work\n')
   if mode=='unmerged':
    run(['git','add','payload'],wt); run(['git','-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','unmerged'],wt)
  e=env|{'FM_HOME':str(home),'FM_STATE_OVERRIDE':str(state),'FM_ROOT_OVERRIDE':str(root)}
  if mode=='alias':
   p=run([area/'base/bin/fm-teardown.sh','task'],e=e,check=False)
   assert p.returncode and 'also task task' in p.stdout
   assert meta.exists(); run(['tmux','has-session','-t','validation:fm-task'])
   log.append('BASELINE: own task falsely reported as competing owner; tab and metadata preserved.\n')
  p=run([root/'bin/fm-teardown.sh','task'],e=e,check=False)
  if mode in ['alias','physical']:
   assert p.returncode==0,p.stdout
   assert not meta.exists()
   windows=run(['tmux','list-windows','-t','validation','-F','#{window_name}']).stdout
   assert 'fm-task' not in windows
   status=run(['treehouse','status'],proj).stdout
   assert 'leased' not in status.lower(),status
   log.append(f'{mode}: real task tab closed; task metadata removed; slot returned; report and conversation preserved.\n')
  else:
   assert p.returncode!=0,p.stdout
   assert meta.exists()
   windows=run(['tmux','list-windows','-t','validation','-F','#{window_name}']).stdout
   assert 'fm-task' in windows
   assert 'leased' in run(['treehouse','status'],proj).stdout.lower()
   if mode in ['dirty','unmerged']: assert (wt/'payload').read_text()=='unmerged precious work\n'
   log.append(f'{mode}: refused; real tab, metadata and leased worktree preserved.\n')
   run(['tmux','kill-window','-t','validation:fm-task'])
  assert report.exists() and conversation.read_bytes()==saved
  (ev/'live-cleanup.log').write_text('\n'.join(log))
finally:
 run(['tmux','-S',socket,'kill-server'],check=False)

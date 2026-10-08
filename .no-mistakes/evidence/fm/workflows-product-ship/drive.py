import os, pathlib, subprocess, json, hashlib, shutil
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/denni/.no-mistakes/evidence/01M4DQVPC3WMSW92N41XQY4YRJ')
home=root/'.validation/live-home'; project=root/'.validation/destination'; home.mkdir(); project.mkdir()
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('TASKS_AXI_'): env.pop(k)
env.update(HOME=str(root/'.validation/home'),FM_HOME=str(home),TMPDIR=str(root/'.validation/tmp'))
transcript=[]
def run(*args, expected=0):
    p=subprocess.run([str(root/'bin/fm-brief.sh'),*args],env=env,text=True,capture_output=True)
    transcript.append({'command':['bin/fm-brief.sh',*args],'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==expected, transcript[-1]
    return p
for mode in ['no-mistakes','direct-PR','local-only']:
    run('live-'+mode,str(project),'--mode',mode,'--herdr-lab')
run('live-scout',str(project),'--scout','--herdr-lab')
env['FM_SECONDMATE_CHARTER']='Synthetic isolated charter'
run('live-charter','--secondmate','--no-projects')
for p in sorted((home/'data').glob('*/brief.md')):
    shutil.copyfile(p,evidence/(p.parent.name+'-brief.md'))
# Follow the emitted interface, not an assumed source path.
text=(home/'data/live-local-only/brief.md').read_text()
line=next(l for l in text.splitlines() if 'read and follow `' in l and 'product-experience' in l)
pointer=pathlib.Path(line.split('`')[1]); body=pointer.read_text()
(evidence/'followed-skill.md').write_text('Resolved from live-local-only/brief.md: '+str(pointer)+'\n\n'+body)
assert pointer==root/'.agents/skills/product-experience/SKILL.md'
assert not (project/'.agents').exists()
assert 'product-experience' not in (home/'data/live-charter/brief.md').read_text()
# Tutorial first success, refusal, and recovery.
run('tutorial',str(project),expected=1)
assert not (home/'data/tutorial/brief.md').exists()
run('tutorial',str(project),'--mode','local-only')
p=home/'data/tutorial/brief.md'; before=p.read_bytes()
run('tutorial',str(project),'--mode','direct-PR',expected=1)
assert p.read_bytes()==before
run('tutorial-recovery',str(project),'--mode','local-only')
shutil.copyfile(p,evidence/'tutorial-brief.md')
(evidence/'live-cli-transcript.json').write_text(json.dumps({'revision':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'resolved_skill':str(pointer),'skill_sha256':hashlib.sha256(body.encode()).hexdigest(),'commands':transcript},indent=2)+'\n')
print('Live generation, emitted pointer read, role exclusion, missing-mode recovery, and overwrite preservation completed.')

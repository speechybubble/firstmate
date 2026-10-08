import os, pathlib, subprocess, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/denni/.no-mistakes/evidence/01M4DE0CN6Y4JTPBGQNXFJPMXM')
home=root/'.test-context/home'
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_'): del env[key]
env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root))
transcript=[]
for mode in ['no-mistakes','direct-PR','local-only','scout','secondmate']:
    args=[str(root/'bin/fm-brief.sh'),mode]
    if mode=='secondmate':
        args+=['--secondmate','--no-projects']
        env['FM_SECONDMATE_CHARTER']='Supervise only assigned tutorial work.'
    else:
        args+=['synthetic-tutorial']+(['--scout'] if mode=='scout' else ['--mode',mode])
    p=subprocess.run(args,env=env,text=True,capture_output=True)
    transcript.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==0,p.stderr
    path=home/'data'/mode/'brief.md'
    text=path.read_text()
    if mode!='secondmate':
        assert str(root/'.agents/skills/task-context/SKILL.md') in text
        text=text.replace('{TASK}','Prepare a corrected onboarding recommendation; preserve returning-user exceptions.').replace('{FIRSTMATE_SPEC}','Read only sources.md and current.json in the isolated fixture. Report a recommendation, not implementation. Do not revive the cancelled migration.')
        path.write_text(text)
        parser='source bin/fm-dod-lib.sh; fm_brief_task_content_valid "$1" && ! fm_brief_task_placeholders_present "$1"; fm_brief_task_heading_body "$1" "## Captain\x27s intent"'
        p=subprocess.run(['bash','-c',parser,'verify',str(path)],env=env,text=True,capture_output=True)
        assert p.returncode==0
        assert p.stdout.strip()=='Prepare a corrected onboarding recommendation; preserve returning-user exceptions.'
        transcript.append({'mode':mode,'extracted_intent':p.stdout})
    else:
        assert '# Task context and learning' not in text
        assert 'That file is your parent channel' in text
    (evidence/(mode+'-brief.md')).write_text(text)
# Existing brief must not be overwritten, even on another mode request.
path=home/'data/scout/brief.md'; before=path.read_bytes()
p=subprocess.run([str(root/'bin/fm-brief.sh'),'scout','synthetic-tutorial','--mode','local-only'],env=env,text=True,capture_output=True)
assert p.returncode!=0 and path.read_bytes()==before
transcript.append({'case':'reject overwrite','exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
(evidence/'cli-transcript.json').write_text(json.dumps(transcript,indent=2))
print('Generated every mode in isolated FM_HOME; extracted original intent; preserved secondmate channel; refused overwrite.')

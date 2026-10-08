import os, pathlib, subprocess, tempfile, shutil, re, json
repo = pathlib.Path.cwd()
proof = pathlib.Path('/home/denni/.no-mistakes/evidence/01M4DDZQ8SWVK6EK8PERYEZ132')
scratch = pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=repo/'.test-phase-scratch'))
records=[]
try:
    env=os.environ.copy()
    for key in ('FM_ROOT_OVERRIDE','FM_DATA_OVERRIDE','FM_STATE_OVERRIDE'):
        env.pop(key,None)
    env['TMPDIR']=str(scratch)
    env['HOME']=str(scratch/'operator-home')
    pathlib.Path(env['HOME']).mkdir()
    route_root=scratch/'tracked root with spaces'
    (route_root/'.agents/skills').mkdir(parents=True)
    (route_root/'.agents/skills/task-execution').symlink_to(repo/'.agents/skills/task-execution',target_is_directory=True)
    env['FM_ROOT_OVERRIDE']=str(route_root)
    def run(args):
        p=subprocess.run([str(repo/'bin/fm-brief.sh'),*args],env=env,text=True,capture_output=True)
        records.append({'command':['bin/fm-brief.sh',*args],'FM_HOME':env['FM_HOME'],'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
        return p
    for episode in ('first','reuse'):
        home=scratch/(episode+' home with spaces'); home.mkdir()
        env['FM_HOME']=str(home)
        out=proof/episode; out.mkdir(exist_ok=True)
        assert run(['--help']).returncode==0
        for mode in ('no-mistakes','direct-PR','local-only','scout'):
            args=[mode,'fixture']+(['--scout'] if mode=='scout' else ['--mode',mode])
            assert run(args).returncode==0
            brief=home/'data'/mode/'brief.md'; text=brief.read_text()
            route=re.search(r'read and follow `([^`]+/task-execution/SKILL.md)`',text).group(1)
            assert pathlib.Path(route).read_bytes()==(repo/'.agents/skills/task-execution/SKILL.md').read_bytes()
            for token in ('{TASK}','{FIRSTMATE_SPEC}',str(home/'state'/f'{mode}.status'),str(home/'state'/f'{mode}.inbox'),'# Herdr lifecycle declaration - NOT ENABLED'):
                assert token in text,token
            if mode=='scout':
                assert 'Delivery contract: mode=' not in text
                assert str(home/'data/scout/report.md') in text
            else:
                assert f'Delivery contract: mode={mode}' in text
            shutil.copyfile(brief,out/f'{mode}.md')
            before=brief.read_bytes()
            assert run(args).returncode!=0
            assert brief.read_bytes()==before
            records[-1]['persisted_result']='Existing brief unchanged byte-for-byte'
        for label,flags in [('unsupported',['--mode','unsupported']),('missing',[]),('conditional',['--mode','no-mistakes-prod-only']),('scout-mode',['--scout','--mode','direct-PR'])]:
            assert run([label,'fixture',*flags]).returncode!=0
            assert not (home/'data'/label/'brief.md').exists()
            records[-1]['persisted_result']='No brief artifact created'
        assert run(['mate','--secondmate','--no-projects']).returncode==0
        text=(home/'data/mate/brief.md').read_text()
        assert '# Task execution' not in text
        assert 'persistent second mate' in text
        shutil.copyfile(home/'data/mate/brief.md',out/'secondmate.md')
        records.append({'episode':episode,'result':'All emitted routes readable; mode, intent, status, inbox, report and safety contracts preserved; refusals leave no successful artifact'})
finally:
    shutil.rmtree(scratch)
    (proof/'cli-transcript.json').write_text(json.dumps(records,indent=2)+'\n')
assert all((proof/ep/name).is_file() for ep in ('first','reuse') for name in ('no-mistakes.md','direct-PR.md','local-only.md','scout.md','secondmate.md'))
(proof/'cleanup.txt').write_text('Both disposable episode homes removed. Generated CLI briefs and refusal transcript remain readable outside cleanup roots. No workers, backend sessions, or pipeline commands launched.\n')
print('Live CLI episodes completed; generated briefs and refusal diagnostics retained after cleanup.')

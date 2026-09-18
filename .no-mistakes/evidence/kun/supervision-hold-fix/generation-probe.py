import os,pathlib,subprocess,json
r=pathlib.Path.cwd();h=r/'.hold-validation-tmp/generation';(h/'state').mkdir(parents=True);(h/'data').mkdir();(h/'config').mkdir();(h/'.tasks.toml').write_bytes((r/'.tasks.toml').read_bytes());(h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n');(h/'state/.lock').write_text(str(os.getpid())+'\n');(h/'state/.wake-queue').write_text('1\t1\tsignal\tt1.turn-ended\tsignal: t1.turn-ended\n')
env={'PATH':'/home/denni/kun-validation/firstmate-hold-tools/node-v24.14.0-linux-x64/bin:'+os.environ['PATH'],'HOME':str(h),'FM_HOME':str(h),'FM_ROOT_OVERRIDE':str(r),'FM_GATE_REFUSE_BYPASS':'1','TMPDIR':str(r/'.hold-validation-tmp')}
def run(*args,want=0):
 p=subprocess.run([str(r/'bin/fm-wake-grant.sh'),*args],env=env,capture_output=True,text=True,timeout=40);print(json.dumps({'command':'fm-wake-grant.sh '+' '.join(args),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}));assert p.returncode==want
run('activate',str(os.getpid()),'old');run('activate',str(os.getpid()),'successor')
run('publish','old','--tasks','t1','--rows','1',want=1)
assert not (h/'state/.branch-eligible-rows').exists()
run('publish','successor','--tasks','t1','--rows','1')
run('deactivate',str(os.getpid()),'old',want=1)
assert (h/'state/.branch-eligible-rows').read_text()=='1\n'
assert (h/'state/.branch-eligible-owner').read_text().endswith('successor\n')
print('SUCCESSOR GRANT SURVIVES OLD-GENERATION PUBLICATION AND CLEANUP:',(h/'state/.branch-eligible-rows').read_text())
run('deactivate',str(os.getpid()),'successor')
assert not (h/'state/.branch-eligible-owner').exists()
print('CURRENT OWNER CLEANUP SUCCEEDS')

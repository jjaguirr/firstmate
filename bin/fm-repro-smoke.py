#!/usr/bin/env python3
"""Offline deterministic policy checks; opt-in live real fm-spawn smoke.
No credentials are copied. Live output is stochastic; only protocol is fixed.
"""
import argparse,json,os,pathlib,re,shlex,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
def validate_revision(value):
    if not re.fullmatch('[0-9a-f]{40}',value):
        raise ValueError('expected revision must be a full lowercase Git SHA')
    return value
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--expected-revision',required=True,type=validate_revision)
    parser.add_argument('--config',type=pathlib.Path,default=ROOT/'tests/fixtures/repro-smoke.json')
    parser.add_argument('--runtime-root',required=True,type=pathlib.Path)
    parser.add_argument('--live',action='store_true')
    args=parser.parse_args(); config=json.loads(args.config.read_text())
    args.runtime_root.mkdir(parents=True,exist_ok=True)
    receipt={'revision':args.expected_revision,'offline':'not-run','live':'not-requested','cleanup':False,'models':config['models']}
    env=os.environ.copy(); lab=None; tmux=None
    def run(cmd,timeout=30,cwd=ROOT):
        p=subprocess.run(cmd,cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
        if p.returncode: raise RuntimeError(p.stdout[-3000:])
        return p.stdout
    try:
        assert run(['git','rev-parse','HEAD']).strip()==args.expected_revision,'source revision mismatch'
        assert not run(['git','status','--porcelain','--untracked-files=no']).strip(),'tracked source dirty'
        for test in ['tests/fm-pi-no-tools.test.sh','tests/fm-codex-sandbox.test.sh']:
            run(['bash',test])
        receipt['offline']='pass'
        if args.live:
            missing=[t for t in config['tools'] if not shutil.which(t)]
            if missing: raise RuntimeError('missing tools: '+','.join(missing))
            assert run(['pi','--version']).strip()==config['pi_version'],'Pi version mismatch'
            # Readiness only: never print bearer tokens/API keys.
            run(['pi','auth','check','--provider','openai','--no-refresh'])
            lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-smoke-',dir=args.runtime_root))
            tmux=shutil.which('tmux'); socket=lab/'tmux.sock'; wrapper=lab/'tools'; wrapper.mkdir()
            (wrapper/'tmux').write_text('#!/bin/sh\nexec '+shlex.quote(tmux)+' -S '+shlex.quote(str(socket))+' "$@"\n')
            (wrapper/'tmux').chmod(0o700)
            env['PATH']=str(wrapper)+os.pathsep+env['PATH']; env.pop('TMUX',None)
            home=lab/'home'; project=lab/'project'
            for name in ['state','config','data/smoke','projects']: (home/name).mkdir(parents=True)
            env.update(FM_HOME=str(home),FM_PI_NO_TOOLS='1',FM_ROOT_OVERRIDE=str(ROOT),TREEHOUSE_ROOT=str(lab/'pool'))
            (home/'config/backend').write_text('tmux\n')
            (home/'data/smoke/brief.md').write_text('Smoke scout: no tools. Reply exactly FM_SCOUT_OK. Do not request tools, changes, publishing or credentials.\n')
            run(['git','init','-q',str(project)])
            (project/'fixture.txt').write_text('tiny deterministic smoke fixture\n')
            run(['git','add','fixture.txt'],cwd=project)
            run(['git','-c','user.name=Smoke','-c','user.email=smoke@invalid','commit','-qm','fixture'],cwd=project)
            run(['git','remote','add','origin',str(project)],cwd=project)
            def captain(prompt):
                return run(['pi','--print','--no-session','--no-tools','--no-mcp','--no-extensions','--no-skills','--no-context-files','--model',config['models']['captain'],'--thinking','minimal',prompt],timeout=config['timeout_seconds'],cwd=lab)
            assert 'FM_CAPTAIN_READY' in captain('Reply exactly FM_CAPTAIN_READY.'),'captain readiness assertion'
            run(['bash','bin/fm-spawn.sh','smoke',str(project),'--scout','--harness','pi','--model',config['models']['scout'],'--effort','low','--backend','tmux'],timeout=config['timeout_seconds'])
            receipt['dispatch']='real fm-spawn.sh'
            meta=(home/'state/smoke.meta').read_text()
            assert 'kind=scout' in meta and config['models']['scout'] in meta,'dispatch metadata assertion'
            deadline=time.monotonic()+config['timeout_seconds']; pane=''
            while time.monotonic()<deadline:
                pane=run(['tmux','capture-pane','-p','-t','firstmate:fm-smoke','-S','-300'])
                if (home/'state/smoke.turn-ended').exists() and 'FM_SCOUT_OK' in pane: break
                time.sleep(0.5)
            else: raise RuntimeError('scout did not finish: '+pane[-2000:])
            (home/'data/smoke/report.md').write_text('Observed FM_SCOUT_OK with turn-ended signal. Harness-owned report; no tool-enabled worker.\n')
            assert 'FM_CAPTAIN_DONE' in captain('The real Firstmate fm-spawn scout returned FM_SCOUT_OK and turn-ended. Reply exactly FM_CAPTAIN_DONE.'),'captain return assertion'
            receipt['live']='pass'
            receipt['scope']='script-driven Firstmate dispatch with Sol readiness/return; not autonomous Sol delegation'
    except Exception as error:
        receipt['error']=str(error)
        receipt['live']='blocked' if receipt['offline']=='pass' else 'not-run'
    finally:
        if tmux and lab:
            subprocess.run([tmux,'-S',str(lab/'tmux.sock'),'kill-server'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            check=subprocess.run([tmux,'-S',str(lab/'tmux.sock'),'list-sessions'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            receipt['private_tmux_stopped']=check.returncode!=0
        if lab: shutil.rmtree(lab)
        receipt['cleanup']=lab is None or not lab.exists()
        destination=args.runtime_root/'receipt.json'
        destination.write_text(json.dumps(receipt,indent=2)+'\n')
        print(json.dumps(receipt))
    return 0 if 'error' not in receipt else 2
if __name__=='__main__': raise SystemExit(main())

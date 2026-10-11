"""Supplied-force ranged combat: unchanged AI commands team 0; fixture owns team 1.

Each invocation allocates an immutable run identity. Economy is frozen only in
the staged scripts. --variant siege isolates the original two-list proposal;
--variant baseline takes a pinned pre-change --data/--dll pair.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from benchmark_store import RAW_ROOT
import storage
from air_arena import lua

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def pool_symbols(staged):
    """Compatibility hook for callers; shared staging owns symbol retention."""
    from symbol_store import stage_symbols
    path = staged / 'SkirmishAI.dbg'
    if path.exists():
        stage_symbols(path, path)


def prepare(args):
    case = json.loads(storage.resolve_definition(args.case, 'cases').read_text())
    role = case.get('role', 'FRONT')
    if role not in ('FRONT', 'TECH', 'AIR', 'SEA', 'SUPPORT', 'TACTICAL'): raise ValueError('Unsupported arena role: '+role)
    directory = storage.allocate('shared', 'combat', case.get('storage_scenario',case['name']), case['map_key'], 'supplied', seed=args.seed)
    starts = directory / 'starts.as'
    starts.write_text(''.join(f'StartSpot(AIFloat3({x},0,{z}), AiRole::{role}, false),\n' for x,z in case['starts']))
    command = [sys.executable, str(HERE / 'playtest.py')]
    stage = command + ['stage','--dir',str(directory),'--dll',str(args.dll),'--data',str(args.data),
        '--map',case['map'],'--map-file',str(starts),'--role',role,'--roles','all','--ally-spots','1',
        '--side',case.get('side','armada'),'--game',args.game,
        '--engine','recoil_2026.07.04','--speed',str(args.speed),'--minutes',str(args.minutes),
        '--shots','','--width','1280','--height','720','--lean-render','--bonus','0',
        '--ai-option','profile='+args.profile,'--ai-option','random_seed='+str(args.seed),
        '--modoption','deathmode=neverend','--modoption','startenergy='+str(case.get('start_energy',1000000)),
        '--modoption','startmetal='+str(case.get('start_metal',1000)),
        '--modoption','startmetalstorage='+str(case.get('start_metal',1000)),
        '--modoption','startenergystorage=1000000',
        '--extra-widget',str(HERE/'widgets/ranged_arena.lua'),
        '--extra-widget',str(HERE/'widgets/workforce_perf_watch.lua')]
    if args.headless: stage += ['--headless']
    subprocess.run(stage, check=True)
    script = directory/'script.txt'
    script.write_text(script.read_text().replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed='+str(args.seed)+';',1))
    staged = directory/'AI/Skirmish/BARbTest/test'
    pool_symbols(staged)
    setup=staged/'script/src/setup.as'
    setup.write_text(setup.read_text().replace('Global::AISettings::Role = derivedRole;',
        'derivedRole=AiRole::'+role+'; Global::AISettings::Role = derivedRole;'))
    for name,manager,wait in [('builder','aiBuilderMgr','TaskB::Wait(60*SECOND)'),('factory','aiFactoryMgr','TaskS::Wait(false,60*SECOND)')]:
        path = staged/'script/src/manager'/(name+'.as')
        source = path.read_text(); start = source.index('{',source.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))+1
        repair='\n if (ai.teamId==1 && !u.circuitDef.IsMobile()) return aiBuilderMgr.DefaultMakeTask(u);' if name=='builder' and case.get('enemy_repair') else ''
        if name=='builder' and case.get('friendly_repair'):
            repair+='\n if (ai.teamId==0 && !u.circuitDef.IsMobile()) return aiBuilderMgr.DefaultMakeTask(u);'
        condition = 'ai.teamId==1' if name=='factory' and case.get('production') else 'ai.frame>=0'
        if name=='builder' and case.get('builders'): condition = 'ai.teamId==1'
        if name=='builder' and case.get('production'):
            repair += '\n if (ai.teamId==0 && !u.circuitDef.IsMobile()) return aiBuilderMgr.DefaultMakeTask(u);'
        path.write_text(source[:start]+repair+'\n if ('+condition+') return '+manager+'.Enqueue('+wait+'); // supplied arena only\n'+source[start:])
    path = staged/'script/src/manager/military.as'
    source = path.read_text(); start = source.index('{',source.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))+1
    # Normal combat cases leave friendly commands to the AI. Production-only
    # cases can explicitly hold them to retain the supplied enemy demand.
    # The enemy follows a declared path or holds, with normal weapon firing.
    destination = case.get('enemy_destination')
    point = f'AIFloat3({destination[0]},0,{destination[1]})' if destination else 'u.GetPos(ai.frame)'
    if case.get('enemy_waypoints'):
        point = ','.join(f'AIFloat3({x},0,{z})' for x,z in case['enemy_waypoints'])
    override = '''
        if (ai.teamId==1 && u.circuitDef.IsMobile()) {
            CRouteTask@ route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            array<AIFloat3> points={'''+point+'''};
            route.SetTraversal(true,48,false); route.SetRoute(points); return route;
        } // enemy fixture only
'''
    if case.get('hold_friendly'):
        override += '''
        if (ai.teamId==0 && u.circuitDef.IsMobile()) {
            CRouteTask@ route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            array<AIFloat3> points={u.GetPos(ai.frame)};
            route.SetTraversal(true,48,false); route.SetRoute(points); return route;
        } // production-only fixture: retain army investment without clearing opponents
'''
    if case.get('native_route'):
        spec = case['native_route']
        points = ','.join(f'AIFloat3({x},0,{z})' for x,z in spec['points'])
        override += '''
        if (ai.teamId==0 && u.circuitDef.GetName()=="'''+case['unit']+'''") {
            if (FixtureRoute is null) {
                @FixtureRoute=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
                array<AIFloat3> points={'''+points+'''};
                FixtureRoute.SetLanes('''+str(spec['lanes'])+','+str(spec['spacing'])+''',1);
                FixtureRoute.SetTraversal(false,'''+str(spec['radius'])+''',false);
                FixtureRoute.SetRoute(points);
            }
            return FixtureRoute;
        } // supplied route: exercise ordinary spam's native arrival/idle path
'''
    patched = source[:start]+override+source[start:]
    if case.get('native_route'): patched = 'CRouteTask@ FixtureRoute;\n'+patched
    path.write_text(patched)
    if case.get('trace_spam'):
        # Supplied buildings did not come through TECH's reserved layout.
        # Its geometry/economy Tick cannot judge this isolated production
        # fixture. Lifecycle OnUnitAdded and Spam's own invariants stay active.
        path=staged/'script/src/systems/diagnostics/invariants.as'
        source=path.read_text(); start=source.index('{',source.index('void Tick()'))+1
        path.write_text(source[:start]+'\n if (ai.frame>=0) return; // supplied-layout fixture only\n'+source[start:])
        path=staged/'script/src/systems/combat/spam.as'
        source=path.read_text(); start=source.index('{',source.index('void Update()'))+1
        probe='''
        if (ai.teamId==0 && ai.frame % (10*SECOND)==0) {
            GenericHelpers::LogUtil("[SpamProbe] workers="+aiBuilderMgr.GetWorkerCount(),1);
            array<int>@ ids=ai.GetOwnedUnitIds();
            for (uint i=0;i<ids.length();++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(ids[i]);
                if (u is null || SpamUnitFor(u.circuitDef).length()==0) continue;
                GenericHelpers::LogUtil("[SpamProbe] factory="+u.id+" task="+(u.task is null ? -1 : int(u.task.GetType()))+" retiring="+Lifecycle::IsRetiring(u),1);
            }
        }
'''
        path.write_text(source[:start]+probe+source[start:])
    if args.variant=='siege':
        for path in (staged/'config').rglob('behaviour*.json'):
            data=path.read_bytes()
            for name in case.get('units',[case['unit']]):
                pattern=rb'("'+name.encode()+rb'"\s*:\s*\{)(.*?)(\n[ \t]*\},?)'
                match=re.search(pattern,data,re.S)
                if not match: continue
                block=re.sub(rb'("role"\s*:\s*)\[[^\]]*\]',rb'\1["artillery"]',match[2])
                if b'"attribute"' in block: block=re.sub(rb'("attribute"\s*:\s*)\[[^\]]*\]',rb'\1["siege"]',block)
                else: block=re.sub(rb'("role"[^\n]*\n)',rb'\1\t\t\t\t"attribute": ["siege"],\n',block)
                data=data[:match.start(2)]+block+data[match.end(2):]
            path.write_bytes(data)
    case.update(variant=args.variant,profile=args.profile,seed=args.seed,minutes=args.minutes,speed=args.speed,headless=args.headless)
    config=directory/'LuaUI/Config';config.mkdir(parents=True,exist_ok=True)
    (config/'ranged_arena.lua').write_text('return '+lua(case)+'\n')
    (directory/'ranged-arena.json').write_text(json.dumps(case,indent=2)+'\n')
    pins={'dll_sha256':hashlib.sha256(args.dll.read_bytes()).hexdigest(),
          'diagnostics':{name:os.environ[name] for name in
              ('CIRCUIT_RANGED_TRACE','CIRCUIT_VERIFY_RANGED_QUERIES','CIRCUIT_VERIFY_RANGED_SNAPSHOT','CIRCUIT_PERF_PHASES')
              if name in os.environ},
          'files':{str(p.relative_to(staged)):storage.file_hash(p) for p in staged.rglob('*') if p.is_file() and p.suffix in ('.as','.json')},
          'observer_sha256':storage.file_hash(HERE/'widgets/ranged_arena.lua'),
          'overrides':['supplied forces','fixed seed','startup energy'] +
              ((['enemy factories and mobile builders frozen','scripted enemy path'] if case.get('production')
                else ['frozen economic builders/factories','scripted enemy path'])
               if args.profile.startswith('experimental_') else ['native legacy economy remains active'])}
    if case.get('production'):
        pins['overrides'] += ['team 0 factories and static assistants active; mobile builders '+('active' if case.get('builders') else 'frozen')]
    if case.get('trace_spam'):
        pins['overrides'] += ['TECH layout/economy invariant Tick disabled for supplied buildings; production/lifecycle and spam invariants retained', 'read-only factory task census every 10 seconds']
    if case.get('hold_friendly'):
        pins['overrides'] += ['friendly combat held for production measurement']
    if case.get('native_route'):
        pins['overrides'] += ['friendly ordinary native route and lane geometry supplied; arrival/idle mechanism test']
    (directory/'ranged-arena-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
    subprocess.run([sys.executable,str(ROOT/'tools/knowledge/check_script_api.py'),'--dll',str(args.dll),'--scripts',str(staged/'script')],check=True)
    print('RANGED_ARENA='+str(directory),flush=True)
    return directory, command


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case',required=True)
    parser.add_argument('--dll',required=True,type=Path)
    parser.add_argument('--data',type=Path,default=ROOT/'data')
    parser.add_argument('--variant',choices=['baseline','siege','ranged'],default='ranged')
    parser.add_argument('--profile',default='experimental_balanced')
    parser.add_argument('--game',default='Beyond All Reason test-31479-433a460')
    parser.add_argument('--seed',type=int,default=2071)
    parser.add_argument('--minutes',type=int,default=4)
    parser.add_argument('--speed',type=int,default=8)
    parser.add_argument('--headless',action='store_true')
    parser.add_argument('--stage-only',action='store_true')
    args=parser.parse_args();directory,command=prepare(args)
    if args.stage_only: return 0
    launch=command+['launch','--dir',str(directory),'--engine','recoil_2026.07.04']
    if args.headless: launch+=['--headless']
    subprocess.run(launch,check=True)
    case=json.loads((directory/'ranged-arena.json').read_text())
    watch=command+['watch','--dir',str(directory),'--role',case.get('role','FRONT'),'--checks',case.get('checks','ranged-arena'),
        '--minutes',str(args.minutes),'--wall-minutes','8']
    if args.variant=='baseline': watch+=['--keep-going']
    return subprocess.run(watch,check=False).returncode

if __name__=='__main__':sys.exit(main())

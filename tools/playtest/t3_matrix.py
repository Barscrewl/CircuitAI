"""D-294 commander-versus-T3 matrix: one T3 walks through a defence line.

Generates one supplied-arena case per (T3, defence) under
cases/shared/combat/t3/, runs them through ranged_arena.py from the most
expensive T3 down, and scores every run from its infolog: whether the T3 died,
whether the D-gun landed the killing blow, D-gun hits, commander survival and
lowest health, and time to kill. Results go to the benchmark checkout.

  python tools/playtest/t3_matrix.py --dll <pin>/SkirmishAI.dll --data <pin>/data \
      [--units corkorg,corjugg] [--lines l,h,w,n] [--speed 4] [--headless]
"""
import argparse
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CASES = HERE / 'cases/shared/combat/t3'
CHECKS = HERE / 'checks/shared/combat'

# Mobile ground T3 attackers that are buildable (reachable) outside Scavengers,
# most expensive first (rjm.bar.docs unit cache, metal cost).
T3 = [('corkorg', 29000), ('legeheatraymech', 23500), ('corjugg', 20000), ('armbanth', 13500),
      ('legelrpcmech', 11000), ('armthor', 9000), ('legeshotgunmech', 7000), ('legerailtank', 6500),
      ('cordemon', 6000), ('corcat', 4900), ('legeallterrainmech', 3950), ('armraz', 3800),
      ('armvang', 3300), ('legkeres', 2600), ('corkarg', 2500), ('legbunk', 1850), ('corshiva', 1600),
      ('legehovertank', 1350), ('legjav', 1200), ('armlun', 1150), ('armmar', 970), ('corsok', 950)]
# Not player-buildable in a standard game, but the most expensive T3 defs the
# game loads: Scavenger units and the retired Thermite. coresuppt3 is a ship
# (sea layout only). Spawned by cheat like the rest.
EXTRA = [('corves', 30000), ('coresuppt3', 30000), ('legeheatraymech_old', 27000), ('legapollyon', 15000)]
NAVAL = {'coresuppt3'}
SCAV = {'corves', 'coresuppt3', 'legapollyon'}

EYES = [(4000, 5500, 'armeyes'), (4000, 5950, 'armeyes')]
# Artillery (max range from the unit pages) shells the line from outside turret
# reach: the commander must hunt it.
SIEGE = {'corcat': 1350, 'legeallterrainmech': 1380, 'armvang': 1450, 'legelrpcmech': 3100}
LINES = {
    'l': [(3760, 4900, 'armllt'), (3880, 4900, 'armllt'), (4120, 4900, 'armllt'), (4240, 4900, 'armllt'),
          (3820, 4840, 'armhlt'), (4180, 4840, 'armhlt')],
    'h': [(3780, 4900, 'armhlt'), (4220, 4900, 'armhlt'), (3880, 4860, 'armpb'), (4120, 4860, 'armpb'),
          (4000, 4800, 'armguard')],
    'w': [(3760, 4900, 'armllt'), (3880, 4900, 'armllt'), (4120, 4900, 'armllt'), (4240, 4900, 'armllt'),
          (3820, 4840, 'armhlt'), (4180, 4840, 'armhlt')]
         + [(x, 5000, 'armdrag') for x in range(3720, 4300, 48)],
    'n': [],
}
LINE_NAMES = {'l': 'light', 'h': 'heavy', 'w': 'walled', 'n': 'none', 's': 'shore'}


def case_for(unit, line):
    if line == 's':
        return shore_case(unit)
    groups = [{'unit': 'armcom', 'team': 0, 'count': 1, 'position': [4000, 4760], 'after_seconds': 12}]
    groups += [{'unit': u, 'team': 0, 'count': 1, 'position': [x, z], 'after_seconds': 12} for x, z, u in LINES[line] + EYES]
    groups += [{'unit': 'armnanotc', 'team': 0, 'count': 1, 'position': [x, 4560], 'after_seconds': 12} for x in (3880, 4120)]
    # Artillery shells the line from (4900,5600): ~1,140 from the line (inside
    # every listed artillery range, outside turret reach) and ~1,000 from the
    # opposing start commander's 700 radar at (4000,6140) on this map.
    siege = unit in SIEGE
    dest, spawn = ([4900, 5600], [5200, 6100]) if siege else ([4000, 4300], [4000, 6300])
    groups.append({'unit': unit, 'team': 1, 'count': 1, 'position': spawn, 'after_seconds': 25})
    if siege:
        # Spotting both ways: the enemy camera (outside turret reach) lets the
        # artillery shell the line; ours lets the commander see what to hunt.
        groups.append({'unit': 'armeyes', 'team': 1, 'count': 1, 'position': [4600, 5250], 'after_seconds': 20})
        groups.append({'unit': 'armeyes', 'team': 0, 'count': 1, 'position': [4650, 5450], 'after_seconds': 12})
    name = f't3-{unit}-{line}'
    assert len(name) <= 24, name
    return name, {
        'name': name, 'unit': 'armcom', 'side': 'armada', 'role': 'FRONT',
        'description': f'D-294 matrix: one {unit} walks through a {LINE_NAMES[line]} defence line at an Armada commander.',
        'map': 'Comet Catcher Remake 1.8', 'map_key': 'comet', 'starts': [[4000, 4000], [4000, 7000]],
        'camera': [4000, 5150, 1900], 'photos': [40, 70, 100, 130], 'min_spawn_spacing': 38,
        'command_breakdown': True, 'commander_observation': True, 'friendly_repair': True,
        'enemy_destination': dest, 'groups': groups, 'enemy_commander_home': True,
        'assertions': {'min_shooters': 0, 'min_kills': 0, 'max_losses': 40, 'min_damage': 0},
        'checks': 'commander-t3-duel'}


def shore_case(unit):
    return sea_case(unit) if unit in NAVAL else _shore(unit)


def _shore(unit):
    """Supreme Isthmus z=6200: the T3 wades ~2,500 elmos of water (depth 27-75)
    and climbs out at x~6900 onto the commander's shore line (probe-supreme)."""
    # A shore line needs sonar: without it an amphibious T3 is invisible
    # until it surfaces (b43: a submerged Juggernaut lasered the commander blind).
    line = [(6650, 6080, 'armllt'), (6650, 6320, 'armllt'), (6600, 6200, 'armhlt'), (6500, 6040, 'armeyes'), (6500, 6360, 'armeyes'),
            (7250, 5900, 'armsonar')]
    groups = [{'unit': 'armcom', 'team': 0, 'count': 1, 'position': [6450, 6200], 'after_seconds': 12}]
    groups += [{'unit': u, 'team': 0, 'count': 1, 'position': [x, z], 'after_seconds': 12} for x, z, u in line]
    groups += [{'unit': 'armnanotc', 'team': 0, 'count': 1, 'position': [6300, z], 'after_seconds': 12} for z in (6100, 6300)]
    groups.append({'unit': unit, 'team': 1, 'count': 1, 'position': [10600, 6200], 'after_seconds': 25})
    name = f't3-{unit}-s'
    return name, {
        'name': name, 'unit': 'armcom', 'side': 'armada', 'role': 'FRONT',
        'description': f'D-294 matrix: one {unit} crosses water and lands on a shore line held by an Armada commander. The D-gun cannot hit it submerged.',
        'map': 'Supreme Isthmus v1.7', 'map_key': 'supreme', 'starts': [[4800, 8200], [7500, 4000]],
        'camera': [7300, 6200, 2400], 'photos': [40, 80, 120, 160], 'min_spawn_spacing': 38,
        'command_breakdown': True, 'commander_observation': True, 'friendly_repair': True,
        'enemy_destination': [6200, 6200], 'groups': groups, 'enemy_commander_home': True,
        'assertions': {'min_shooters': 0, 'min_kills': 0, 'max_losses': 40, 'min_damage': 0},
        'checks': 'commander-t3-duel'}


def sea_case(unit):
    """Supreme Isthmus z=6200: a ship sails in from open water (x~8600) to the
    shallows off the commander's shore line (x~7150); it never lands."""
    name, case = _shore(unit)
    case['groups'][-1]['position'] = [8600, 6200]
    # Spotting at the water's edge: ships stop beyond the line's own sight.
    case['groups'].insert(1, {'unit': 'armeyes', 'team': 0, 'count': 1, 'position': [6850, 6200], 'after_seconds': 12})
    case['enemy_destination'] = [7150, 6200]
    case['description'] = f'D-294 matrix: one {unit} ship sails to the shallows off a shore line held by an Armada commander.'
    return name, case


CHECK = {'stop_minute': 5, 'expect': [
    {'key': 'loaded', 'pattern': '\\[RangedArena\\].* loaded', 'scope': 'any', 'by_minute': 1},
    {'key': 'plan', 'pattern': '\\[CommanderT3\\] unit=\\d+ target=\\d+ def=\\w+ plan', 'scope': 'any', 'by_minute': 4},
    {'key': 'dead_t3', 'pattern': '\\[RangedArena\\].* death id=\\d+ team=1 unit=', 'scope': 'any', 'by_minute': 5}],
    'forbid': [
    {'key': 'script', 'pattern': ': ERR\\s+:|SCRIPT CRASH|Lib exception', 'scope': 'any'},
    {'key': 'invariant', 'pattern': '\\[INVARIANT\\]', 'scope': 'any'},
    {'key': 'fixture', 'pattern': '\\[RangedArena\\].*ERROR|Error in.*ranged_arena', 'scope': 'any'},
    {'key': 'crash', 'pattern': 'Access violation|has crashed|Fatal:', 'scope': 'any'}]}

FRAME = re.compile(r'\[f=(-?\d+)\]')


def score(infolog):
    """Score one run. The front commander is the one the fixture spawned."""
    res = {'t3': None, 'spawn': None, 'death': None, 'dgun_hits': 0, 'other_damage': 0, 'killing_weapon': None,
           'commander': None, 'commander_dead': None, 'commander_min_hp': None, 'plan': None, 'fallback': 0}
    for line in open(infolog, encoding='utf-8', errors='replace'):
        m = FRAME.search(line)
        f = int(m[1]) if m else -1
        if (s := re.search(r'spawn id=(\d+) team=0 unit=armcom ', line)) and res['commander'] is None:
            res['commander'] = s[1]
        elif s := re.search(r'spawn id=(\d+) team=1 unit=(\w+)', line):
            res['t3'], res['spawn'], res['unit'] = s[1], f, s[2]
        elif (d := re.search(r'damage id=(\d+) team=1 amount=(-?\d+) attacker=(\d+) attackerTeam=0 .*weaponName=(\S+)', line)) and d[1] == res['t3']:
            # Credit only the commander under test: the base start commander
            # can also D-gun a T3 that walks into the base.
            own = 'disintegrator' in d[4] and d[3] == res['commander']
            if own:
                res['dgun_hits'] += 1
            else:
                res['other_damage'] += max(0, int(d[2]))
            res['killing_weapon'] = d[4] if own or 'disintegrator' not in d[4] else 'other_commander_dgun'
        elif d := re.search(r'death id=(\d+) team=(\d)', line):
            if d[1] == res['t3']:
                res['death'] = f
            elif d[1] == res['commander']:
                res['commander_dead'] = f
        elif res['commander'] and (c := re.search(r'commander id=' + res['commander'] + r' .* hp=(\d+) cloaked=', line)):
            hp = int(c[1])
            res['commander_min_hp'] = hp if res['commander_min_hp'] is None else min(res['commander_min_hp'], hp)
        elif p := re.search(r'\[CommanderT3\] unit=(\d+) .*def=\w+ plan (.*)', line):
            if p[1] == res['commander'] and res['plan'] is None:
                res['plan'] = p[2].strip()
        elif res['commander'] and re.search(r'\[CommanderFallback\] unit=' + res['commander'] + ' on', line):
            res['fallback'] += 1
    res['dgun_kill'] = bool(res['death'] and res['killing_weapon'] and 'disintegrator' in res['killing_weapon'])
    res['survived'] = res['commander_dead'] is None
    res['seconds_to_kill'] = round((res['death'] - res['spawn']) / 30, 1) if res['death'] and res['spawn'] else None
    # DGUN: the D-gun landed the killing blow. LINE: the defence killed it
    # first (cheap/fast T3) with the commander alive and on the line.
    res['outcome'] = ('DGUN' if res['dgun_kill'] else 'LINE') if res['death'] and res['survived'] else 'FAIL'
    res['pass'] = res['outcome'] != 'FAIL'
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--dll', required=True)
    ap.add_argument('--data', required=True)
    ap.add_argument('--units', default=','.join(u for u, _ in T3))
    ap.add_argument('--lines', default='l')
    ap.add_argument('--speed', type=int, default=4)
    ap.add_argument('--minutes', type=int, default=5)
    ap.add_argument('--headless', action='store_true')
    ap.add_argument('--out', required=True, help='results JSON (benchmark checkout)')
    args = ap.parse_args()
    CASES.mkdir(parents=True, exist_ok=True)
    (CHECKS / 'commander-t3-duel.json').write_text(json.dumps(CHECK, indent=2) + '\n', newline='\n')
    order = {u: c for u, c in T3 + EXTRA}
    units = sorted(args.units.split(','), key=lambda u: -order.get(u, 0))
    results = []
    out = Path(args.out)
    for unit in units:
        for line in args.lines.split(','):
            name, case = case_for(unit, line)
            if unit in SCAV:
                case['modoptions'] = {'scavunitsforplayers': 1}  # load Scavenger unit defs
            (CASES / f'{name}.json').write_text(json.dumps(case, indent=2) + '\n', newline='\n')
            command = [sys.executable, str(HERE / 'ranged_arena.py'), '--case', name, '--dll', args.dll,
                       '--data', args.data, '--minutes', str(args.minutes), '--speed', str(args.speed)]
            if args.headless:
                command.append('--headless')
            run = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace')
            report = re.search(r'\[playtest\] report: (.*report\.md)', run.stdout)
            row = {'unit': unit, 'cost': order.get(unit), 'line': LINE_NAMES[line], 'case': name,
                   'report': report[1].strip() if report else None}
            if report:
                infolog = Path(report[1].strip()).parent / 'infolog.txt'
                if infolog.exists():
                    row.update(score(infolog))
            row['verdict'] = row.get('outcome', 'FAIL')
            results.append(row)
            print(f"{unit:<20} {row['line']:<7} {row['verdict']}  dgun_kill={row.get('dgun_kill')} hits={row.get('dgun_hits')} "
                  f"survived={row.get('survived')} min_hp={row.get('commander_min_hp')} t={row.get('seconds_to_kill')} "
                  f"fallback={row.get('fallback')} plan={row.get('plan')}", flush=True)
            out.write_text(json.dumps({'generated': datetime.datetime.utcnow().isoformat() + 'Z', 'dll': args.dll,
                                       'results': results}, indent=2) + '\n')
    return 0 if all(r['verdict'] != 'FAIL' for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())

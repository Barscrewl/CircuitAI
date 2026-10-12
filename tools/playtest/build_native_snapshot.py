"""Build a pinned BARb source snapshot against an existing read-only Recoil wrapper.

Writes only a new benchmark validation directory. Does not configure or build
inside the reference engine checkout and does not deploy to a game install.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

from benchmark_store import VALIDATION_ROOT, require_checkout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    require_checkout()
    repo = Path(__file__).resolve().parents[2]
    engine = repo.parent / 'bar-RecoilEngine'
    reference = engine / 'build-amd64-windows'
    destination = (VALIDATION_ROOT / args.session).resolve()
    if not destination.is_relative_to(VALIDATION_ROOT.resolve()) or destination == VALIDATION_ROOT.resolve():
        raise ValueError('Build destination must be a named validation subdirectory')
    destination.mkdir(parents=True, exist_ok=False)
    source = destination / 'source'
    for name in ('src', 'data'):
        shutil.copytree(repo / name, source / name)
    for name in ('CMakeLists.txt', 'VERSION'):
        shutil.copy2(repo / name, source / name)
    ninja = (reference / 'build.ninja').read_text()
    blocks = re.findall(r'^build ([^\n]+): CXX_COMPILER__BARb_unscanned_RELWITHDEBINFO ([^\n]+)\n((?:  [^\n]*\n)+)', ninja, re.M)
    if not blocks:
        raise ValueError('No BARb compilation rules in the reference build')
    output = [
        'rule cxx',
        '  command = /usr/bin/x86_64-w64-mingw32-g++-posix $DEFINES $INCLUDES $FLAGS -MD -MF $out.d -o $out -c $in',
        '  depfile = $out.d', '  deps = gcc',
        'rule link',
        '  command = /usr/bin/x86_64-w64-mingw32-g++-posix $FLAGS -shared -o $out $in $LIBRARIES',
        'rule symbols',
        '  command = x86_64-w64-mingw32-objcopy --only-keep-debug SkirmishAI.full.dll SkirmishAI.dbg && x86_64-w64-mingw32-strip --strip-debug --strip-unneeded -o SkirmishAI.dll SkirmishAI.full.dll && x86_64-w64-mingw32-objcopy --add-gnu-debuglink=SkirmishAI.dbg SkirmishAI.dll',
    ]
    objects = []
    for object_path, inputs, variables in blocks:
        source_path = inputs.split(' || ')[0]
        local = f'objects/{len(objects):03d}.obj'
        objects.append(local)
        output.append(f'build {local}: cxx {source_path}')
        for key in ('DEFINES', 'INCLUDES', 'FLAGS'):
            match = re.search(r'^  ' + key + r' = (.*)$', variables, re.M)
            if match is None:
                raise ValueError(f'Missing {key}: {object_path}')
            output.append(f'  {key} = {match[1]}')
    link = re.search(r'^build AI/Skirmish/BARb/data/SkirmishAI.dll: [^\n]+\n((?:  [^\n]*\n)+)', ninja, re.M)[1]
    flags = re.search(r'^  LINK_FLAGS = (.*)$', link, re.M)[1]
    libraries = re.search(r'^  LINK_LIBRARIES = (.*)$', link, re.M)[1]
    libraries = libraries.replace('AI/Wrappers/', '/build/out/AI/Wrappers/')
    output += [f'build SkirmishAI.full.dll: link {" ".join(objects)}',
               f'  FLAGS = {flags}', f'  LIBRARIES = {libraries}',
               'build SkirmishAI.dll SkirmishAI.dbg: symbols SkirmishAI.full.dll',
               'default SkirmishAI.dll']
    (destination / 'objects').mkdir()
    (destination / 'build.ninja').write_text('\n'.join(output) + '\n')
    image = 'ghcr.io/beyond-all-reason/recoil-build-amd64-windows:latest'
    command = ['docker', 'run', '--rm', '-v', f'{engine.as_posix()}:/build/src:ro',
               '-v', f'{source.as_posix()}:/build/src/AI/Skirmish/BARb:ro',
               '-v', f'{reference.as_posix()}:/build/out:ro',
               '-v', f'{destination.as_posix()}:/work', '-w', '/work',
               '--entrypoint', 'ninja', image, '-j', str(max(1, args.jobs))]
    print('BUILD_DIRECTORY=' + str(destination), flush=True)
    with (destination / 'build.log').open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    metadata = {'command': command, 'exit_code': result.returncode, 'objects': len(objects),
                'reference_ninja_sha256': hashlib.sha256(ninja.encode()).hexdigest()}
    if result.returncode == 0:
        metadata['sha256'] = {name: hashlib.sha256((destination / name).read_bytes()).hexdigest()
                              for name in ('SkirmishAI.dll', 'SkirmishAI.dbg')}
        shutil.copytree(source / 'data', destination / 'data')
    (destination / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(metadata), flush=True)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())

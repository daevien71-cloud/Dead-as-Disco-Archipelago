"""Bundle the disabled reviewed Lua components into one isolated check-only stage."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'staging/runtime-adapter'
HOOK = '/Game/Pagoda/Core/GameModes/InfiniteDisco/BP_PagodaGameState_InfiniteDisco.BP_PagodaGameState_InfiniteDisco_C:AdvanceRound'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_workspace(path):
    path = path.absolute()
    if not path.resolve().is_relative_to(ROOT) or path.resolve() != path:
        raise ValueError('Path must be ordinary and remain inside this workspace')
    for part in (path, *path.parents):
        if part.exists() and (part.is_symlink() or part.is_junction()):
            raise ValueError('Reparse paths are not allowed')
    return path


def prepare(session, bridge, identity):
    session = safe_workspace(session)
    bridge = safe_workspace(bridge)
    if not session.is_relative_to(ROOT / 'runtime'):
        raise ValueError('Stage must be inside workspace runtime')
    if bridge.name != 'bridge' or not isinstance(identity['seed_name'], str) or not identity['seed_name'].isascii():
        raise ValueError('Use this proof state bridge directory and an ASCII seed name')
    for key in ('team', 'slot'):
        if type(identity[key]) is not int or identity[key] < 0:
            raise ValueError('Team/slot must be nonnegative integer IDs')
    key = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if bridge.parent.name != key:
        raise ValueError('Bridge path does not match the seed/team/slot fingerprint')
    dependency = SOURCE / 'deps/json.lua'
    if sha(dependency) != '0eaccda57fabc0330736de25f45cf589821a42b5e0fe02e4e3125f7dc0bf2b7e':
        raise ValueError('Pinned official JSON library changed')
    components = [dependency, SOURCE / 'first_wave.lua', SOURCE / 'bridge-wrapper.lua']
    texts = [p.read_text(encoding='utf-8') for p in components]
    install_id = uuid.uuid4().hex
    config = {'bridge_dir':bridge.as_posix(), 'identity':identity, 'install_id':install_id}
    # All supplied strings are ASCII; JSON string escaping is also valid here.
    config_lua = '{bridge_dir=' + json.dumps(config['bridge_dir']) + ',identity={seed_name=' + json.dumps(identity['seed_name']) + ',team=' + str(identity['team']) + ',slot=' + str(identity['slot']) + '},install_id=' + json.dumps(install_id) + '}'
    wrapper = texts[2]
    for old, new in [('local ENABLE_CHECKS = false', 'local ENABLE_CHECKS = true'),
                     ('local CONFIG = nil', 'local CONFIG = ' + config_lua)]:
        if wrapper.count(old) != 1:
            raise ValueError('Disabled wrapper source marker changed')
        wrapper = wrapper.replace(old, new, 1)
    bundle = 'local json = (function()\n' + texts[0] + '\nend)()\nlocal FirstWave = (function()\n' + texts[1] + '\nend)()\n' + wrapper
    subprocess.run([sys.executable, str(ROOT / 'scripts/prepare_metadata_runtime.py'),
                    '--session-directory', str(session), '--wave-observer'], check=True, capture_output=True)
    destination = session / 'staging/ue4ss/Mods/DADAPProbe/Scripts/main.lua'
    destination.write_text(bundle, encoding='utf-8', newline='\n')
    luac = ROOT / 'staging/metadata-probe/syntax-check/build/luac.exe'
    syntax = subprocess.run([str(luac), '-p', str(destination)], capture_output=True, text=True)
    if syntax.returncode:
        raise ValueError('Derived check adapter failed Lua syntax: ' + syntax.stderr)
    plan_path = session / 'install-plan.json'
    plan = json.loads(plan_path.read_text())
    plan.update(purpose='Experimental calibrated first-wave check only; no ability mutation',
                wave_observer=False, session_nonce=None, checks_only=True, unlock_application_enabled=False,
                owner_calibration_profile='owner_requested_arcade_20261011',
                install_id=install_id, identity=identity, bridge_directory=str(bridge),
                adapter_build='dad-first-wave-check-v1-' + install_id,
                adapter_sha256=sha(destination), hook_path=HOOK,
                source_components=[{'path':str(p), 'sha256':sha(p)} for p in components],
                syntax={'command':[str(luac), '-p', str(destination)], 'exit_code':0,
                        'script_executed':False})
    for entry in plan['entries']:
        target = Path(plan['staging_root']) / entry['relative_path']
        entry.update(bytes=target.stat().st_size, sha256=sha(target))
    plan_path.write_text(json.dumps(plan, indent=2), encoding='utf-8')
    return {'plan':str(plan_path), 'adapter_build':plan['adapter_build'],
            'adapter_sha256':plan['adapter_sha256'], 'install_id':install_id,
            'bridge_directory':str(bridge), 'live_writes':False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session-directory', type=Path, required=True)
    parser.add_argument('--bridge-directory', type=Path, required=True)
    parser.add_argument('--seed-name', required=True)
    parser.add_argument('--team', type=int, default=0)
    parser.add_argument('--slot', type=int, default=1)
    parser.add_argument('--accept-owner-calibration', action='store_true', required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.session_directory, args.bridge_directory,
                            dict(seed_name=args.seed_name, team=args.team, slot=args.slot)), indent=2))

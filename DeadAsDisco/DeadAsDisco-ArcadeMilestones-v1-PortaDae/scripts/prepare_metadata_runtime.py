"""Stage the official loader plus bounded observer/metadata Lua; no live writes."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'staging/ue4ss/UE4SS_v3.0.1-1164-g5e627997.zip'
EXPECTED = '3c72142a383e25e9f9553ac9e4d5677aa572e98cb369cac57200efb2e381e603'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--session-directory', type=Path, required=True)
    parser.add_argument('--include-optional', action='store_true')
    parser.add_argument('--include-gas', action='store_true')
    parser.add_argument('--wave-observer', action='store_true')
    args = parser.parse_args()
    if args.wave_observer and (args.include_optional or args.include_gas):
        parser.error('Wave observation is an isolated probe; metadata options are not allowed')
    session = args.session_directory.resolve()
    if not session.is_relative_to(ROOT / 'runtime'):
        raise RuntimeError('Session must be under this workspace runtime directory')
    target = session / 'staging'
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != EXPECTED:
        raise RuntimeError('Official loader archive hash mismatch')
    target.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(ARCHIVE) as archive:
        for name in ('dwmapi.dll', 'ue4ss/UE4SS.dll', 'ue4ss/LICENSE', 'ue4ss/UE4SS-settings.ini'):
            path = target / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(archive.read(name))
    settings = target / 'ue4ss/UE4SS-settings.ini'
    text = settings.read_text(encoding='utf-8-sig')
    overrides = {'EnableHotReloadSystem':'0', 'EnableAutoReloadingLuaMods':'0',
                 'ConsoleEnabled':'0', 'GuiConsoleEnabled':'0', 'GuiConsoleVisible':'0',
                 'LoadAllAssetsBeforeDumpingObjects':'0', 'LoadAllAssetsBeforeGeneratingCXXHeaders':'0',
                 'SecondsToScanBeforeGivingUp':'30', 'SigScannerNumThreads':'2',
                 'EnableDumping':'0', 'FullMemoryDump':'0'}
    for key, value in overrides.items():
        text, count = re.subn(rf'(?m)^{re.escape(key)}\s*=.*$', f'{key} = {value}', text)
        if count != 1:
            raise RuntimeError(f'Unexpected settings field {key}: {count}')
    settings.write_text(text, encoding='utf-8', newline='\n')
    sources = {
        'DADAPProbe': ROOT / 'evidence/hooks/ue4ss-probe/Mods/DADAPProbe/Scripts/main.lua',
        'DADAPMetadata': ROOT / 'staging/metadata-probe/Mods/DADAPMetadata/Scripts/main.lua',
    }
    if args.include_gas:
        sources['DADAPGASMetadata'] = ROOT / 'staging/gas-metadata-probe/Mods/DADAPGASMetadata/Scripts/main.lua'
    nonce = None
    if args.wave_observer:
        sources = {'DADAPProbe': ROOT / 'staging/wave-observer/Mods/DADAPProbe/Scripts/main.lua'}
        nonce = uuid.uuid4().hex
    for mod, source in sources.items():
        text = source.read_text(encoding='utf-8')
        switch = 'ENABLE_PROBE' if mod == 'DADAPProbe' else 'ENABLE_METADATA'
        old = f'local {switch} = false'
        if text.count(old) != 1:
            raise RuntimeError('Unexpected disabled probe source')
        text = text.replace(old, f'local {switch} = true', 1)
        if args.wave_observer:
            old = 'local SESSION_NONCE = ""'
            if text.count(old) != 1:
                raise RuntimeError('Unexpected nonce field')
            text = text.replace(old, f'local SESSION_NONCE = "{nonce}"', 1)
        if mod == 'DADAPMetadata' and args.include_optional:
            old = 'local ENABLE_OPTIONAL_ABILITY_METADATA = false'
            if text.count(old) != 1:
                raise RuntimeError('Unexpected optional probe source')
            text = text.replace(old, 'local ENABLE_OPTIONAL_ABILITY_METADATA = true', 1)
        destination = target / f'ue4ss/Mods/{mod}/Scripts/main.lua'
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text, encoding='utf-8', newline='\n')
    (target / 'ue4ss/Mods/mods.txt').write_text(''.join(f'{name} : 1\n' for name in sources), encoding='utf-8')
    entries = [{'relative_path':str(p.relative_to(target)), 'bytes':p.stat().st_size,
                'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
               for p in sorted(target.rglob('*')) if p.is_file()]
    plan = {'staging_root':str(target), 'official_archive_sha256':EXPECTED,
            'purpose':'bounded observer and metadata only; no checks or unlocks',
            'optional_metadata':args.include_optional, 'gas_metadata':args.include_gas, 'stock_mods_included':False,
            'debug_windows_enabled':False, 'entries':entries}
    plan.update(wave_observer=args.wave_observer, session_nonce=nonce)
    (session / 'install-plan.json').write_text(json.dumps(plan, indent=2), encoding='utf-8')
    print(json.dumps({'plan':str(session/'install-plan.json'), 'files':len(entries),
                      'live_writes':False, 'optional_metadata':args.include_optional}, indent=2))


if __name__ == '__main__':
    main()

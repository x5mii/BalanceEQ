#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Extract explicit upstream target compatibility; never guess a rig from a headphone name."""
import ast, csv, hashlib, io, json, math, subprocess
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
COMMIT = '7ae0f56d53074872b028649617a22bbb4232feb7'
OUT = ROOT / 'Sources/EQCore/Resources'
CACHE = ROOT / '.build/autoeq/targets' / COMMIT
BASE = f'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/{COMMIT}/'


def fetch(path):
    CACHE.mkdir(parents=True, exist_ok=True)
    file = CACHE / hashlib.sha256(path.encode()).hexdigest()
    if not file.exists():
        temporary = file.with_suffix('.part')
        subprocess.run(['curl', '-fLsS', '--proto', '=https', '--proto-redir', '=https', '--max-time', '60', BASE + quote(path, safe='/'), '-o', str(temporary)], check=True)
        temporary.replace(file)
    return file.read_text()


class PathsToStrings(ast.NodeTransformer):
    def visit_Call(self, node):
        if isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) and node.func.value.id == 'TARGETS_PATH' and node.func.attr == 'joinpath' and len(node.args) == 1:
            return node.args[0]
        raise ValueError('Unexpected call in upstream target metadata')


def main():
    tree = ast.parse(fetch('dbtools/create_webapp_data.py'))
    assignment = next(n for n in ast.walk(tree) if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'targets' for t in n.targets))
    definitions = ast.literal_eval(PathsToStrings().visit(assignment.value))
    records, matches, excluded = [], {}, []
    for definition in definitions:
        if not definition.get('compatible'): continue
        file = definition['file']; identity = hashlib.sha256(file.encode()).hexdigest()[:24]
        rows = list(csv.DictReader(io.StringIO(fetch('targets/' + file))))
        frequencies = [float(r['frequency']) for r in rows]
        levels = [float(r['raw']) for r in rows]
        assert all(math.isfinite(x) for x in frequencies + levels)
        assert frequencies[0] <= 20 and frequencies[-1] >= 19900
        assert all(a < b for a,b in zip(frequencies,frequencies[1:]))
        records.append(dict(id=identity, name=definition.get('label',file[:-4]), frequencies=frequencies, levels=levels, bassGain=definition['bassBoost']['gain'], sourceURL=BASE + quote('targets/'+file,safe='/')))
        for role, rules in [('neutral', definition.get('recommended', [])), ('harman', definition['compatible'] if ('Harman over-ear 2018 without bass' in file or 'Harman in-ear 2019 without bass' in file) else [])]:
            for rule in rules:
                variant = (rule.get('rig','') + ' ' + rule['form']).strip()
                key = rule['source'] + '/' + variant
                record = matches.setdefault(key,{})
                assert role not in record, (key,role)
                record[role] = identity
    profiles = json.loads((OUT/'calibration-index.json').read_text())['profiles']
    for profile in profiles:
        roles = matches.get(profile['source']+'/'+profile['variant'],{})
        for role in ['neutral','harman']:
            if role not in roles: excluded.append(dict(id=profile['id'],name=profile['name'],mode=role,reason='No explicit compatible upstream target mapping'))
    (OUT/'calibration-targets.json').write_text(json.dumps(dict(version=1,commit=COMMIT,targets=records,matches=matches),separators=(',',':'))+'\n')
    (OUT/'Calibration-Target-Exclusions.json').write_text(json.dumps(excluded,indent=2)+'\n')
    (OUT/'Calibration-Targets-Provenance.txt').write_text(f'AutoEq {COMMIT}, MIT; original authors retained in AutoEq-LICENSE.txt.\nCompatibility extracted literally (AST, no execution) from dbtools/create_webapp_data.py.\nNeutral: upstream recommended base target without the added preference bass shelf. This is BalanceEQ Neutral, not Sonarworks Studio Reference.\nHarman: upstream explicitly compatible Harman base target plus its documented 105 Hz, Q 0.7 preference shelf, evaluated at AutoEq default 44100 Hz.\nTargets are anchored once to the published reference at 1 kHz; the measurement and prediction are never independently normalized.\nUnsupported associations are listed in Calibration-Target-Exclusions.json.\nRegenerate: python3 scripts/update-calibration-targets.py\n')
    print(f'{len(records)} target curves; {len(matches)} explicit measurement mappings; {len(excluded)} unavailable model/mode combinations')


if __name__ == '__main__': main()

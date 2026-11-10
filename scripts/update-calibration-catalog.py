#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bundle matched AutoEq recommended measurements, targets and parametric filters.
Uses system curl (verified HTTPS), a pinned snapshot and a resumable build cache.
No Python or network access is needed by the app.
"""
import concurrent.futures, csv, hashlib, io, json, math, re, subprocess
from pathlib import Path
from urllib.parse import quote, unquote

COMMIT = '7ae0f56d53074872b028649617a22bbb4232feb7'
ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.build/autoeq/cache' / COMMIT
OUT = ROOT / 'Sources/EQCore/Resources'
BASE = f'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/{COMMIT}/'
CACHE.mkdir(parents=True, exist_ok=True)


def fetch(path):
    dest = CACHE / hashlib.sha256(path.encode()).hexdigest()
    if not dest.exists():
        temp = dest.with_suffix('.part')
        result = subprocess.run(['curl', '-fLsS', '--proto', '=https', '--proto-redir', '=https', '--retry', '3',
                        '--connect-timeout', '15', '--max-time', '90', BASE + quote(path, safe='/'), '-w', '%{http_code}', '-o', str(temp)], capture_output=True, text=True)
        if result.returncode:
            if result.stdout == '404': raise ValueError('matching upstream file missing: ' + path)
            raise RuntimeError(result.stderr)

        temp.replace(dest)
    return dest.read_text(encoding='utf-8-sig')


def convert(item):
    name, path = item
    try:
        text = fetch(f'results/{path}/{path.rsplit("/",1)[-1]} ParametricEQ.txt')
        bands, preamp = [], None
        types = {'PK': 'peak', 'LSC': 'lowShelf', 'HSC': 'highShelf'}
        for line in text.splitlines():
            if not line.strip() or line.startswith('#'): continue
            if line.startswith('Preamp:'):
                preamp = float(line.split()[1]); continue
            m = re.fullmatch(r'Filter \d+: (ON|OFF) (PK|LSC|HSC) Fc ([\d.eE+-]+) Hz Gain ([\d.eE+-]+) dB Q ([\d.eE+-]+)', line.strip())
            if not m: raise ValueError('unsupported filter convention')
            enabled, typ, f, g, q = m.groups(); f,g,q=map(float,(f,g,q))
            if not (10 <= f <= 20000 and -24 <= g <= 24 and .1 <= q <= 30): raise ValueError('filter outside engine bounds')
            bands.append(dict(type=types[typ], enabled=enabled=='ON', frequency=f, gainDB=g, q=q))
        if preamp is None or not -60 <= preamp <= 12 or not 1 <= len(bands) <= 32: raise ValueError('invalid preamp/filter count')
        rows = list(csv.DictReader(io.StringIO(fetch(f'results/{path}/{path.rsplit("/",1)[-1]}.csv'))))
        f = [float(r['frequency']) for r in rows]
        raw = [float(r['raw']) for r in rows]; target = [float(r['target']) for r in rows]
        if not 2 <= len(f) <= 8192 or not all(math.isfinite(x) for a in [f,raw,target] for x in a): raise ValueError('invalid curve data')
        if any(b <= a for a,b in zip(f,f[1:])) or f[0] > 20 or f[-1] < 19900: raise ValueError('insufficient frequency coverage')
        # Keep original samples: no smoothing or invented measurement features.
        record = dict(frequencies=f, measured=raw, target=target, preampDB=preamp, bands=bands)
        source, rig, _ = path.split('/',2)
        identity = hashlib.sha256(path.encode()).hexdigest()[:24]
        metadata = dict(id=identity, name=name, source=source, variant=rig,
                        targetName=f'AutoEq published target · {source} / {rig}',
                        sourceURL=f'https://github.com/jaakkopasanen/AutoEq/tree/{COMMIT}/results/'+quote(path,safe='/'))
        return metadata, record, None
    except (ValueError, KeyError) as error:
        return None, None, dict(name=name,path=path,reason=str(error))


def main():
    index = fetch('results/README.md')
    items = [(name,unquote(path)) for name,path in re.findall(r'^- \[(.*)\]\(\./(.*)\)$',index,re.M)]
    if not items: raise ValueError('Empty recommended index')
    records, excluded = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        for i,result in enumerate(pool.map(convert,items)):
            meta, data, error = result
            if error: excluded.append(error)
            else: records.append((meta,data))
            if i % 250 == 0: print(f'Processed {i}/{len(items)}',flush=True)
    records.sort(key=lambda r:(r[0]['name'].casefold(),r[0]['id']))
    manifest=[]; offset=0
    with (OUT/'calibration-curves.jsonl').open('wb') as output:
        for meta,data in records:
            line=(json.dumps(data,separators=(',',':'),allow_nan=False)+'\n').encode()
            meta.update(offset=offset,length=len(line)); manifest.append(meta)
            output.write(line); offset+=len(line)
    (OUT/'calibration-index.json').write_text(json.dumps(dict(version=1,commit=COMMIT,profiles=manifest),separators=(',',':'))+'\n')
    (OUT/'AutoEq-Excluded.json').write_text(json.dumps(excluded,indent=2)+'\n')
    (OUT/'AutoEq-LICENSE.txt').write_text(fetch('LICENSE'))
    (OUT/'AutoEq-Provenance.txt').write_text(f'AutoEq snapshot {COMMIT}\nhttps://github.com/jaakkopasanen/AutoEq\nMIT license; see AutoEq-LICENSE.txt. Measurement authors and exact result links are retained per record.\nRecommended entries: {len(items)}; included: {len(records)}; excluded: {len(excluded)}.\nRaw and target CSV columns are retained without smoothing. Playback uses the matching ParametricEQ.txt, not the idealized equalized CSV columns.\nTarget labels identify the published result rather than guessing a Harman version from its headphone name.\nRegenerate: python3 scripts/update-calibration-catalog.py\n')
    print(f'Included {len(records)}; excluded {len(excluded)}; curves {offset/1e6:.1f} MB',flush=True)

if __name__=='__main__': main()

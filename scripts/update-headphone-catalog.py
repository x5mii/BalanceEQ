#!/usr/bin/env python3
"""Convert the pinned OPRA data without truncating or approximating any EQ profile."""
import collections
import hashlib
import json
import math
from pathlib import Path
import sys
from urllib.request import urlopen

COMMIT = "0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865"
SOURCE = f"https://raw.githubusercontent.com/opra-project/OPRA/{COMMIT}/dist/database_v1.jsonl"
text = Path(sys.argv[1]).read_text() if len(sys.argv) > 1 else urlopen(SOURCE, timeout=30).read().decode()
rows = [json.loads(line) for line in text.splitlines()]
vendors = {row["id"]: row["data"] for row in rows if row["type"] == "vendor"}
products = {row["id"]: row["data"] for row in rows if row["type"] == "product"}
TYPES = {"peak_dip": "peak", "low_shelf": "lowShelf", "high_shelf": "highShelf"}
profiles, excluded = [], []


def bounded(value, minimum, maximum):
    return isinstance(value, (int, float)) and math.isfinite(value) and minimum <= value <= maximum


for row in rows:
    if row["type"] != "eq":
        continue
    data = row["data"]
    parameters = data["parameters"]
    reason = None
    if data["type"] != "parametric_eq":
        reason = "unsupported EQ type"
    elif not 1 <= len(parameters["bands"]) <= 32:
        reason = "filter count outside 1–32"
    elif not bounded(parameters["gain_db"], -60, 12):
        reason = "preamp outside −60…+12 dB"
    bands = []
    for band in parameters["bands"]:
        if band["type"] not in TYPES or "slope" in band or "q" not in band:
            reason = "unsupported filter convention (requires explicit Q-based peak or center shelf)"
        elif not (bounded(band["frequency"], 10, 20_000)
                  and bounded(band.get("gain_db", 0), -24, 24)
                  and bounded(band["q"], 0.1, 30)):
            reason = "filter parameters outside frequency/gain/Q boundaries"
        else:
            bands.append(dict(type=TYPES[band["type"]], frequency=band["frequency"], gainDB=band.get("gain_db", 0), q=band["q"]))
    if reason:
        excluded.append(dict(id=row["id"], reason=reason))
        continue
    product = products[data["product_id"]]
    name = vendors[product["vendor_id"]]["name"] + " " + product["name"]
    assert 0 < len(name) <= 70 and 0 < len(data["author"]) <= 25
    profiles.append(dict(id=row["id"], name=name, creator=data["author"], description=data.get("details", ""),
                         sourceURL=data.get("link"), preampDB=parameters["gain_db"], bands=bands))

profiles.sort(key=lambda profile: (profile["name"].casefold(), profile["creator"].casefold(), profile["description"].casefold(), profile["id"]))
assert profiles and len({profile["id"] for profile in profiles}) == len(profiles)
for profile in profiles:
    profile["presetName"] = f'{profile["name"]} — {profile["creator"]}' + (f' • {profile["description"]}' if profile["description"] else "")
counts = collections.Counter(profile["presetName"] for profile in profiles)
for profile in profiles:
    if counts[profile["presetName"]] > 1:
        profile["presetName"] += f' • {len(profile["bands"])} bands'
counts = collections.Counter(profile["presetName"] for profile in profiles)
for profile in profiles:
    if counts[profile["presetName"]] > 1 or len(profile["presetName"]) > 100:
        short_id = hashlib.sha256(profile["id"].encode()).hexdigest()[:8]
        profile["presetName"] = profile["presetName"][:89] + " • " + short_id
assert len({profile["presetName"] for profile in profiles}) == len(profiles)
output = Path(__file__).resolve().parent.parent / "Sources/EQCore/Resources"
output.mkdir(parents=True, exist_ok=True)
(output / "headphones.json").write_text(json.dumps(dict(version=1, commit=COMMIT, profiles=profiles), ensure_ascii=False, separators=(",", ":")) + "\n")
(output / "OPRA-Excluded.json").write_text(json.dumps(excluded, ensure_ascii=False, indent=2) + "\n")
print(f"Included {len(profiles)} complete profiles; excluded {len(excluded)} profiles, without approximating filters.")
for reason, count in collections.Counter(item["reason"] for item in excluded).items():
    print(f"  {count}: {reason}")

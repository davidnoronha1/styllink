#!/usr/bin/env python3
"""Summarize native-app lock-on/off segments from StylLink JSON-lines logs."""
import argparse
import json
import statistics

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('log', help='server JSON-lines log')
args = parser.parse_args()
states = {}
groups = {True: [], False: []}
with open(args.log) as log:
    for number, line in enumerate(log, 1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            parser.error(f'{args.log}:{number}: {exc}')
        peer, kind = event.get('peer'), event.get('ev')
        if kind == 'start':
            states.clear()
        elif kind in ('connect', 'disconnect'):
            states.pop(peer, None)
        elif kind == 'caps':
            states[peer] = event.get('wifi_lock', False) if event.get('native') else None
        elif kind == 'stat' and states.get(peer) is not None and event.get('msgs', 0) > 0:
            groups[states[peer]].append(event)

def median(rows, key):
    values = [row[key] for row in rows if key in row]
    return f'{statistics.median(values):.2f}' if values else 'n/a'

print('lock  active stat windows  stalls/window  gap_max median ms  uplink p95 median ms')
for lock, rows in groups.items():
    if not rows:
        print(f'{"on" if lock else "off":4}  no native pen data')
        continue
    rate = sum(row.get('stalls', 0) for row in rows) / len(rows)
    print(f'{"on" if lock else "off":4}  {len(rows):19}  {rate:13.2f}  '
          f'{median(rows, "gap_max_ms"):>17}  {median(rows, "uplink_p95_ms"):>20}')
print('Each stat window is about one second. Uplink is the median of per-window p95s.')
print('Use continuous strokes of equal duration; pauses between strokes also count as gaps.')

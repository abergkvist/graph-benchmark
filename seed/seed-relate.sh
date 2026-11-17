#!/usr/bin/env bash
# Seeds a Relate store in relate/benchmark from data/. Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

IMPORT=relate/import
rm -rf relate/benchmark "$IMPORT"
mkdir -p "$IMPORT"
cp data/link.csv data/platsmitt.csv data/rinf-op.csv data/rinf-sections.csv "$IMPORT"/

# lank.csv is 19 MB, over LOAD CSV's 8 MiB limit; only two columns are used.
python3 - <<'PY'
import csv
with open('data/lank.csv', newline='') as src, open('relate/import/lank.csv', 'w', newline='') as dst:
    r = csv.DictReader(src)
    w = csv.writer(dst)
    w.writerow(['ELEMENT_ID', 'Sparlangd'])
    for row in r:
        w.writerow([row['ELEMENT_ID'], row['Sparlangd']])
PY

relate query --database relate/benchmark --load-csv-dir "$IMPORT" \
  --fetch-params ts=data/trainstations.json --mode table \
  < seed/seed-relate.cypher

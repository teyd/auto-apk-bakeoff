# auto-apk bake-off (throwaway)

Phase 0 of auto-apk: APKPure (apkeep) against APKMirror (trawl) for the 8 apps.
For each app: ask Morphe for the target version, fetch it from each source,
check the signing certificate, patch it with Morphe, record the result.

- `scripts/run.sh` runs everything and appends to `results/<run>.jsonl`.
- `scripts/report.sh` turns all result files into tables.
- `.github/workflows/bakeoff.yml` runs it on `ubuntu-latest` (manual and daily).

Nothing here is published. Delete this repo after Phase 0.

# Phase 0 findings (beyond results/*.jsonl)

## Signing certificates
Pins are the original (v3.0) signer, present in every APK and split. Three apps
also carry a rotated v3.1 key (Android 13+), so the gate is "pin is among the
signers", not "signers equal pin".

| App | Pin (original key) | Rotated v3.1 key |
|---|---|---|
| YouTube | 3d7a1223…994a | 5aad2bee…b0c6 |
| Instagram | 5f3e50f4…e305 | 3a10c50c…c014 (Meta Platforms) |
| Gboard | f0fd6c5b…db83 | 7ce83c1b…5053 |
| X, Reddit, Twitch | j-hc list, matched | none |
| Discord, TikTok | agreed by both sources | none |

## Morphe on an unsupported version (YouTube 21.31.524, no --force)
Exit 0, result.json `success: true`, 0 applied, 0 failed. Every patch is logged
as "incompatible" and skipped. The output is a stock app. Only the check
`applied == expected (from list-versions)` catches it.

## APKPure and YouTube 21.30.216
Missing from the API (apkeep) and the website versions page (21.30.209 is the
nearest). The download URL redirects to the generic APK Downloader page.
apkeep exits 0 with no file when a version is missing.

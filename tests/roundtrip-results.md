# Roundtrip Test Results

**Date:** 2026-04-11 12:38:20
**Verdict:** PASS

## Test Configuration

| Parameter | Value |
|-----------|-------|
| Test file | test-roundtrip.bin |
| File size | 25MB |
| Job hash | roundtrip-1775903188 |
| NZB file | roundtrip-1775903188.nzb |
| SABnzbd version | 4.5.5 |
| Docker platform | linux/amd64 |

## Timing

| Phase | Duration |
|-------|----------|
| Phase 1: Prepare test file | <1s (25MB /dev/urandom) |
| Phase 2: Upload to Usenet | ~15s (7z + PAR2 + Nyuu upload) |
| Phase 3: Propagation wait | 480s (8 minutes) |
| Phase 4: Download via SABnzbd | 10s (1s download + 9s overhead) |
| Phase 5: Verify byte-identity | <1s |
| **Total** | **~506s (~8.4 minutes)** |

## SHA256 Verification

| File | SHA256 |
|------|--------|
| Original | `9d574e725a378e275ff6435a9bae730dce073420be99d685191449fd1432298d` |
| Extracted | `9d574e725a378e275ff6435a9bae730dce073420be99d685191449fd1432298d` |
| **Match** | **✅ YES** |

## Upload Details

- NZB file: roundtrip-1775903188.nzb
- NZB size: 8740 bytes
- Password meta tag: ✅ Present (`<meta type="password">aeuW4DBO7wWHHDkWbwrlTJNS</meta>`)
- Provider 1 (EasyUsenet): ✅ Uploaded 34.58 MiB in 12.7s (2788 KiB/s)
- Nyuu config: Used `${rand(20)}` subject + `${rand(15)}` yenc-name obfuscation (T01 fix)
- 7z: header encryption enabled (-mhe=on)
- PAR2: 30% redundancy (11 files)

## SABnzbd Download Details

```json
{
  "status": "Completed",
  "name": "roundtrip-test",
  "size": "30.3 MB",
  "download_time": 1,
  "postproc_time": 0,
  "fail_message": "",
  "stage_log": [
    {"name": "Source", "actions": ["roundtrip-1775903188.nzb"]},
    {"name": "Download", "actions": ["Downloaded in 1 sec at an average of 15.4 MB/s<br/>Age: 11m"]},
    {"name": "Servers", "actions": ["reader.easyusenet.com=30.3 MB"]},
    {"name": "Repair", "actions": ["[roundtrip-1775903188] Quick Check OK", "Trying RAR renamer"]},
    {"name": "Unpack", "actions": ["[roundtrip-1775903188.7z] Trying 7zip with password \"aeuW4DBO7wWHHDkWbwrlTJNS\"", "[roundtrip-1775903188.7z] Unpacked 1 files/folders in 0 seconds"]},
    {"name": "Deobfuscate", "actions": ["Deobfuscate renamed 1 file(s)"]}
  ]
}
```

## Result

**✅ PASS — Pipeline proven end-to-end!**

The full roundtrip completed successfully:
1. Test file created (25MB random data)
2. Uploaded to Usenet via Nyuu (obfuscated subjects + yEnc names via `${rand(N)}` tokens)
3. Downloaded via SABnzbd in 1 second
4. Extracted password-protected 7z archive — SABnzbd read password from `<meta type="password">` NZB meta tag
5. **SHA256 of extracted file matches original — byte-identical**

### Key Pipeline Stages Verified

- **T01 Obfuscation fix:** Nyuu `${rand(N)}` tokens work correctly — SABnzbd deobfuscation renamed 1 file
- **T02 Password delivery:** `<meta type="password">` tag in NZB works — SABnzbd used it to extract 7z with `-mhe=on`
- **PAR2 verification:** Quick Check OK — no repair needed (clean upload)
- **7z extraction:** Password-protected archive with header encryption extracted successfully

## Environment

- Upload image: openmedia-uploader:roundtrip-test (rebuilt with T01 obfuscation fix)
- SABnzbd: lscr.io/linuxserver/sabnzbd:latest (v4.5.5)
- S3 bypass: test file mounted directly into container (no S3 dependency for this test)
- Provider: EasyUsenet (reader.easyusenet.com:563, SSL, 10 connections)

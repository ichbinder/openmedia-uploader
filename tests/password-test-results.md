# SABnzbd Password Extraction Test Results

**Date:** 2026-04-11  
**SABnzbd Version:** 4.5.5  
**Docker Image:** lscr.io/linuxserver/sabnzbd:latest  
**Test NZB:** test-3p-corrected_p1.nzb (password: `lMGBaN5GK99tq8FhidfLe7F`)

## Test 1: NZB `<meta type="password">` Tag

**Result: ✅ PASS**

SABnzbd successfully reads the password from the NZB's `<meta type="password">` tag and uses it to extract password-protected 7z archives with header encryption (`-mhe=on`).

**Evidence from SABnzbd history stage_log:**
```
Unpack stage:
  "[test-3p-corrected.7z] Trying 7zip with password \"lMGBaN5GK99tq8FhidfLe7F\""
  "[test-3p-corrected.7z] Unpacked 1 files/folders in 0 seconds"
```

- Download: 227.1 MB in 9 seconds (24.9 MB/s)
- Status: Completed
- Extracted file: `test-3p-corrected.mkv` (224.7 MB)

## Test 2: No Password (Negative Test)

**Result: ❌ Failed as expected**

Removed the `<meta type="password">` tag from the NZB. SABnzbd downloaded successfully but failed to extract:

```
Status: Failed
fail_message: "Unpacking failed, see logfile"
```

This confirms that without the password, the 7z archive with header encryption cannot be extracted, and the password must be provided.

## Test 3: `{{password}}` Filename Convention (Fallback)

**Result: ✅ PASS**

Renamed the no-password NZB to include `{{lMGBaN5GK99tq8FhidfLe7F}}` in the filename. SABnzbd extracted the password from the filename and successfully unpacked:

```
Unpack stage:
  "[test-3p-corrected.7z] Trying 7zip with password \"lMGBaN5GK99tq8FhidfLe7F\""
  "[test-3p-corrected.7z] Unpacked 1 files/folders in 0 seconds"
```

- Status: Completed
- Extracted file: `test-filename-pw.mkv` (224.7 MB)

## Conclusion

Both password delivery methods work in SABnzbd 4.5.5:

1. **Primary (recommended):** `<meta type="password">` tag in NZB — this is the standard NZB 1.1 spec approach
2. **Fallback:** `{{password}}` in the NZB filename — works but non-standard

**Recommendation:** Use the `<meta type="password">` tag as the primary method (already implemented in upload.sh). The filename fallback is available if needed for compatibility with other downloaders.

## Test Environment

- Usenet server: reader.easyusenet.com (port 563, SSL)
- Articles were ~16 hours old at test time
- No propagation issues observed — all articles were available

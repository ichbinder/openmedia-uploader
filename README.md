# openmedia-uploader

Usenet Re-Upload Service für openmedia. Nimmt eine MKV von Hetzner S3, teilt sie in 250MB 7z-Parts (Header-Encrypted), generiert 30% PAR2, und uploaded über Nyuu auf alle 3 Usenet-Provider gleichzeitig.

## Architektur

```
openmedia-api              S3 (Hetzner)               Usenet (Eweka + Newshosting + EasyUsenet)
┌──────────────────┐       ┌──────────────────────┐    ┌──────────────────────────────────────────┐
│ DownloadJob      │       │ {hash}/original.mkv  │    │ Provider 1 → alt.binaries.xxx            │
│ .completed       │       │                      │    │ Provider 2 → alt.binaries.yyy            │
│                  │──────▶│                      │───▶│ Provider 3 → alt.binaries.zzz            │
│ POST             │       └──────────────────────┘    │                                          │
│ /upload-jobs     │                                   │ 7z Parts (250MB, -mhe=on)               │
│                  │◀─────────────────────────────────│ PAR2 (30% redundancy)                    │
│ PATCH            │       ┌──────────────────────┐    │ NZB (mit Passwort-Meta)                  │
│ /upload-jobs/:id │       │ nzb/{hash}.nzb       │    └──────────────────────────────────────────┘
└──────────────────┘       └──────────────────────┘
  NzbFile.ownUsenetHash          NZB Output
```

## Stream-Pipeline

```bash
# 1. mkfifo pipe
mkfifo /tmp/mkv.fifo

# 2. rclone streamt MKV von S3 in die Pipe
rclone cat s3:bucket/{hash}/original.mkv > /tmp/mkv.fifo &

# 3. 7z liest von der Pipe, schreibt Parts
7z a -si"hash.mkv" -p{PASS} -mhe=on -mx0 -v250m /tmp/hash.7z < /tmp/mkv.fifo

# 4. par2create für 30% Redundanz
par2create -r30 hash.par2 hash.7z.*

# 5. Nyuu uploaded auf alle 3 Provider
nyuu -c nyuu.conf.json hash.7z.* hash.par2*
```

## Newsgroup-Pool

9 Gruppen, pro Upload werden 3 zufällig gewählt, je Provider eine:

```
alt.binaries.misc
alt.binaries.flowed
alt.binaries.iso
alt.binaries.test
alt.binaries.a51
alt.binaries.mom
alt.binaries.bloaf
alt.binaries.boneless
alt.binaries.multimedia
```

## Environment Variables

| Variable | Beschreibung |
|----------|-------------|
| `JOB_ID` | UploadJob ID |
| `JOB_HASH` | NzbFile Hash |
| `S3_KEY` | S3 Key der MKV |
| `S3_ENDPOINT` | Hetzner S3 Endpoint |
| `S3_BUCKET` | S3 Bucket Name |
| `S3_ACCESS_KEY` | S3 Access Key |
| `S3_SECRET_KEY` | S3 Secret Key |
| `API_BASE_URL` | openmedia-api URL |
| `SERVICE_TOKEN` | API Auth Token |
| `HETZNER_API_TOKEN` | Für VPS Self-Delete |
| `USENET_HOST_1` | Provider 1 Host (z.B. post.eweka.nl) |
| `USENET_PORT_1` | Provider 1 Port |
| `USENET_USER_1` | Provider 1 Username |
| `USENET_PASS_1` | Provider 1 Password |
| `USENET_SSL_1` | Provider 1 SSL (1/0) |
| `USENET_CONNS_1` | Provider 1 Connections |
| `USENET_HOST_2/3` | Analog für Provider 2+3 |
| `POSTER_NAME` | NNTP From-Header |

## Bau mit GHCR

```bash
docker pull ghcr.io/ichbinder/openmedia-uploader:latest
```

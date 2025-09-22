# Bulk OPNsense Unbound Host Overrides (PowerShell)

This repo contains a PowerShell script that **bulk-creates Unbound “Host Overrides”** on an OPNsense firewall from a CSV.
It calls the official Unbound MVC API and can optionally **replace** existing entries and **reconfigure** Unbound.

**Script:** `bulk_add_opnsense_host_overrides.ps1`

---

## What it does

- Reads a CSV (default: `bulk_overrides.csv`) with columns **FQDN, IP, DESCRIPTION**.
- Splits `FQDN` into `hostname` + `domain` (e.g., `auth.example.com` → `auth` + `example.com`).
- Adds **A records** as Unbound **Host Overrides** via the OPNsense API.
- Skips duplicates automatically (or deletes/re-adds with `-ReplaceExisting`).
- Calls **`/api/unbound/service/reconfigure`** at the end when `-Apply` is specified.
- Works with **Windows PowerShell 5.1** and **PowerShell 7+** (optional self‑signed TLS bypass).

---

## Requirements

- OPNsense with **Unbound DNS** enabled.
- **API key/secret** with permission to manage Unbound settings and reconfigure.
- PowerShell **5.1+** (Windows) or **7+** (cross‑platform).

> If script signing is enforced, either sign the script (see below) or run once with `-ExecutionPolicy Bypass` / `Unblock-File`.

---

## CSV format

Canonical headers (case‑insensitive; leading/trailing spaces tolerated):

```csv
FQDN,IP,DESCRIPTION
auth.example.com,10.1.1.100,Auth portal
```

- **FQDN** – full hostname (no trailing dot).
- **IP** – IPv4 address (A record). AAAA support can be added.
- **DESCRIPTION** – optional description shown in the UI.

---

## Usage

```powershell
# One-time run (bypass execution policy for this call only)
powershell -NoProfile -ExecutionPolicy Bypass -File bulk_add_opnsense_host_overrides.ps1
```

### Parameters

- `-OpnUri` — OPNsense base URL (e.g., `https://<firewall>:<port>`).
- `-ApiKey`, `-ApiSecret` — OPNsense API credentials.
- `-CsvPath` — Path to input CSV (default: `bulk_overrides.csv`).
- `-Apply` — Reconfigure Unbound after changes.
- `-ReplaceExisting` — If an override exists, **delete** it first, then add the new one.
- `-SkipTLSVerify` — Skip certificate validation (helpful with self‑signed GUI certs).

### API endpoints used

- `POST /api/unbound/settings/searchHostOverride`
- `POST /api/unbound/settings/addHostOverride`
- `POST /api/unbound/settings/delHostOverride`
- `POST /api/unbound/service/reconfigure`

---

## Behavior details

- **De‑duplication**: The script calls `searchHostOverride` and builds a map of `hostname.domain → uuid`.
  - Without `-ReplaceExisting`: matching entries are **skipped**.
  - With `-ReplaceExisting`: matching entries are **deleted** then added fresh.
- **TTL**: Defaults to `300` seconds (adjust in script if desired).
- **IPv6**: Script currently adds **A** records. We can add AAAA support (extra CSV column or a second pass).
- **Unbound includes**: If you maintain a custom `local-zone: "<domain>." redirect`, it may overshadow host overrides.
  Use `transparent`/`static` zone types when per‑host answers must win.

---

## Troubleshooting

- **Unsigned script / execution policy**  
  - One‑time bypass:  
    `powershell -NoProfile -ExecutionPolicy Bypass -File bulk_add_opnsense_host_overrides.ps1 ...`
  - Or unblock:  
    `Unblock-File bulk_add_opnsense_host_overrides.ps1` and `Unblock-File bulk_overrides.csv`
- **Self‑signed TLS**  
  Add `-SkipTLSVerify` or trust the OPNsense GUI cert on your machine.
- **Warnings like `Add failed for <host>:`**  
  The script surfaces the API response body where possible—common issues are invalid IP/FQDN, missing privileges, or endpoint mismatch.

---

## Optional: environment variables & signing

- **Environment variables**:
  ```powershell
  $Env:OPNSENSE_KEY = "<KEY>"
  $Env:OPNSENSE_SECRET = "<SECRET>"
  bulk_add_opnsense_host_overrides.ps1 -OpnUri https://10.1.1.1:440 `
    -ApiKey $Env:OPNSENSE_KEY -ApiSecret $Env:OPNSENSE_SECRET -CsvPath bulk_overrides.csv -Apply
  ```
- **Sign the script (AllSigned)**:
  ```powershell
  $cert = New-SelfSignedCertificate -DnsName "Local Script Signing" -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "TrustedPublisher","CurrentUser"
  $store.Open("ReadWrite"); $store.Add($cert); $store.Close()
  Set-AuthenticodeSignature -FilePath bulk_add_opnsense_host_overrides.ps1 -Certificate $cert
  ```

---

## Example output

```
Deleted existing: auth.example.com (uuid=abcd-1234...)
Added: auth.example.com -> 10.1.1.100 (Auth portal)
Unbound reconfigure: ok

Done. Added=1 Updated(Deleted)=1 Skipped=0 Errors=0
```

---

## License

MIT

# Adds bulk Unbound "Host Overrides" on OPNsense from a CSV
# CSV headers expected (case-insensitive; spaces OK): FQDN, IP, DESCRIPTION
# Example row: auth.jbhome.cloud, 10.1.40.42, Auth portal

param(
  [string]$OpnUri = "OPNsense URI, e.g. https://10.1.1.1",
  [string]$ApiKey = "",
  [string]$ApiSecret = "",
  [string]$CsvPath = "bulk_overrides.csv",
  [switch]$Apply = $true,
  [switch]$SkipTLSVerify = $true,
  [switch]$ReplaceExisting = $false  # if set, delete existing host override before adding
)

if (-not $ApiKey -or -not $ApiSecret) {
  Write-Error "Provide -ApiKey and -ApiSecret (OPNsense API key/secret)."
  exit 1
}

# --- TLS: allow skipping certificate validation on PS5/PS7 ---
$irmHasSkip = $false
try {
  $irmCmd = Get-Command Invoke-RestMethod -ErrorAction Stop
  $irmHasSkip = $irmCmd.Parameters.ContainsKey('SkipCertificateCheck')
} catch {}

if ($SkipTLSVerify -and -not $irmHasSkip) {
  try {
    add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
  } catch {
    Write-Warning "Could not install TrustAllCertsPolicy. You may need to trust the OPNsense cert."
  }
}

# --- Helpers ---
function _HeaderAuth {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$ApiKey" + ":" + "$ApiSecret"))
  $h = @{
    "Authorization" = "Basic $encoded"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
  }
  return $h
}

function _InvokeJson([string]$Uri, $Body) {
  $json = $null
  if ($Body -ne $null) { $json = ($Body | ConvertTo-Json -Depth 8) }

  $headers = _HeaderAuth
  $common = @{
    Uri     = $Uri
    Method  = "POST"
    Headers = $headers
  }
  if ($json) { $common["Body"] = $json }
  if ($SkipTLSVerify -and $irmHasSkip) { $common["SkipCertificateCheck"] = $true }

  try {
    return Invoke-RestMethod @common
  } catch {
    # Try to surface the actual response body if available
    $respText = $null
    if ($_.Exception -and $_.Exception.Response) {
      try {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $respText = $reader.ReadToEnd()
        $reader.Close()
      } catch {}
    }
    if ($respText) {
      throw "Request to $Uri failed: $respText"
    } else {
      throw
    }
  }
}

# --- Endpoints (correct Unbound MVC endpoints) ---
$AddHostURL      = "$OpnUri/api/unbound/settings/addHostOverride"
$SearchHostURL   = "$OpnUri/api/unbound/settings/searchHostOverride"
$DeleteHostURL   = "$OpnUri/api/unbound/settings/delHostOverride"
$ReconfigureURL  = "$OpnUri/api/unbound/service/reconfigure"

# --- Load CSV ---
if (-not (Test-Path -LiteralPath $CsvPath)) {
  Write-Error "CSV not found: $CsvPath"
  exit 1
}

$rows = Import-Csv -LiteralPath $CsvPath

# Normalize property accessors for columns that might have leading spaces
function _GetProp($obj, [string]$name) {
  if ($obj.PSObject.Properties.Name -contains $name) { return $obj.$name }
  $prop = ($obj.PSObject.Properties | Where-Object { $_.Name.Trim().ToLower() -eq $name.Trim().ToLower() } | Select-Object -First 1)
  if ($prop) { return $obj.($prop.Name) }
  return $null
}

# Fetch existing to avoid duplicates (and capture UUIDs)
$existingRows = @()
try {
  $existingRows = _InvokeJson -Uri $SearchHostURL -Body @{ current = 1; rowCount = 9999; sort = @{ } }
} catch {
  Write-Verbose "searchHostOverride failed; proceeding without de-dup. $_"
}
$existingMap = @{}
if ($existingRows -and $existingRows.rows) {
  foreach ($row in $existingRows.rows) {
    if ($row.hostname -and $row.domain -and $row.uuid) {
      $existingMap["$($row.hostname).$($row.domain)".ToLower()] = $row.uuid
    }
  }
}

$added = 0; $skipped = 0; $updated = 0; $errors = 0

foreach ($r in $rows) {
  $fqdn = (_GetProp $r "FQDN")
  $ip   = (_GetProp $r "IP")
  $desc = (_GetProp $r "DESCRIPTION")

  if (-not $fqdn) { Write-Warning ("Skipping row with empty FQDN: {0}" -f ($r | ConvertTo-Json -Compress)); $skipped++; continue }
  $fqdn = "$fqdn".Trim().TrimEnd(".")
  $ip   = "$ip".Trim()
  $desc = "$desc".Trim()

  if (-not $ip -or -not ($ip -match '^\d{1,3}(\.\d{1,3}){3}$')) {
    Write-Warning ("Skipping {0}: invalid IPv4 '{1}'" -f $fqdn, $ip); $skipped++; continue
  }

  $firstDot = $fqdn.IndexOf('.')
  if ($firstDot -lt 1 -or $firstDot -ge ($fqdn.Length - 1)) {
    Write-Warning ("Skipping '{0}': must be host.domain.tld" -f $fqdn); $skipped++; continue
  }
  $hostname = $fqdn.Substring(0, $firstDot)
  $domain   = $fqdn.Substring($firstDot + 1)

  $key = "$hostname.$domain".ToLower()
  $uuid = $null
  if ($existingMap.ContainsKey($key)) { $uuid = $existingMap[$key] }

  if ($uuid -and -not $ReplaceExisting) {
    Write-Host -ForegroundColor Yellow ("Already exists: {0} — skipping" -f $key)
    $skipped++; continue
  }

  if ($uuid -and $ReplaceExisting) {
    try {
      $del = _InvokeJson -Uri $DeleteHostURL -Body @{ uuid = $uuid }
      Write-Host -ForegroundColor DarkYellow ("Deleted existing: {0} (uuid={1})" -f $key, $uuid)
      $updated++
      Start-Sleep -Milliseconds 200
    } catch {
      Write-Warning ("Delete failed for {0}: {1}" -f $key, $_)
    }
  }

  $payload = @{
    host = @{
      enabled     = "1"
      hostname    = $hostname
      domain      = $domain
      rr          = "A"
      server      = $ip
      ttl         = "300"
      description = $desc
      mxprio      = ""
      mx          = ""
      txtdata     = ""
    }
  }

  try {
    $resp = _InvokeJson -Uri $AddHostURL -Body $payload
    if ($resp -and $resp.result -eq "saved") {
      Write-Host -ForegroundColor Cyan ("Added: {0} -> {1} ({2})" -f $key, $ip, $desc)
      $added++
    } else {
      Write-Warning ("Add failed for {0}: {1}" -f $key, ($resp | ConvertTo-Json -Compress))
      $errors++
    }
  } catch {
    Write-Warning ("Add failed for {0}: {1}" -f $key, $_)
    $errors++
  }
}

if ($Apply -and ($added -gt 0 -or $updated -gt 0)) {
  try {
    $rc = _InvokeJson -Uri $ReconfigureURL -Body @{} 
    Write-Host -ForegroundColor Green ("Unbound reconfigure: {0}" -f $rc.status)
  } catch {
    Write-Warning ("Reconfigure failed: {0}" -f $_)
  }
}

Write-Host ("`nDone. Added={0} Updated(Deleted)={1} Skipped={2} Errors={3}" -f $added, $updated, $skipped, $errors)

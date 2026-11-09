# This file is also copied to the public repository. Keep it free of private source and credentials.
$script:MapleEngineRepo = 'Micheal-tcy/p5be8f34493564220bd0f11d'
$script:MapleEngineId = 'v8-152.2.0-abi1-win-x64'
$script:MapleEngineTag = "engine-$script:MapleEngineId"
$script:MapleEngineNames = @('engine-manifest.json', 'maple-v8.dll')

function Get-MapleFileSha([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Read-MapleEnginePair([string]$Directory, [string]$ExpectedPin = '') {
  $manifest = Get-Item -LiteralPath (Join-Path $Directory 'engine-manifest.json') -ErrorAction Stop
  $dll = Get-Item -LiteralPath (Join-Path $Directory 'maple-v8.dll') -ErrorAction Stop
  foreach ($item in @($dll, $manifest)) {
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Engine assets must be regular files.' }
  }
  if ($manifest.Length -lt 2 -or $manifest.Length -gt 16KB -or $dll.Length -lt 2 -or $dll.Length -ge 100MB) { throw 'Invalid engine asset size.' }
  $pin = Get-MapleFileSha $manifest.FullName
  if ($ExpectedPin -and $pin -cne $ExpectedPin) { throw 'Engine manifest does not match the pinned original bytes.' }
  $text = [Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($manifest.FullName))
  $json = [System.Text.Json.JsonDocument]::Parse($text)
  try {
    $root = $json.RootElement
    $keys = @($root.EnumerateObject() | ForEach-Object Name | Sort-Object)
    if (($keys -join '|') -cne 'asset|compatibility|schema|sha256|size') { throw 'Unexpected engine manifest fields.' }
    $hash = $root.GetProperty('sha256').GetString()
    if ($root.GetProperty('schema').GetInt32() -ne 1 -or $root.GetProperty('compatibility').GetString() -cne $script:MapleEngineId -or
        $root.GetProperty('asset').GetString() -cne 'maple-v8.dll' -or $root.GetProperty('size').GetInt64() -ne $dll.Length -or
        $hash -cnotmatch '^[0-9a-f]{64}$' -or $hash -cne (Get-MapleFileSha $dll.FullName)) { throw 'Engine DLL/hash/identity mismatch.' }
  } finally { $json.Dispose() }
  return $pin
}

function Get-MapleEngineRelease {
  $headers = @{Accept = 'application/vnd.github+json'}
  if ($env:GH_TOKEN) { $headers.Authorization = "Bearer $env:GH_TOKEN" }
  try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$script:MapleEngineRepo/releases/tags/$script:MapleEngineTag" -Headers $headers -TimeoutSec 30
  } catch {
    if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
    throw
  }
  $assets = @($release.assets)
  if ($release.tag_name -cne $script:MapleEngineTag -or $release.draft -or !$release.prerelease -or
      $assets.Count -ne 2 -or (($assets.name | Sort-Object) -join '|') -cne ($script:MapleEngineNames -join '|')) {
    throw 'Existing engine release is incomplete or has an unexpected identity; it will never be overwritten.'
  }
  foreach ($asset in $assets) {
    $limit = if ($asset.name -ceq 'maple-v8.dll') { 100MB - 1 } else { 16KB }
    if ($asset.state -cne 'uploaded' -or $asset.size -lt 2 -or $asset.size -gt $limit) { throw 'Invalid public engine asset metadata.' }
  }
  return $release
}

function Receive-MapleEnginePair([string]$Directory, $Release, [string]$ExpectedPin = '') {
  if ($null -eq $Release) { throw 'The compatible engine has not been published.' }
  [IO.Directory]::CreateDirectory($Directory) | Out-Null
  foreach ($name in $script:MapleEngineNames) {
    $file = Join-Path $Directory $name
    # Public fixed-tag downloads must work without a token, including release verification.
    Invoke-WebRequest -Uri "https://github.com/$script:MapleEngineRepo/releases/download/$script:MapleEngineTag/$name" -OutFile $file -TimeoutSec 300 | Out-Null
    $asset = @($Release.assets | Where-Object name -CEQ $name)
    if ($asset.Count -ne 1 -or (Get-Item -LiteralPath $file).Length -ne $asset[0].size) { throw "Public engine asset size mismatch: $name" }
  }
  return Read-MapleEnginePair $Directory $ExpectedPin
}

function Assert-MaplePublishedEngine($Release, [string]$Pin, [string]$DllHash, [string]$FallbackDirectory) {
  if ($null -eq $Release) { throw 'The verified engine release disappeared; refusing to publish the assistant.' }
  if ($Pin -cnotmatch '^[0-9a-f]{64}$' -or $DllHash -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid verified engine digests.' }
  $needsDownload = $false
  foreach ($name in $script:MapleEngineNames) {
    $asset = @($Release.assets | Where-Object name -CEQ $name)
    if ($asset.Count -ne 1) { throw 'The verified engine assets changed.' }
    $digest = [string]$asset[0].digest
    $expected = if ($name -ceq 'maple-v8.dll') { $DllHash } else { $Pin }
    if (!$digest) { $needsDownload = $true }
    elseif ($digest -cne "sha256:$expected") { throw "Existing engine asset no longer matches its verified digest: $name" }
  }
  # Older release metadata may not provide digest. Only then reread both files.
  if ($needsDownload) {
    Receive-MapleEnginePair $FallbackDirectory $Release $Pin | Out-Null
    if ((Get-MapleFileSha (Join-Path $FallbackDirectory 'maple-v8.dll')) -cne $DllHash) { throw 'Existing engine DLL changed.' }
  }
}

function New-MapleEnginePair([string]$Directory, [string]$BuiltDll) {
  [IO.Directory]::CreateDirectory($Directory) | Out-Null
  $dll = Copy-Item -LiteralPath $BuiltDll -Destination (Join-Path $Directory 'maple-v8.dll') -Force -PassThru
  $manifest = [ordered]@{schema=1; compatibility=$script:MapleEngineId; asset='maple-v8.dll'; size=$dll.Length; sha256=(Get-MapleFileSha $dll.FullName)}
  $bytes = (ConvertTo-Json -InputObject $manifest -Compress) + [char]10
  [IO.File]::WriteAllText((Join-Path $Directory 'engine-manifest.json'), $bytes, [Text.UTF8Encoding]::new($false))
  return Read-MapleEnginePair $Directory
}

function Resolve-MapleEnginePublication([ValidateSet('create','reuse')][string]$Planned, $Release) {
  if ($null -ne $Release) { return 'reuse' }
  if ($Planned -ceq 'reuse') { throw 'The previously published engine disappeared; it must not be recreated.' }
  return 'create'
}

function Set-MaplePublicEngineFiles([string]$Repository, [string]$Pair, [ValidateSet('create','reuse')][string]$Planned) {
  $pin = Read-MapleEnginePair $Pair
  $dest = Join-Path $Repository "engine/$script:MapleEngineId"
  # Stage a first publication only. A release may have been finalized while the EXE built.
  $release = Get-MapleEngineRelease
  $action = Resolve-MapleEnginePublication $Planned $release
  if ($action -ceq 'reuse') {
    $probe = Join-Path $Pair ('remote-' + [guid]::NewGuid().ToString('N'))
    Assert-MaplePublishedEngine $release $pin (Get-MapleFileSha (Join-Path $Pair 'maple-v8.dll')) $probe
  } else {
    $sparse = & git -C $Repository config --type=bool --default=false --get core.sparseCheckout
    if ($LASTEXITCODE -ne 0) { throw 'Cannot check public checkout configuration.' }
    if ($sparse -ceq 'true') {
      & git -C $Repository sparse-checkout add "engine/$script:MapleEngineId"
      if ($LASTEXITCODE -ne 0) { throw 'Cannot check out first-publication engine assets.' }
    }
    if (Test-Path -LiteralPath $dest) {
      Read-MapleEnginePair $dest $pin | Out-Null
    } else {
      [IO.Directory]::CreateDirectory($dest) | Out-Null
      foreach ($name in $script:MapleEngineNames) { Copy-Item -LiteralPath (Join-Path $Pair $name) -Destination (Join-Path $dest $name) }
    }
  }
  $scripts = Join-Path $Repository '.github/scripts'
  [IO.Directory]::CreateDirectory($scripts) | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'engine-release.ps1') -Destination (Join-Path $scripts 'engine-release.ps1') -Force
  & git -C $Repository add -- .github/scripts/engine-release.ps1
  if ($LASTEXITCODE -ne 0) { throw 'Cannot stage public engine validation script.' }
  if ($action -ceq 'create') {
    foreach ($name in $script:MapleEngineNames) {
      $relative = "engine/$script:MapleEngineId/$name"
      & git -C $Repository add -- $relative
      if ($LASTEXITCODE -ne 0) { throw 'Cannot stage engine asset.' }
      $attribute = & git -C $Repository check-attr --cached text -- $relative
      if ($LASTEXITCODE -ne 0 -or $attribute -cne "${relative}: text: unset") { throw 'Engine asset lacks -text protection.' }
      $blob = & git -C $Repository rev-parse --verify ":$relative"
      if ($LASTEXITCODE -ne 0 -or $blob -cne (& git -C $Repository hash-object --no-filters -- $relative)) { throw 'Git filters changed engine asset bytes.' }
    }
  }
  return $action
}

function Read-MapleEngineBuildInfo([string]$Executable, [string]$Directory) {
  [IO.Directory]::CreateDirectory($Directory) | Out-Null
  $info = [Diagnostics.ProcessStartInfo]::new((Resolve-Path -LiteralPath $Executable).Path, '--build-info')
  $info.WorkingDirectory = $Directory
  $info.UseShellExecute = $false; $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
  $info.Environment.Clear()
  foreach ($name in @('SystemRoot','SystemDrive','WINDIR','PATH','USERPROFILE','APPDATA')) {
    $value = [Environment]::GetEnvironmentVariable($name); if ($value) { $info.Environment[$name] = $value }
  }
  foreach ($name in @('LOCALAPPDATA','TEMP','TMP')) { $info.Environment[$name] = $Directory }
  $process = [Diagnostics.Process]::Start($info)
  try {
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(10000)) { $process.Kill($true); throw 'EXE build identity timed out.' }
    if ($process.ExitCode -ne 0) { throw 'Cannot read EXE build identity.' }
    return ($out.GetAwaiter().GetResult() | ConvertFrom-Json -ErrorAction Stop)
  } finally { $process.Dispose() }
}

# Only the public workflow has permission to create releases. The private build
# identity is recorded by the EXE; the release tag always targets a public commit.
function Publish-MapleEngineOnce([string]$Repository, [string]$Commit, [string]$Pair, [string]$Pin, [string]$CheckDirectory) {
  if ($Repository -cne $script:MapleEngineRepo -or $Commit -cnotmatch '^[0-9a-f]{40}$' -or $Pin -cnotmatch '^[0-9a-f]{64}$') { throw 'Engine publication identity is invalid.' }
  $release = Get-MapleEngineRelease
  if ($null -eq $release) {
    Read-MapleEnginePair $Pair $Pin | Out-Null
    $tagExists = & git ls-remote --tags origin "refs/tags/$script:MapleEngineTag"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot check the existing engine tag.' }
    if (!$tagExists) {
      & gh release create $script:MapleEngineTag "$Pair/maple-v8.dll" "$Pair/engine-manifest.json" --repo $script:MapleEngineRepo --target $Commit --title "V8 $script:MapleEngineId" --notes 'Shared Windows script engine for compatible Maple Helper builds.' --prerelease --latest=false
      # A concurrent publisher may have completed since the tag probe. Never retry a write.
    }
    $release = Get-MapleEngineRelease
    if ($null -eq $release) { throw 'Engine release is absent or incomplete; no existing tag or asset will be overwritten.' }
  }
  Receive-MapleEnginePair $CheckDirectory $release $Pin | Out-Null
}

function Invoke-MapleEngineSmoke([string]$Executable, [string]$Pair, [string]$Pin, [string]$LocalData) {
  Read-MapleEnginePair $Pair $Pin | Out-Null
  $cache = Join-Path $LocalData "MapleHelper/engines/$script:MapleEngineId"
  [IO.Directory]::CreateDirectory($cache) | Out-Null
  foreach ($name in $script:MapleEngineNames) { Copy-Item -LiteralPath (Join-Path $Pair $name) -Destination (Join-Path $cache $name) }
  $info = [Diagnostics.ProcessStartInfo]::new((Resolve-Path -LiteralPath $Executable).Path)
  $info.ArgumentList.Add('--verify-engine-cache')
  $info.ArgumentList.Add((Resolve-Path -LiteralPath $cache).Path)
  $info.UseShellExecute = $false; $info.CreateNoWindow = $true
  $info.WorkingDirectory = $LocalData
  $info.Environment.Clear()
  foreach ($name in @('SystemRoot','SystemDrive','WINDIR','PATH','COMPUTERNAME','USERDOMAIN','USERNAME','ProgramData','ProgramFiles','ProgramFiles(x86)','USERPROFILE','APPDATA')) {
    $value = [Environment]::GetEnvironmentVariable($name); if ($value) { $info.Environment[$name] = $value }
  }
  foreach ($name in @('LOCALAPPDATA','TEMP','TMP')) { $info.Environment[$name] = $LocalData }
  $process = [Diagnostics.Process]::Start($info)
  try {
    if (!$process.WaitForExit(60000)) { $process.Kill($true); throw 'Engine smoke test timed out.' }
    if ($process.ExitCode -ne 0) { throw "Verified-engine JS smoke failed (exit $($process.ExitCode))." }
  } finally { $process.Dispose() }
}

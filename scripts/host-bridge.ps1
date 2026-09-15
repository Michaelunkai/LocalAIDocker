[CmdletBinding()]
param(
    [int]$Port = 8765,
    [Parameter(Mandatory = $true)][string]$KeyPath,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
    throw "Host bridge key is missing: $KeyPath"
}
$BridgeKey = (Get-Content -LiteralPath $KeyPath -Raw -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($BridgeKey)) { throw 'Host bridge key is empty.' }

$ResolvedProjectRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ProjectRoot).Path).TrimEnd('\')
$ReadRoot = [IO.Path]::GetPathRoot($ResolvedProjectRoot)
$WriteRoot = $ResolvedProjectRoot
$ScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$MaxHeaderBytes = 64KB
$MaxBodyBytes = 20MB
$Listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'), $Port)

function Write-JsonAtomic {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function New-ConfirmationRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Risk,
        [Parameter(Mandatory = $true)]$Details
    )
    $confirmationId = 'confirmation-' + [guid]::NewGuid().ToString('N')
    $confirmationPath = Join-Path $ResolvedProjectRoot ('state\confirmations\' + $confirmationId + '.json')
    $record = [ordered]@{
        schema_version = 1
        confirmation_id = $confirmationId
        risk = $Risk
        operation = $Operation
        details = $Details
        user_confirmed = $true
        created_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-JsonAtomic $confirmationPath $record
    return [ordered]@{ confirmation_id = $confirmationId; path = $confirmationPath }
}

function Test-ContainedPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparseAncestors {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $current = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Reparse-point path components are rejected.'
            }
        }
        if ($current.TrimEnd('\').Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parentInfo = [IO.Directory]::GetParent($current)
        if ($null -eq $parentInfo) { break }
        $parent = $parentInfo.FullName
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $parent
    }
}

function Resolve-ReadPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) { throw 'A non-empty path is required.' }
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $ResolvedProjectRoot $Path }
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not (Test-ContainedPath $full $ReadRoot)) { throw 'The requested path is outside the configured read-only drive.' }
    if (-not (Test-Path -LiteralPath $full)) { throw "Path does not exist: $full" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    Assert-NoReparseAncestors -Path $full -Root $ReadRoot
    return $item
}

function Resolve-WritePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) { throw 'A non-empty path is required.' }
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $ResolvedProjectRoot $Path }
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not (Test-ContainedPath $full $WriteRoot)) { throw 'Writes are restricted to the LocalAIDocker project.' }
    $parent = Split-Path -Parent $full
    if (Test-Path -LiteralPath $parent) {
        $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse-point write targets are rejected.' }
    }
    if (Test-Path -LiteralPath $full) {
        $targetItem = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse-point replacement targets are rejected.' }
    }
    Assert-NoReparseAncestors -Path $full -Root $WriteRoot
    return $full
}

function Read-HttpRequest {
    param([Parameter(Mandatory = $true)][Net.Sockets.NetworkStream]$Stream)
    $headerBytes = New-Object Collections.Generic.List[byte]
    while ($headerBytes.Count -lt $MaxHeaderBytes) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { throw 'Client closed before sending a request.' }
        [void]$headerBytes.Add([byte]$value)
        if ($headerBytes.Count -ge 4 -and
            $headerBytes[$headerBytes.Count - 4] -eq 13 -and
            $headerBytes[$headerBytes.Count - 3] -eq 10 -and
            $headerBytes[$headerBytes.Count - 2] -eq 13 -and
            $headerBytes[$headerBytes.Count - 1] -eq 10) { break }
    }
    if ($headerBytes.Count -ge $MaxHeaderBytes) { throw 'HTTP headers exceed the limit.' }
    $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = $headerText -split "\r\n"
    $requestLine = $lines[0] -split ' ', 3
    if ($requestLine.Count -ne 3) { throw 'Malformed request line.' }
    $headers = @{}
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $separator = $line.IndexOf(':')
        if ($separator -le 0) { throw 'Malformed HTTP header.' }
        $headers[$line.Substring(0, $separator).Trim().ToLowerInvariant()] = $line.Substring($separator + 1).Trim()
    }
    $contentLength = 0
    if ($headers.ContainsKey('content-length')) {
        if (-not [int]::TryParse($headers['content-length'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$contentLength)) { throw 'Invalid content length.' }
    }
    if ($contentLength -lt 0 -or $contentLength -gt $MaxBodyBytes) { throw 'HTTP body exceeds the limit.' }
    $body = New-Object byte[] $contentLength
    $offset = 0
    while ($offset -lt $contentLength) {
        $read = $Stream.Read($body, $offset, $contentLength - $offset)
        if ($read -le 0) { throw 'Client closed before sending the complete body.' }
        $offset += $read
    }
    [pscustomobject]@{
        Method = $requestLine[0].ToUpperInvariant()
        Path = ($requestLine[1] -split '\?', 2)[0]
        Headers = $headers
        Body = if ($contentLength) { [Text.Encoding]::UTF8.GetString($body) } else { '' }
    }
}

function Send-HttpResponse {
    param(
        [Parameter(Mandatory = $true)][Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory = $true)][int]$Status,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)]$Payload
    )
    $body = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 20 -Compress) + "`n")
    $header = "HTTP/1.1 $Status $Reason`r`nContent-Type: application/json; charset=utf-8`r`nCache-Control: no-store`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Read-JsonBody {
    param([Parameter(Mandatory = $true)]$Request)
    if ([string]::IsNullOrWhiteSpace($Request.Body)) { throw 'JSON request body is required.' }
    return $Request.Body | ConvertFrom-Json
}

function Assert-Authorized {
    param([Parameter(Mandatory = $true)]$Request)
    $supplied = if ($Request.Headers.ContainsKey('authorization')) { [string]$Request.Headers['authorization'] } else { '' }
    if (-not $supplied.Equals(('Bearer ' + $BridgeKey), [StringComparison]::Ordinal)) {
        throw [UnauthorizedAccessException]::new('authentication required')
    }
}

function Get-FolderListing {
    param([Parameter(Mandatory = $true)]$Payload)
    $item = Resolve-ReadPath ([string]$Payload.path)
    if (-not $item.PSIsContainer) { throw 'The requested path is not a directory.' }
    $recursive = [bool]$Payload.recursive
    $maxItems = 50000
    if ($Payload.PSObject.Properties.Name -contains 'max_items' -and $null -ne $Payload.max_items) { $maxItems = [Math]::Min(1000000, [Math]::Max(1, [int]$Payload.max_items)) }
    $maxSeconds = 90
    if ($Payload.PSObject.Properties.Name -contains 'max_seconds' -and $null -ne $Payload.max_seconds) { $maxSeconds = [Math]::Min(300, [Math]::Max(5, [int]$Payload.max_seconds)) }
    $deadline = (Get-Date).AddSeconds($maxSeconds)
    $folders = New-Object Collections.Generic.List[object]
    $errors = New-Object Collections.Generic.List[string]
    $queue = New-Object Collections.Generic.Queue[string]
    $timedOut = $false
    $folderCount = [int64]0
    $displayLimit = 2000
    $evidencePath = $null
    $temporaryEvidence = $null
    $evidenceWriter = $null
    if ($recursive) {
        $evidenceDirectory = Join-Path $ResolvedProjectRoot 'evidence'
        New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
        $fileName = 'filesystem-scan-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N') + '.txt'
        $evidencePath = Join-Path $evidenceDirectory $fileName
        $temporaryEvidence = $evidencePath + '.tmp'
        $utf8 = New-Object Text.UTF8Encoding($false)
        $evidenceWriter = New-Object -TypeName IO.StreamWriter -ArgumentList @($temporaryEvidence, $false, $utf8)
    }
    $queue.Enqueue($item.FullName)
    while ($queue.Count -gt 0 -and $folderCount -lt $maxItems -and (Get-Date) -lt $deadline) {
        $directory = $queue.Dequeue()
        try { $children = [IO.Directory]::EnumerateDirectories($directory, '*', [IO.SearchOption]::TopDirectoryOnly) }
        catch { [void]$errors.Add(('{0}: {1}' -f $directory, $_.Exception.Message)); continue }
        foreach ($childPath in $children) {
            if ((Get-Date) -ge $deadline) { $timedOut = $true; break }
            try { $attributes = [IO.File]::GetAttributes($childPath) } catch { [void]$errors.Add(('{0}: {1}' -f $childPath, $_.Exception.Message)); continue }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $childName = [IO.Path]::GetFileName($childPath.TrimEnd('\'))
            $entry = [ordered]@{ path = $childPath; name = $childName; parent = $directory }
            $folderCount++
            if ($folders.Count -lt $displayLimit) { [void]$folders.Add($entry) }
            if ($null -ne $evidenceWriter) { $evidenceWriter.WriteLine($childPath) }
            if ($recursive -and $folderCount -lt $maxItems) { $queue.Enqueue($childPath) }
            if ($folderCount -ge $maxItems) { break }
        }
        if (-not $recursive) { break }
    }
    if ($null -ne $evidenceWriter) {
        $evidenceWriter.Flush()
        $evidenceWriter.Dispose()
        $evidenceWriter = $null
        if ($folderCount -gt $displayLimit) {
            Move-Item -LiteralPath $temporaryEvidence -Destination $evidencePath -Force
        } else {
            Remove-Item -LiteralPath $temporaryEvidence -Force -ErrorAction SilentlyContinue
            $evidencePath = $null
        }
    }
    [ordered]@{
        status = 'verified'
        operation = 'list_directories'
        root = $item.FullName
        recursive = $recursive
        folders = $folders.ToArray()
        count = $folderCount
        truncated = ($timedOut -or $queue.Count -gt 0 -or $folderCount -ge $maxItems)
        display_truncated = ($folderCount -gt $displayLimit)
        evidence_path = $evidencePath
        deadline_seconds = $maxSeconds
        timed_out = $timedOut
        errors = @($errors.ToArray() | Select-Object -First 200)
    }
}

function Get-FileText {
    param([Parameter(Mandatory = $true)]$Payload)
    $item = Resolve-ReadPath ([string]$Payload.path)
    if ($item.PSIsContainer) { throw 'The requested path is a directory.' }
    $maxBytes = 4MB
    if ($Payload.PSObject.Properties.Name -contains 'max_bytes' -and $null -ne $Payload.max_bytes) { $maxBytes = [Math]::Min(16MB, [Math]::Max(1KB, [int]$Payload.max_bytes)) }
    if ($item.Length -gt $maxBytes) { throw "File exceeds the read limit of $maxBytes bytes." }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    [ordered]@{ status = 'verified'; operation = 'read_file'; path = $item.FullName; bytes = $bytes.Length; text = [Text.Encoding]::UTF8.GetString($bytes) }
}

function Set-ProjectFile {
    param([Parameter(Mandatory = $true)]$Payload)
    $target = Resolve-WritePath ([string]$Payload.path)
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = $null
    $confirmation = New-ConfirmationRecord -Operation 'write_file' -Risk 'high' -Details ([ordered]@{ path = $target; bytes = ([Text.Encoding]::UTF8.GetBytes([string]$Payload.content)).Length })
    try {
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $backup = $target + '.bak.' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
            Copy-Item -LiteralPath $target -Destination $backup -Force
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Payload.content)
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Move-Item -LiteralPath $temporary -Destination $target -Force
        [ordered]@{ status = 'verified'; operation = 'write_file'; path = $target; bytes = $bytes.Length; backup = $backup; confirmation_id = $confirmation.confirmation_id }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ChromeExecutable {
    $candidates = New-Object Collections.Generic.List[string]
    foreach ($candidate in @(
            (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
        )) {
        if ($candidate -and -not $candidates.Contains($candidate)) { [void]$candidates.Add($candidate) }
    }
    foreach ($registryPath in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
        )) {
        try {
            $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            $registered = [string]$properties.'(default)'
            if ($registered -and -not $candidates.Contains($registered)) { [void]$candidates.Add($registered) }
        } catch { }
    }
    foreach ($registryPath in @(
            'HKCU:\Software\Classes\Applications\chrome.exe\shell\open\command',
            'HKLM:\Software\Classes\Applications\chrome.exe\shell\open\command'
        )) {
        try {
            $command = [string](Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop).'(default)'
            $match = [regex]::Match($command, '^\s*"([^"]+\.exe)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $match.Success) { $match = [regex]::Match($command, '^\s*([^\s]+\.exe)', [Text.RegularExpressions.RegexOptions]::IgnoreCase) }
            if ($match.Success -and -not $candidates.Contains($match.Groups[1].Value)) { [void]$candidates.Add($match.Groups[1].Value) }
        } catch { }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'Google Chrome executable was not found in known user or machine installation locations.'
}

function Open-DefaultChrome {
    param([Parameter(Mandatory = $true)]$Payload)
    $rawUrl = [string]$Payload.url
    if ([string]::IsNullOrWhiteSpace($rawUrl) -or $rawUrl.Length -gt 4096) { throw 'A bounded browser URL is required.' }
    $uri = $null
    if (-not [Uri]::TryCreate($rawUrl, [UriKind]::Absolute, [ref]$uri)) { throw 'Browser URL must be absolute.' }
    if ($uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrWhiteSpace($uri.Host) -or $uri.UserInfo) { throw 'Only credential-free HTTP(S) browser URLs are allowed.' }
    $chrome = Get-ChromeExecutable
    $newTab = $true
    if ($Payload.PSObject.Properties.Name -contains 'new_tab' -and $null -ne $Payload.new_tab) { $newTab = [bool]$Payload.new_tab }
    $arguments = if ($newTab) { @('--new-tab', $uri.AbsoluteUri) } else { @($uri.AbsoluteUri) }
    $process = Start-Process -FilePath $chrome -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $chrome) -PassThru -ErrorAction Stop
    $confirmation = New-ConfirmationRecord -Operation 'open_default_chrome' -Risk 'external-effect' -Details ([ordered]@{ url = $uri.AbsoluteUri; browser = 'chrome'; new_tab = $newTab; process_id = $process.Id })
    [ordered]@{
        status = 'opened-requested'
        operation = 'open_default_chrome'
        browser = 'chrome'
        url = $uri.AbsoluteUri
        new_tab = $newTab
        process_id = $process.Id
        observed = $false
        controlled = $false
        confirmation_id = $confirmation.confirmation_id
    }
}

function Invoke-Request {
    param([Parameter(Mandatory = $true)]$Request)
    if ($Request.Path -eq '/health' -and $Request.Method -eq 'GET') {
        Assert-Authorized $Request
        return [ordered]@{ status = 'host-bridge-ready'; pid = $PID; port = $Port; script_sha256 = $ScriptSha256; read_root = $ReadRoot; write_root = $WriteRoot }
    }
    Assert-Authorized $Request
    $payload = Read-JsonBody $Request
    switch ($Request.Path) {
        '/v1/files/list' { if ($Request.Method -ne 'POST') { throw 'POST required.' }; return Get-FolderListing -Payload $payload }
        '/v1/files/read' { if ($Request.Method -ne 'POST') { throw 'POST required.' }; return Get-FileText -Payload $payload }
        '/v1/files/write' { if ($Request.Method -ne 'POST') { throw 'POST required.' }; return Set-ProjectFile -Payload $payload }
        '/v1/browser/open' { if ($Request.Method -ne 'POST') { throw 'POST required.' }; return Open-DefaultChrome -Payload $payload }
        '/v1/process/list' {
            if ($Request.Method -ne 'POST') { throw 'POST required.' }
            # Name and Id are available for protected processes where CPU/path
            # properties may throw. Keep the snapshot useful instead of
            # turning one inaccessible process into a failed whole request.
            $processes = @(Get-Process | Select-Object -First 200 Name, Id)
            return [ordered]@{ status = 'verified'; operation = 'list_processes'; processes = $processes; count = $processes.Count }
        }
        default { throw 'route not found' }
    }
}

$Listener.Start()
Write-JsonAtomic $StatePath ([ordered]@{
    schema_version = 1
    status = 'running'
    pid = $PID
    port = $Port
    script_sha256 = $ScriptSha256
    read_root = $ReadRoot
    write_root = $WriteRoot
    started_at = (Get-Date).ToUniversalTime().ToString('o')
})
try {
    while ($true) {
        $client = $Listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            try {
                try {
                    $request = Read-HttpRequest $stream
                    $result = Invoke-Request $request
                    Send-HttpResponse $stream 200 'OK' $result
                } catch [UnauthorizedAccessException] {
                    Send-HttpResponse $stream 401 'Unauthorized' ([ordered]@{ error = $_.Exception.Message })
                } catch {
                    $message = $_.Exception.Message
                    $status = if ($message -eq 'route not found') { 404 } else { 400 }
                    Send-HttpResponse $stream $status 'Request Failed' ([ordered]@{ error = $message; detail = $_.Exception.ToString(); location = $_.InvocationInfo.PositionMessage })
                }
            } finally { $stream.Dispose() }
        } finally { $client.Dispose() }
    }
} finally {
    $Listener.Stop()
    if (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue }
}

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Check,
    [switch]$Doctor,
    [switch]$Json,
    [switch]$Install,
    [switch]$Launch,
    [switch]$Repair,
    [switch]$Models,
    [switch]$Benchmark,
    [ValidateSet('hyperv-cpu', 'native-linux-gpu')]
    [string]$Backend,
    [ValidateSet('fast', 'balanced', 'quality', 'coding', 'vision')]
    [string]$Profile = 'fast',
    [string[]]$Pack = @('core'),
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Task
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ConfigRoot = Join-Path $ProjectRoot 'config'
$StateRoot = Join-Path $ProjectRoot 'state'
$DataRoot = Join-Path $ProjectRoot 'data'
$InstalledPacksPath = Join-Path $StateRoot 'installed-packs.json'
$RuntimeEnv = Join-Path $ProjectRoot '.env.runtime'
$SecretPath = Join-Path $ProjectRoot 'secrets\localai-api-key'
$HostBridgeKeyPath = Join-Path $ProjectRoot 'secrets\host-bridge-key'
$BrowserSecretPath = Join-Path $ProjectRoot 'secrets\browser-api-key'
$HostBridgeScript = Join-Path $ProjectRoot 'scripts\host-bridge.ps1'
$HostBridgeStatePath = Join-Path $StateRoot 'host-bridge.json'
$HostBridgePort = 8765
$ComposeProject = 'localaidocker'
$Exit = @{
    Success = 0; Invalid = 2; Engine = 10; NotReady = 11; Install = 12
    Backend = 13; Model = 14; Server = 15; Pack = 16; Provenance = 17
    Interrupted = 18; External = 19
}
$RunClock = [Diagnostics.Stopwatch]::StartNew()
$HostBridgeAvailable = $false

$KnownPacks = @('core', 'gpu', 'coding', 'media', 'documents', 'browser', 'research', 'containers', 'harness')
$Pack = @($Pack | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
$unsupportedPacks = @($Pack | Where-Object { $KnownPacks -notcontains $_ })
if ($Pack.Count -eq 0 -or $unsupportedPacks.Count -gt 0) {
    $invalidPackText = if ($unsupportedPacks.Count -gt 0) { $unsupportedPacks -join ', ' } else { '<empty>' }
    [Console]::Error.WriteLine('Unsupported pack name(s): ' + $invalidPackText)
    exit $Exit.Invalid
}

function Get-InstalledPacks {
    $packs = @('core')
    if (Test-Path -LiteralPath $InstalledPacksPath -PathType Leaf) {
        try {
            $record = Read-JsonFile $InstalledPacksPath
            if ($record.packs) { $packs = @($record.packs | ForEach-Object { [string]$_ }) }
        } catch { $packs = @('core') }
    }
    $valid = @($packs | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $KnownPacks -contains $_ } | Select-Object -Unique)
    if ($valid -notcontains 'core') { $valid = @('core') + $valid }
    return $valid
}

function Save-InstalledPacks {
    param([Parameter(Mandatory = $true)][string[]]$Packs)
    $normalized = @($Packs | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $KnownPacks -contains $_ } | Select-Object -Unique)
    if ($normalized -notcontains 'core') { $normalized = @('core') + $normalized }
    Write-AtomicText $InstalledPacksPath (([ordered]@{ schema_version = 1; packs = $normalized; updated_at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Depth 8))
}

function Write-RunProgress {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = ('[+{0:000000}ms] {1}' -f [int]$RunClock.Elapsed.TotalMilliseconds, $Message)
    if ($Json) { [Console]::Error.WriteLine($line) } else { [Console]::Out.WriteLine($line) }
}

function Get-DockerExecutable {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($commandName in @('docker.exe', 'docker')) {
        $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command -and $command.Source -and -not $candidates.Contains([string]$command.Source)) {
            [void]$candidates.Add([string]$command.Source)
        }
    }
    foreach ($candidate in @(
            (Join-Path ${env:ProgramFiles} 'Docker\Docker\resources\bin\docker.exe'),
            (Join-Path ${env:ProgramFiles} 'Docker\Docker\resources\bin\com.docker.cli.exe'),
            (Join-Path ${env:LOCALAPPDATA} 'Docker\wsl\docker.exe')
        )) {
        if ($candidate -and -not $candidates.Contains($candidate)) { [void]$candidates.Add($candidate) }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'Docker CLI executable was not found. Install Docker Desktop or Docker Engine, then rerun this command.'
}

function Invoke-Docker {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $docker = Get-DockerExecutable
    $previousErrorAction = $ErrorActionPreference
    $previousDockerTimeout = $env:DOCKER_CLIENT_TIMEOUT
    $previousComposeTimeout = $env:COMPOSE_HTTP_TIMEOUT
    $ErrorActionPreference = 'Continue'
    $env:DOCKER_CLIENT_TIMEOUT = '10'
    $env:COMPOSE_HTTP_TIMEOUT = '10'
    $job = $null
    try {
        $argumentJson = @($Arguments) | ConvertTo-Json -Compress
        $job = Start-Job -ScriptBlock {
            param([string]$Executable, [string]$ArgumentJson)
            $parsedArguments = ConvertFrom-Json -InputObject $ArgumentJson
            $Argv = New-Object string[] ([int]$parsedArguments.Count)
            for ($index = 0; $index -lt $parsedArguments.Count; $index++) {
                $Argv[$index] = [string]$parsedArguments[$index]
            }
            $lines = @(& $Executable @Argv 2>&1)
            [pscustomobject]@{ Output = ($lines -join "`n"); ExitCode = $LASTEXITCODE }
        } -ArgumentList $docker, $argumentJson
        $finished = Wait-Job -Job $job -Timeout ([Math]::Max(1, $TimeoutSeconds))
        if ($null -eq $finished) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
            return [pscustomobject]@{ Output = "Docker command timed out after $TimeoutSeconds seconds."; ExitCode = 124 }
        }
        $result = Receive-Job -Job $job | Select-Object -Last 1
        if ($null -eq $result) { return [pscustomobject]@{ Output = 'Docker command returned no result.'; ExitCode = 125 } }
        $output = [string]$result.Output
        $code = [int]$result.ExitCode
    }
    catch {
        return [pscustomobject]@{ Output = $_.Exception.Message; ExitCode = 125 }
    }
    finally {
        if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null }
        $ErrorActionPreference = $previousErrorAction
        if ($null -eq $previousDockerTimeout) { Remove-Item Env:DOCKER_CLIENT_TIMEOUT -ErrorAction SilentlyContinue } else { $env:DOCKER_CLIENT_TIMEOUT = $previousDockerTimeout }
        if ($null -eq $previousComposeTimeout) { Remove-Item Env:COMPOSE_HTTP_TIMEOUT -ErrorAction SilentlyContinue } else { $env:COMPOSE_HTTP_TIMEOUT = $previousComposeTimeout }
    }
    [pscustomobject]@{ Output = ($output -join "`n"); ExitCode = $code }
}

function ConvertTo-NativeProcessArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append([char]34)
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $slashes++
            continue
        }
        if ($character -eq [char]34) {
            if ($slashes -gt 0) { [void]$builder.Append([char]92, ($slashes * 2)) }
            [void]$builder.Append([char]92)
            [void]$builder.Append([char]34)
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append([char]92, $slashes); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append([char]92, ($slashes * 2)) }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Invoke-DockerLive {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Stage,
        [int]$TimeoutSeconds = 1800
    )
    $docker = Get-DockerExecutable
    $lines = New-Object System.Collections.Generic.List[string]
    $lastPrintedLine = ''
    $lastPrintedAt = -1000
    $lastHeartbeatAt = 0
    $ansiPattern = ([string][char]27) + '\\[[0-?]*[ -/]*[@-~]'
    $stateDirectory = Join-Path $ProjectRoot 'state'
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $runId = [guid]::NewGuid().ToString('N')
    $capturePath = Join-Path $ProjectRoot ('logs\.docker-' + $runId + '.log')
    $process = $null
    $stdoutQueue = New-Object Collections.Concurrent.ConcurrentQueue[string]
    $stderrQueue = New-Object Collections.Concurrent.ConcurrentQueue[string]
    $stdoutSubscription = $null
    $stderrSubscription = $null
    $code = 125
    Write-RunProgress "$Stage started timeout_seconds=$TimeoutSeconds"
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $docker
        $startInfo.WorkingDirectory = $ProjectRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
        if ($null -ne $argumentListProperty) {
            foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
        } else {
            $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeProcessArgument ([string]$_) }) -join ' ')
        }
        $startInfo.EnvironmentVariables['DOCKER_CLIENT_TIMEOUT'] = '10'
        $startInfo.EnvironmentVariables['COMPOSE_HTTP_TIMEOUT'] = '10'
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Docker process could not be started.' }
        $stdoutSource = 'LocalAIDocker.' + $runId + '.stdout'
        $stderrSource = 'LocalAIDocker.' + $runId + '.stderr'
        $stdoutSubscription = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -SourceIdentifier $stdoutSource -MessageData $stdoutQueue -Action {
            if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.Enqueue([string]$EventArgs.Data) }
        }
        $stderrSubscription = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -SourceIdentifier $stderrSource -MessageData $stderrQueue -Action {
            if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.Enqueue([string]$EventArgs.Data) }
        }
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        $started = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited) {
            $emitted = $false
            $line = ''
            while ($stdoutQueue.TryDequeue([ref]$line)) {
                $line = [regex]::Replace([string]$line, $ansiPattern, '') -replace "`r", ''
                [void]$lines.Add($line)
                $emitted = $true
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $now = [int]$RunClock.Elapsed.TotalMilliseconds
                    $isTransferProgress = $line -match 'Downloading|Extracting'
                    if (-not $isTransferProgress -or (($now - $lastPrintedAt) -ge 500 -and $line -ne $lastPrintedLine)) {
                        Write-RunProgress "$Stage | $line"
                        $lastPrintedLine = $line
                        $lastPrintedAt = $now
                    }
                }
            }
            $line = ''
            while ($stderrQueue.TryDequeue([ref]$line)) {
                $line = [regex]::Replace([string]$line, $ansiPattern, '') -replace "`r", ''
                [void]$lines.Add($line)
                $emitted = $true
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $now = [int]$RunClock.Elapsed.TotalMilliseconds
                    $isTransferProgress = $line -match 'Downloading|Extracting'
                    if (-not $isTransferProgress -or (($now - $lastPrintedAt) -ge 500 -and $line -ne $lastPrintedLine)) {
                        Write-RunProgress "$Stage | $line"
                        $lastPrintedLine = $line
                        $lastPrintedAt = $now
                    }
                }
            }
            if (-not $emitted -and ([int]$RunClock.Elapsed.TotalMilliseconds - $lastHeartbeatAt) -ge 1000) {
                $lastHeartbeatAt = [int]$RunClock.Elapsed.TotalMilliseconds
                Write-RunProgress "$Stage waiting elapsed_ms=$lastHeartbeatAt"
            }
            if ($started.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-RunProgress "$Stage deadline exceeded elapsed_ms=$([int]$RunClock.Elapsed.TotalMilliseconds)"
                try { $process.Kill() } catch { }
                $code = 124
                break
            }
            Start-Sleep -Milliseconds 100
        }
        if ($code -ne 124) {
            $process.WaitForExit()
            Start-Sleep -Milliseconds 100
            $line = ''
            while ($stdoutQueue.TryDequeue([ref]$line)) {
                $line = [regex]::Replace([string]$line, $ansiPattern, '') -replace "`r", ''
                [void]$lines.Add($line)
                if (-not [string]::IsNullOrWhiteSpace($line)) { Write-RunProgress "$Stage | $line" }
            }
            $line = ''
            while ($stderrQueue.TryDequeue([ref]$line)) {
                $line = [regex]::Replace([string]$line, $ansiPattern, '') -replace "`r", ''
                [void]$lines.Add($line)
                if (-not [string]::IsNullOrWhiteSpace($line)) { Write-RunProgress "$Stage | $line" }
            }
            $code = $process.ExitCode
        } else {
            try { $process.WaitForExit(5000) } catch { }
        }
    } catch {
        [void]$lines.Add($_.Exception.Message)
        Write-RunProgress "$Stage error=$($_.Exception.Message)"
    } finally {
        foreach ($subscription in @($stdoutSubscription, $stderrSubscription)) {
            if ($null -ne $subscription) {
                # Windows PowerShell 5.1 returns a PSEventJob whose
                # SourceIdentifier property is empty; the registered source
                # is held in Name.  Prefer the former when available, then
                # fall back to the latter so repeated Docker invocations do
                # not leak event subscribers/jobs into the caller's session.
                $eventSource = [string]$subscription.SourceIdentifier
                if ([string]::IsNullOrWhiteSpace($eventSource)) { $eventSource = [string]$subscription.Name }
                if (-not [string]::IsNullOrWhiteSpace($eventSource)) {
                    try { Unregister-Event -SourceIdentifier $eventSource -ErrorAction SilentlyContinue } catch { }
                    try { Get-Job -Name $eventSource -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
        }
        try {
            if ($lines.Count -gt 0) { Write-AtomicText $capturePath ($lines -join "`n") }
        } catch { }
        if ($null -ne $process) { $process.Dispose() }
    }
    Write-RunProgress "$Stage finished exit=$code"
    [pscustomobject]@{ Output = ($lines -join "`n"); ExitCode = $code }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-AtomicText {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-BackendName {
    if ($Backend) { return $Backend }
    $current = Join-Path $StateRoot 'current-deployment.json'
    if (Test-Path -LiteralPath $current -PathType Leaf) {
        try { return [string](Read-JsonFile $current).backend } catch { }
    }
    if ($env:LOCALAI_BACKEND) { return $env:LOCALAI_BACKEND }
    return 'hyperv-cpu'
}

function Test-DockerEngine {
    Write-RunProgress 'Docker daemon probe started timeout=10s'
    try {
        $result = Invoke-Docker @('info', '--format', '{{json .}}')
    } catch {
        Write-RunProgress 'Docker daemon probe finished ready=false cli-missing'
        return [pscustomobject]@{ Ready = $false; Code = $Exit.Engine; Reason = $_.Exception.Message; Raw = '' }
    }
    if ($result.ExitCode -ne 0) {
        Write-RunProgress 'Docker daemon probe finished ready=false'
        $detail = ([string]$result.Output).Trim()
        $reason = if ($detail -match 'pipe/docker_engine|daemon is not running|cannot connect') {
            'Docker CLI is installed but the Docker daemon is not running. The project does not start Docker Desktop or switch contexts automatically.'
        } else {
            'Docker daemon is unavailable.'
        }
        return [pscustomobject]@{ Ready = $false; Code = $Exit.Engine; Reason = $reason; Raw = $detail }
    }
    try { $info = $result.Output | ConvertFrom-Json } catch {
        Write-RunProgress 'Docker daemon probe finished ready=false invalid-info'
        return [pscustomobject]@{ Ready = $false; Code = $Exit.Engine; Reason = 'Docker returned invalid info.'; Raw = $result.Output }
    }
    Write-RunProgress "Docker daemon probe finished ready=true os=$($info.OSType)"
    [pscustomobject]@{ Ready = $true; Reason = 'Docker daemon is reachable.'; Info = $info; Raw = $result.Output }
}

function Test-Backend {
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$ProbeGpu)
    $engine = Test-DockerEngine
    if (-not $engine.Ready) { return [pscustomobject]@{ Ready = $false; Code = $Exit.Engine; Reason = $engine.Reason; Engine = $engine } }
    $context = (Invoke-Docker @('context', 'show')).Output.Trim()
    if ($Name -eq 'native-linux-gpu') {
        if ([string]$engine.Info.OSType -ne 'linux') { return [pscustomobject]@{ Ready = $false; Code = $Exit.Backend; Reason = 'GPU backend requires a Linux Docker daemon.'; Context = $context } }
        if (-not $ProbeGpu) {
            # Read-only checks may inspect the daemon/context only.  Starting
            # a probe container can pull an image and mutate Docker state, so
            # the actual NVIDIA passthrough test is reserved for explicit
            # installation or repair.
            return [pscustomobject]@{ Ready = $true; Code = 0; Backend = $Name; Context = $context; Engine = $engine.Info; GPU = 'not-probed-read-only' }
        }
        $gpu = Invoke-Docker @('run', '--rm', '--gpus', 'all', 'nvidia/cuda:12.8.0-base-ubuntu24.04@sha256:e778509d37d66475120929671500377524f7278478ba08131b07ef3ffcc0dce0', 'nvidia-smi', '--query-gpu=name,memory.total', '--format=csv,noheader')
        if ($gpu.ExitCode -ne 0) { return [pscustomobject]@{ Ready = $false; Code = $Exit.Backend; Reason = 'NVIDIA GPU passthrough failed in the selected Docker context.'; Context = $context; GPU = $gpu.Output } }
        return [pscustomobject]@{ Ready = $true; Code = 0; Backend = $Name; Context = $context; Engine = $engine.Info; GPU = $gpu.Output; GpuProbe = 'verified' }
    }
    if ($Name -ne 'hyperv-cpu') { return [pscustomobject]@{ Ready = $false; Code = $Exit.Backend; Reason = "Unsupported backend: $Name"; Context = $context } }
    if ($context -notmatch 'desktop-linux|default') { return [pscustomobject]@{ Ready = $false; Code = $Exit.Backend; Reason = "Unexpected local Docker context: $context"; Context = $context } }
    $proof = $false
    $proofSource = 'environment'
    $backendSettingKnown = $false
    $wslBackendDetected = $false
    $settings = @(
        (Join-Path $env:APPDATA 'Docker\settings-store.json'),
        (Join-Path $env:LOCALAPPDATA 'Docker\settings-store.json'),
        (Join-Path $env:PROGRAMDATA 'DockerDesktop\install-settings.json')
    )
    foreach ($settingsPath in $settings) {
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            try {
                $dockerSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
                $wslProperty = @($dockerSettings.PSObject.Properties | Where-Object { $_.Name -ieq 'WslEngineEnabled' }) | Select-Object -First 1
                if ($null -ne $wslProperty) {
                    $backendSettingKnown = $true
                    if ([bool]$wslProperty.Value) { $wslBackendDetected = $true }
                    else {
                        $proof = $true
                        $proofSource = $settingsPath
                    }
                }
            } catch { }
        }
    }
    if ($wslBackendDetected) {
        return [pscustomobject]@{ Ready = $false; Code = $Exit.Backend; Reason = 'Docker Desktop is configured with its WSL2 backend. This project will not use or switch that backend; select a verified Hyper-V backend or an explicit native Linux Docker context.'; Context = $context }
    }
    if (-not $proof -and -not $backendSettingKnown -and $env:LOCALAI_HYPERV_VERIFIED -eq '1') { $proof = $true }
    if (-not $proof) {
        return [pscustomobject]@{ Ready = $false; Code = $Exit.Backend; Reason = 'A non-WSL Docker Desktop backend is not proven. Select Hyper-V and set LOCALAI_HYPERV_VERIFIED=1, or provide a Docker Desktop settings record with WslEngineEnabled=false.'; Context = $context }
    }
    [pscustomobject]@{ Ready = $true; Code = 0; Backend = $Name; Context = $context; Engine = $engine.Info; BackendProof = $proofSource }
}

function Ensure-Secret {
    if (Test-Path -LiteralPath $SecretPath -PathType Leaf) {
        if ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $SecretPath -Raw))) { throw 'API key file is empty.' }
        return
    }
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    Write-AtomicText $SecretPath ([Convert]::ToBase64String($bytes))
}

function Ensure-HostBridgeSecret {
    if (Test-Path -LiteralPath $HostBridgeKeyPath -PathType Leaf) {
        if ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $HostBridgeKeyPath -Raw))) { throw 'Host bridge key file is empty.' }
        return
    }
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    Write-AtomicText $HostBridgeKeyPath ([Convert]::ToBase64String($bytes))
}

function Ensure-BrowserSecret {
    if (Test-Path -LiteralPath $BrowserSecretPath -PathType Leaf) {
        if ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $BrowserSecretPath -Raw))) { throw 'Browser API key file is empty.' }
        return
    }
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    Write-AtomicText $BrowserSecretPath ([Convert]::ToBase64String($bytes))
}

function Get-HostBridgeKey {
    if (-not (Test-Path -LiteralPath $HostBridgeKeyPath -PathType Leaf)) { return '' }
    return (Get-Content -LiteralPath $HostBridgeKeyPath -Raw -Encoding UTF8).Trim()
}

function Test-HostBridge {
    $key = Get-HostBridgeKey
    if ([string]::IsNullOrWhiteSpace($key)) {
        return [pscustomobject]@{ Ready = $false; Reason = 'Host interoperability bridge key is not installed.' }
    }
    try {
        $headers = @{ Authorization = 'Bearer ' + $key }
        $health = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/health' -f $HostBridgePort) -Method Get -Headers $headers -TimeoutSec 3
        if ([string]$health.status -ne 'host-bridge-ready') { throw 'unexpected bridge status' }
        return [pscustomobject]@{ Ready = $true; Reason = 'Host interoperability bridge is ready.'; Health = $health }
    } catch {
        return [pscustomobject]@{ Ready = $false; Reason = $_.Exception.Message }
    }
}

function Stop-StaleHostBridge {
    if (-not (Test-Path -LiteralPath $HostBridgeStatePath -PathType Leaf)) { return }
    try {
        $record = Read-JsonFile $HostBridgeStatePath
        $bridgePid = [int]$record.pid
        if ($bridgePid -le 0) { return }
        $process = Get-Process -Id $bridgePid -ErrorAction SilentlyContinue
        if ($null -eq $process) { return }
        $commandLine = ''
        try {
            $processRecord = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $bridgePid) -ErrorAction SilentlyContinue
            $commandLine = [string]$processRecord.CommandLine
        } catch {
            try { $processRecord = Get-WmiObject Win32_Process -Filter ("ProcessId={0}" -f $bridgePid) -ErrorAction SilentlyContinue; $commandLine = [string]$processRecord.CommandLine } catch { }
        }
        if ($commandLine -and $commandLine.IndexOf($HostBridgeScript, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Start-HostBridge {
    Ensure-HostBridgeSecret
    $currentHash = (Get-FileHash -LiteralPath $HostBridgeScript -Algorithm SHA256).Hash.ToLowerInvariant()
    $existing = Test-HostBridge
    if ($existing.Ready) {
        $reportedHash = if ($existing.Health.PSObject.Properties.Name -contains 'script_sha256') { [string]$existing.Health.script_sha256 } else { '' }
        if ($reportedHash -eq $currentHash) {
            Write-RunProgress "host bridge ready port=$HostBridgePort reused=true"
            return $true
        }
        Write-RunProgress 'host bridge script changed; replacing the stale target-local bridge'
        Stop-StaleHostBridge
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $HostBridgeScript -PathType Leaf)) {
        Write-RunProgress 'host bridge unavailable script-missing'
        return $false
    }
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot 'logs') -Force | Out-Null
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $stdout = Join-Path $ProjectRoot 'logs\host-bridge.stdout.log'
    $stderr = Join-Path $ProjectRoot 'logs\host-bridge.stderr.log'
    $powershell = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
    Write-RunProgress "host bridge starting port=$HostBridgePort read_root=$([IO.Path]::GetPathRoot($ProjectRoot))"
    Start-Process -FilePath $powershell -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $HostBridgeScript,
        '-Port', [string]$HostBridgePort, '-KeyPath', $HostBridgeKeyPath,
        '-StatePath', $HostBridgeStatePath, '-ProjectRoot', $ProjectRoot
    ) -WorkingDirectory $ProjectRoot -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr | Out-Null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        Start-Sleep -Milliseconds 200
        $health = Test-HostBridge
        Write-RunProgress "host bridge health attempt=$attempt/30 ready=$($health.Ready)"
        if ($health.Ready) {
            $reportedHash = if ($health.Health.PSObject.Properties.Name -contains 'script_sha256') { [string]$health.Health.script_sha256 } else { '' }
            if ($reportedHash -eq $currentHash) {
                Write-RunProgress "host bridge ready port=$HostBridgePort"
                return $true
            }
            Write-RunProgress 'host bridge responded with a stale script hash; replacing it'
            Stop-StaleHostBridge
            Start-Sleep -Milliseconds 250
        }
    }
    Write-RunProgress 'host bridge failed to become ready'
    return $false
}

function Ensure-RuntimeEnv {
    param([string]$ModelId)
    Ensure-Secret
    if ((Get-InstalledPacks) -contains 'browser') { Ensure-BrowserSecret }
    $lock = Read-JsonFile (Join-Path $ConfigRoot 'runtime.lock.json')
    $cpu = "{0}@{1}" -f $lock.images.localai_cpu.source_ref, $lock.images.localai_cpu.digest
    $gpu = "{0}@{1}" -f $lock.images.localai_gpu.source_ref, $lock.images.localai_gpu.digest
    $base = "{0}@{1}" -f $lock.images.agent_base.source_ref, $lock.images.agent_base.digest
    $installed = @(Get-InstalledPacks)
    $agentPacks = ($installed -join ',')
    $buildPacks = @($installed | Where-Object { $_ -in @('coding', 'media', 'documents') }) -join ','
    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        $existingReceipt = Get-Receipt
        if ($existingReceipt -and $existingReceipt.model_id) { $ModelId = [string]$existingReceipt.model_id }
    }
    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        $modelLock = Read-JsonFile (Join-Path $ConfigRoot 'models.lock.json')
        $selected = @($modelLock.models | Where-Object { @($_.profiles) -contains $Profile } | Select-Object -First 1)
        if ($selected.Count -ne 1) { throw "No verified model fits profile '$Profile'." }
        $ModelId = [string]$selected[0].id
    }
    $lines = @(
        "LOCALAI_IMAGE=$cpu",
        "LOCALAI_CPU_IMAGE=$cpu",
        "LOCALAI_GPU_IMAGE=$gpu",
        "AGENT_BASE_IMAGE=$base",
        "AGENT_PACKS=$agentPacks",
        "INSTALL_PACKS=$buildPacks",
        "MODEL_ID=$ModelId",
        "MODEL_PROFILE=$Profile",
        "HOST_BRIDGE_AVAILABLE=$(if ($HostBridgeAvailable) { '1' } else { '0' })",
        "LOCALAI_API_KEY_FILE=./secrets/localai-api-key",
        "BROWSER_API_KEY_FILE=./secrets/browser-api-key"
    )
    Write-AtomicText $RuntimeEnv (($lines -join "`n") + "`n")
}

function Get-ComposeArguments {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path -LiteralPath $RuntimeEnv -PathType Leaf)) { throw 'Runtime environment is missing; run -Install explicitly.' }
    $files = @('compose.yaml')
    if ($Name -eq 'hyperv-cpu') { $files += 'compose.cpu.yaml' } else { $files += 'compose.gpu.yaml' }
    $packFiles = @{
        browser = 'compose.pack-browser.yaml'
        research = 'compose.pack-research.yaml'
    }
    foreach ($packName in Get-InstalledPacks) {
        if ($packFiles.ContainsKey($packName)) { $files += $packFiles[$packName] }
    }
    $arguments = @('compose', '--project-name', $ComposeProject, '--project-directory', $ProjectRoot, '--env-file', $RuntimeEnv)
    foreach ($file in $files) { $arguments += @('-f', (Join-Path $ProjectRoot $file)) }
    return $arguments
}

function Get-AppServices {
    $services = @('localai', 'gateway', 'agent')
    if ((Get-InstalledPacks) -contains 'browser') { $services += 'browser' }
    return $services
}

function Invoke-Compose {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string[]]$Command)
    Invoke-Docker ((Get-ComposeArguments $Name) + $Command)
}

function Invoke-ComposeLive {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Command,
        [Parameter(Mandatory = $true)][string]$Stage
    )
    Invoke-DockerLive ((Get-ComposeArguments $Name) + $Command) $Stage
}

function Get-ApiKey {
    if (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) { throw 'API key file is missing.' }
    return (Get-Content -LiteralPath $SecretPath -Raw -Encoding UTF8).Trim()
}

function Get-FileSha256WithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $total = [int64]$file.Length
    Write-RunProgress "$Label started bytes=$total"
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 4MB, [IO.FileOptions]::SequentialScan)
    $digest = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] (4MB)
    $readTotal = [int64]0
    $lastReportAt = [Diagnostics.Stopwatch]::GetTimestamp()
    $lastReportBytes = [int64]0
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$digest.TransformBlock($buffer, 0, $read, $buffer, 0)
            $readTotal += $read
            $now = [Diagnostics.Stopwatch]::GetTimestamp()
            $elapsedSeconds = ($now - $lastReportAt) / [Diagnostics.Stopwatch]::Frequency
            if ($readTotal -eq $total -or $readTotal - $lastReportBytes -ge (64MB) -or $elapsedSeconds -ge 1) {
                $percent = if ($total -gt 0) { ($readTotal / $total) * 100 } else { 100 }
                Write-RunProgress "$Label progress bytes=$readTotal total_bytes=$total percent=$('{0:N2}' -f $percent)"
                $lastReportAt = $now
                $lastReportBytes = $readTotal
            }
        }
        [void]$digest.TransformFinalBlock([byte[]]::new(0), 0, 0)
        $hash = ([BitConverter]::ToString($digest.Hash) -replace '-', '').ToLowerInvariant()
        Write-RunProgress "$Label finished sha256=$hash"
        return $hash
    } finally {
        $digest.Dispose()
        $stream.Dispose()
    }
}

function Invoke-Api {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Body, [switch]$Authenticated)
    $headers = @{}
    if ($Authenticated) { $headers.Authorization = 'Bearer ' + (Get-ApiKey) }
    $uri = 'http://127.0.0.1:8080' + $Path
    try {
        if ($Body) { return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body $Body -TimeoutSec 180 }
        return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 15
    } catch { return $null }
}

function Invoke-ApiLive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Body,
        [switch]$Authenticated,
        [string]$Label = 'API request',
        [int]$TimeoutSeconds = 180,
        [switch]$ExtraUsage
    )
    $headers = @{}
    if ($Authenticated) { $headers.Authorization = 'Bearer ' + (Get-ApiKey) }
    $uri = 'http://127.0.0.1:8080' + $Path
    $job = $null
    $started = [Diagnostics.Stopwatch]::StartNew()
    try {
        $job = Start-Job -ScriptBlock {
            param([string]$RequestUri, [string]$RequestBody, [string]$ApiKey, [bool]$IncludeExtraUsage)
            $requestHeaders = @{}
            if ($ApiKey) { $requestHeaders.Authorization = 'Bearer ' + $ApiKey }
            if ($IncludeExtraUsage) { $requestHeaders['Extra-Usage'] = 'true' }
            try {
                if ($RequestBody) {
                    Invoke-RestMethod -Uri $RequestUri -Method Post -Headers $requestHeaders -ContentType 'application/json' -Body $RequestBody -TimeoutSec 330
                } else {
                    Invoke-RestMethod -Uri $RequestUri -Method Get -Headers $requestHeaders -TimeoutSec 15
                }
            } catch { }
        } -ArgumentList $uri, $Body, $(if ($Authenticated) { Get-ApiKey } else { '' }), [bool]$ExtraUsage
        while ($job.State -eq 'Running' -and $started.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 500
            if ($started.ElapsedMilliseconds -ge 1000) {
                Write-RunProgress "$Label waiting elapsed_ms=$($started.ElapsedMilliseconds)"
            }
        }
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
            Write-RunProgress "$Label timed out elapsed_ms=$($started.ElapsedMilliseconds)"
            return $null
        }
        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($null -eq $result) { return $null }
        return $result
    } finally {
        $started.Stop()
        if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null }
    }
}

function Get-Receipt {
    $current = Join-Path $StateRoot 'current-deployment.json'
    if (-not (Test-Path -LiteralPath $current -PathType Leaf)) { return $null }
    try { return Read-JsonFile $current } catch { return $null }
}

function Wait-ForGateway {
    param([int]$Attempts = 60, [int]$DelaySeconds = 2)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Write-RunProgress "health check attempt=$attempt/$Attempts endpoint=http://127.0.0.1:8080/health"
        $health = Invoke-Api '/health'
        if ($null -ne $health) {
            Write-RunProgress 'gateway health=ready'
            return $health
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
    }
    Write-RunProgress 'gateway health=timeout'
    return $null
}

function Test-LocalImages {
    param([Parameter(Mandatory = $true)][string]$Name)
    $runtimeLock = Read-JsonFile (Join-Path $ConfigRoot 'runtime.lock.json')
    $localAi = if ($Name -eq 'native-linux-gpu') {
        "{0}@{1}" -f $runtimeLock.images.localai_gpu.source_ref, $runtimeLock.images.localai_gpu.digest
    } else {
        "{0}@{1}" -f $runtimeLock.images.localai_cpu.source_ref, $runtimeLock.images.localai_cpu.digest
    }
    $required = @($localAi, 'localaidocker/gateway:locked', 'localaidocker/agent:locked')
    if ((Get-InstalledPacks) -contains 'browser') { $required += 'localaidocker/browser:locked' }
    $imageIds = [ordered]@{}
    foreach ($image in $required) {
        Write-RunProgress "checking local image=$image"
        $format = if ($image -match '@sha256:') { '{{json .RepoDigests}}' } else { '{{.Id}}' }
        $inspect = Invoke-Docker @('image', 'inspect', $image, '--format', $format)
        if ($inspect.ExitCode -ne 0) {
            return [pscustomobject]@{ Ready = $false; Code = $Exit.NotReady; Reason = "Required image is not present locally: $image. Run -Install explicitly."; Missing = $image }
        }
        if ($image -match '@(sha256:[0-9a-f]{64})') {
            if ($inspect.Output -notmatch [regex]::Escape($Matches[1])) {
                return [pscustomobject]@{ Ready = $false; Code = $Exit.Provenance; Reason = "Image digest does not match the lock: $image"; Mismatch = $image }
            }
        }
        $imageIds[$image] = $inspect.Output.Trim()
    }
    [pscustomobject]@{ Ready = $true; Code = 0; Reason = 'All verified runtime images are present locally.'; Images = $imageIds }
}

function Test-EnabledPackServices {
    $installed = @(Get-InstalledPacks)
    if ($installed -notcontains 'browser') {
        return [pscustomobject]@{ Ready = $true; Code = 0; Reason = 'No service-backed optional pack is enabled.' }
    }
    Write-RunProgress 'browser pack service health probe started'
    $running = Invoke-Compose (Get-BackendName) @('ps', '--status', 'running', '--services', 'browser')
    if ($running.ExitCode -ne 0 -or $running.Output.Trim() -notmatch '(?m)^browser\s*$') {
        return [pscustomobject]@{ Ready = $false; Code = $Exit.Pack; Reason = 'The installed browser service is not running.'; Raw = $running.Output }
    }
    Write-RunProgress 'browser pack service health probe finished ready=true'
    return [pscustomobject]@{ Ready = $true; Code = 0; Reason = 'Enabled optional services are running.' }
}

function Start-Runtime {
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$ForceRecreate)
    # A normal invocation is deliberately a complete, project-owned rebuild
    # cycle. Install-Core performs the locked image/model checks, builds the
    # project images, recreates fresh containers, waits for health, runs an
    # authenticated smoke inference, and commits the verified receipt.
    return Install-Core -Name $Name -ForceRecreate -Operation 'runtime rebuild'
}

function Test-Ready {
    $name = Get-BackendName
    $backend = Test-Backend $name
    if (-not $backend.Ready) { return [pscustomobject]@{ Ready = $false; Code = $backend.Code; Reason = $backend.Reason; Backend = $name; Details = $backend } }
    $receipt = Get-Receipt
    if (-not $receipt) { return [pscustomobject]@{ Ready = $false; Code = $Exit.NotReady; Reason = 'No verified deployment receipt exists.'; Backend = $name } }
    if ([string]$receipt.backend -ne $name) { return [pscustomobject]@{ Ready = $false; Code = $Exit.Provenance; Reason = 'Deployment backend does not match the selected backend.'; Backend = $name } }
    $receiptProfile = if ($receipt.PSObject.Properties.Name -contains 'profile') { [string]$receipt.profile } else { '' }
    if ($receiptProfile -ne $Profile) { return [pscustomobject]@{ Ready = $false; Code = $Exit.NotReady; Reason = "Profile '$receiptProfile' is deployed; requested profile '$Profile' is not active."; Backend = $name; Receipt = $receipt } }
    $receiptAcceptance = if ($receipt.PSObject.Properties.Name -contains 'acceptance') { [string]$receipt.acceptance } else { '' }
    $hasBenchmark = $receipt.PSObject.Properties.Name -contains 'benchmark' -and $null -ne $receipt.benchmark
    if ($receiptAcceptance -ne 'core-inference-and-profile-benchmark-passed' -or -not $hasBenchmark) {
        return [pscustomobject]@{ Ready = $false; Code = $Exit.Provenance; Reason = 'Deployment receipt predates the current verified inference-and-profile benchmark contract. Run the normal launcher to rebuild it.'; Backend = $name; Receipt = $receipt }
    }
    if ($name -eq 'native-linux-gpu') {
        $gpuPackVerified = $receipt.PSObject.Properties.Name -contains 'packs' -and $null -ne $receipt.packs -and
            $receipt.packs.PSObject.Properties.Name -contains 'gpu' -and [string]$receipt.packs.gpu -eq 'verified'
        $gpuProofVerified = $receipt.PSObject.Properties.Name -contains 'backend_proof' -and [string]$receipt.backend_proof -eq 'nvidia-container-runtime-and-smi'
        if (-not $gpuPackVerified -or -not $gpuProofVerified) {
            return [pscustomobject]@{ Ready = $false; Code = $Exit.Backend; Reason = 'The deployment does not contain a verified NVIDIA container-runtime and GPU acceptance proof.'; Backend = $name; Receipt = $receipt }
        }
    }
    try {
        $runtimeLock = Read-JsonFile (Join-Path $ConfigRoot 'runtime.lock.json')
        $expectedImageDigest = if ($name -eq 'native-linux-gpu') { [string]$runtimeLock.images.localai_gpu.digest } else { [string]$runtimeLock.images.localai_cpu.digest }
        if ([string]$receipt.image_digest -ne $expectedImageDigest) { throw 'Deployment LocalAI image digest does not match the current runtime lock.' }
        $modelLock = Read-JsonFile (Join-Path $ConfigRoot 'models.lock.json')
        $model = @($modelLock.models | Where-Object id -eq $receipt.model_id | Select-Object -First 1)
        if ($model.Count -ne 1) { throw 'Receipt model is absent from the model lock.' }
        if (@($model[0].profiles | ForEach-Object { [string]$_ }) -notcontains $Profile) { throw "Receipt model is not verified for profile '$Profile'." }
        if ([string]$receipt.model_revision -ne [string]$model[0].revision) { throw 'Deployment model revision does not match the current model lock.' }
        $artifact = @($model[0].artifacts | Where-Object role -eq 'main' | Select-Object -First 1)
        $artifactPath = Join-Path $DataRoot ("models\$($receipt.model_id)\$($artifact[0].filename)")
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw 'Verified model artifact is missing.' }
        $artifactFile = Get-Item -LiteralPath $artifactPath
        if ([int64]$artifactFile.Length -ne [int64]$artifact[0].size_bytes) { throw 'Verified model artifact size changed.' }
        $artifactHash = Get-FileSha256WithProgress $artifactPath 'read-only model receipt verification'
        if ($artifactHash -ne [string]$artifact[0].sha256 -or $artifactHash -ne [string]$receipt.model_artifact_sha256) { throw 'Verified model artifact digest changed.' }
    } catch {
        return [pscustomobject]@{ Ready = $false; Code = $Exit.Provenance; Reason = $_.Exception.Message; Backend = $name; Receipt = $receipt }
    }
    $images = Test-LocalImages $name
    if (-not $images.Ready) { return [pscustomobject]@{ Ready = $false; Code = $images.Code; Reason = $images.Reason; Backend = $name; Details = $images } }
    $packServices = Test-EnabledPackServices
    if (-not $packServices.Ready) { return [pscustomobject]@{ Ready = $false; Code = $packServices.Code; Reason = $packServices.Reason; Backend = $name; Details = $packServices } }
    $compose = Invoke-Compose $name @('config', '--quiet')
    if ($compose.ExitCode -ne 0) { return [pscustomobject]@{ Ready = $false; Code = $Exit.Provenance; Reason = 'Compose configuration is invalid.'; Details = $compose.Output } }
    $health = Invoke-Api '/health'
    if ($null -eq $health) { return [pscustomobject]@{ Ready = $false; Code = $Exit.Server; Reason = 'Gateway health endpoint is unavailable.'; Backend = $name } }
    $bridge = Test-HostBridge
    $bridgeReason = if ($bridge.Ready) { 'Verified Docker runtime and host interoperability bridge are ready.' } else { 'Verified Docker runtime is ready; optional host interoperability is unavailable: ' + $bridge.Reason }
    [pscustomobject]@{ Ready = $true; Code = 0; Reason = $bridgeReason; Backend = $name; Receipt = $receipt; Health = $health; HostBridge = $bridge; HostBridgeAvailable = [bool]$bridge.Ready }
}

function Show-Status {
    param([Parameter(Mandatory = $true)]$Status)
    if ($Json) { [Console]::Out.WriteLine(($Status | ConvertTo-Json -Depth 12)); return }
    if ($Status.Ready) {
        $bridgeState = if ($Status.PSObject.Properties.Name -contains 'HostBridgeAvailable') { if ($Status.HostBridgeAvailable) { 'ready' } else { 'unavailable' } } else { 'unknown' }
        [Console]::Out.WriteLine("LOCALAI_DOCKER_READY backend=$($Status.Backend) host_bridge=$bridgeState")
    }
    else { [Console]::Error.WriteLine("LOCALAI_DOCKER_NOT_READY code=$($Status.Code) reason=$($Status.Reason)") }
}

function Install-Core {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$ForceRecreate,
        [string]$Operation = 'installation'
    )
    Write-RunProgress "$Operation started backend=$Name"
    $backend = Test-Backend $Name -ProbeGpu
    if (-not $backend.Ready) { Show-Status $backend; return $backend.Code }
    $modelLock = Read-JsonFile (Join-Path $ConfigRoot 'models.lock.json')
    $modelEntry = @($modelLock.models | Where-Object { @($_.profiles) -contains $Profile } | Select-Object -First 1)
    if ($modelEntry.Count -ne 1) {
        [Console]::Error.WriteLine("No verified model fits profile '$Profile'.")
        return $Exit.Model
    }
    $modelId = [string]$modelEntry[0].id
    if ($Name -ne 'native-linux-gpu') {
        $withoutGpu = @(Get-InstalledPacks | Where-Object { $_ -ne 'gpu' })
        if (@(Get-InstalledPacks) -contains 'gpu') { Save-InstalledPacks $withoutGpu }
    }
    try { $script:HostBridgeAvailable = [bool](Start-HostBridge) }
    catch {
        $script:HostBridgeAvailable = $false
        Write-RunProgress "optional host interoperability bridge failed: $($_.Exception.Message)"
    }
    if (-not $HostBridgeAvailable) { Write-RunProgress 'optional host interoperability bridge is unavailable; core interactive mode will continue' }
    Write-RunProgress 'creating target-local runtime credentials and environment'
    Ensure-RuntimeEnv -ModelId $modelId
    $config = Invoke-ComposeLive $Name @('config', '--quiet') 'Compose validation'
    if ($config.ExitCode -ne 0) { [Console]::Error.WriteLine($config.Output); return $Exit.Install }
    $pull = $null
    for ($pullAttempt = 1; $pullAttempt -le 2; $pullAttempt++) {
        $pull = Invoke-ComposeLive $Name @('pull', 'localai') ("LocalAI image pull attempt=$pullAttempt/2")
        if ($pull.ExitCode -eq 0) { break }
        if ($pullAttempt -lt 2) {
            Write-RunProgress 'LocalAI image pull transient failure; retrying once'
            Start-Sleep -Seconds 2
        }
    }
    if ($null -eq $pull -or $pull.ExitCode -ne 0) { [Console]::Error.WriteLine($pull.Output); return $Exit.Install }
    $buildServices = @('gateway', 'agent', 'model-manager')
    if ((Get-InstalledPacks) -contains 'browser') { $buildServices += 'browser' }
    $build = Invoke-ComposeLive $Name (@('--progress', 'plain', 'build', '--pull') + $buildServices) 'agent image build'
    if ($build.ExitCode -ne 0) { [Console]::Error.WriteLine($build.Output); return $Exit.Install }
    $images = Test-LocalImages $Name
    if (-not $images.Ready) { [Console]::Error.WriteLine($images.Reason); return $Exit.Provenance }
    $model = Invoke-ComposeLive $Name @('--profile', 'install', 'run', '--rm', 'model-manager') 'locked model and data verification'
    if ($model.ExitCode -ne 0) { [Console]::Error.WriteLine($model.Output); return $Exit.Model }
    # The selected model configuration is promoted immediately before this
    # step. Recreate every application container so a model/profile change can
    # never leave a healthy-looking server running the previous model.
    $upCommand = @('up', '-d', '--force-recreate')
    $upCommand += @('--pull', 'never', '--no-build') + (Get-AppServices)
    $up = Invoke-ComposeLive $Name $upCommand 'Docker application start and container recreation'
    if ($up.ExitCode -ne 0) { [Console]::Error.WriteLine($up.Output); return $Exit.Install }
    $ready = Wait-ForGateway
    if ($null -eq $ready) { [Console]::Error.WriteLine('Gateway did not become healthy.'); return $Exit.Server }
    $body = @{ model = $modelId; messages = @(@{ role = 'user'; content = 'Reply with exactly LOCALAI_CORE_OK.' }); temperature = 0; stream = $false } | ConvertTo-Json -Depth 8
    Write-RunProgress 'authenticated smoke inference started'
    $answer = Invoke-ApiLive '/v1/chat/completions' $body -Authenticated -Label 'authenticated core smoke inference'
    if ($null -eq $answer) { [Console]::Error.WriteLine('Authenticated core inference failed.'); return $Exit.Server }
    $visibleAnswer = ''
    try { $visibleAnswer = [string]$answer.choices[0].message.content } catch { }
    if ([string]::IsNullOrWhiteSpace($visibleAnswer) -or $visibleAnswer -notmatch 'LOCALAI_CORE_OK') {
        [Console]::Error.WriteLine('Authenticated inference returned no verified visible answer.')
        return $Exit.Server
    }
    Write-RunProgress 'authenticated smoke inference finished visible_answer=verified'
    $agentBody = @{ model = $modelId; message = 'Reply with exactly LOCALAI_AGENT_OK.'; task_id = ('smoke-' + [guid]::NewGuid().ToString('N')) } | ConvertTo-Json -Depth 8
    Write-RunProgress 'authenticated agent smoke task started'
    $agentAnswer = Invoke-ApiLive '/v1/task' $agentBody -Authenticated -Label 'authenticated agent smoke task'
    if ($null -eq $agentAnswer) { [Console]::Error.WriteLine('Authenticated agent task failed.'); return $Exit.Server }
    $agentText = Get-AssistantText $agentAnswer
    if ([string]::IsNullOrWhiteSpace($agentText) -or $agentText -notmatch 'LOCALAI_AGENT_OK') {
        [Console]::Error.WriteLine('Authenticated agent task returned no verified visible answer.')
        return $Exit.Server
    }
    Write-RunProgress 'authenticated agent smoke task finished visible_answer=verified'
    $benchmark = Invoke-ProfileBenchmark $modelId $Profile
    if (-not $benchmark.Passed) {
        [Console]::Error.WriteLine("Profile benchmark failed: $($benchmark.Reason)")
        return $Exit.Server
    }
    Write-RunProgress "profile benchmark finished profile=$Profile end_to_end_tokens_per_second=$($benchmark.end_to_end_completion_tokens_per_second) floor=$($benchmark.minimum_end_to_end_completion_tokens_per_second)"
    $modelLock = Read-JsonFile (Join-Path $ConfigRoot 'models.lock.json')
    $modelEntry = @($modelLock.models | Where-Object id -eq $modelId | Select-Object -First 1)
    if ($modelEntry.Count -ne 1) { [Console]::Error.WriteLine('The selected model is absent from the model lock.'); return $Exit.Provenance }
    $artifact = @($modelEntry[0].artifacts | Where-Object role -eq 'main' | Select-Object -First 1)
    $artifactPath = Join-Path $DataRoot ("models\$modelId\$($artifact[0].filename)")
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { [Console]::Error.WriteLine('The verified model artifact is missing.'); return $Exit.Model }
    $artifactHash = Get-FileSha256WithProgress $artifactPath 'Windows-side model hash verification'
    if ($artifactHash -ne [string]$artifact[0].sha256) { [Console]::Error.WriteLine('The model artifact hash changed after verification.'); return $Exit.Provenance }
    $runtimeLock = Read-JsonFile (Join-Path $ConfigRoot 'runtime.lock.json')
    $imageDigest = if ($Name -eq 'native-linux-gpu') { $runtimeLock.images.localai_gpu.digest } else { $runtimeLock.images.localai_cpu.digest }
    $backendProof = if ($backend.PSObject.Properties.Name -contains 'BackendProof') { [string]$backend.BackendProof } else { 'nvidia-container-runtime-and-smi' }
    $installedPacks = @(Get-InstalledPacks)
    $packs = [ordered]@{}
    foreach ($packName in $KnownPacks) {
        $packs[$packName] = if ($packName -eq 'core') { 'verified' } elseif ($packName -eq 'gpu') { if ($Name -eq 'native-linux-gpu') { 'verified' } else { 'not-installed' } } elseif ($installedPacks -contains $packName) { 'verified' } else { 'not-installed' }
    }
    $deployment = [ordered]@{
        schema_version = 1; deployment_id = ('deploy-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
        backend = $Name; model_id = $modelId; profile = $Profile; image_digest = $imageDigest
        image_ids = $images.Images
        docker_context = [string]$backend.Context; engine_os_type = [string]$backend.Engine.OSType; backend_proof = $backendProof
        model_revision = [string]$modelEntry[0].revision; model_artifact_sha256 = $artifactHash; model_artifact_size_bytes = [int64]$artifact[0].size_bytes
        packs = $packs; benchmark = $benchmark; created_at = (Get-Date).ToUniversalTime().ToString('o'); acceptance = 'core-inference-and-profile-benchmark-passed'
    }
    $receiptPath = Join-Path $DataRoot ('deployments\' + $deployment.deployment_id + '.json')
    $jsonText = $deployment | ConvertTo-Json -Depth 12
    Write-AtomicText $receiptPath $jsonText
    Write-AtomicText (Join-Path $StateRoot 'current-deployment.json') $jsonText
    $containerState = 'recreated'
    $bridgeState = if ($HostBridgeAvailable) { 'ready' } else { 'unavailable' }
    [Console]::Out.WriteLine("LOCALAI_DOCKER_READY backend=$Name host_bridge=$bridgeState app=running containers=$containerState deployment=$($deployment.deployment_id)")
    Write-RunProgress "$Operation finished with verified core inference and committed deployment"
    return 0
}

function Update-DeploymentPack {
    param([Parameter(Mandatory = $true)][string]$PackName, [Parameter(Mandatory = $true)][string]$Status)
    $receipt = Get-Receipt
    if ($null -eq $receipt) { return }
    if ($null -eq $receipt.packs) { $receipt | Add-Member -NotePropertyName packs -NotePropertyValue ([pscustomobject]@{}) }
    if ($receipt.packs.PSObject.Properties.Name -contains $PackName) { $receipt.packs.$PackName = $Status }
    else { $receipt.packs | Add-Member -NotePropertyName $PackName -NotePropertyValue $Status }
    $json = $receipt | ConvertTo-Json -Depth 20
    Write-AtomicText (Join-Path $StateRoot 'current-deployment.json') $json
    if ($receipt.deployment_id) {
        $deploymentPath = Join-Path $DataRoot ('deployments\' + [string]$receipt.deployment_id + '.json')
        if (Test-Path -LiteralPath $deploymentPath -PathType Leaf) { Write-AtomicText $deploymentPath $json }
    }
}

function Invoke-PackSmoke {
    param([Parameter(Mandatory = $true)][string]$PackName, [Parameter(Mandatory = $true)][string]$ModelId)
    $message = switch ($PackName) {
        'coding' { 'run: git --version' }
        'media' { 'run: ffmpeg -version' }
        'documents' { 'run: pdftotext -v' }
        'research' { 'Research fetch https://example.com and return only RESEARCH_FETCH_OK.' }
        'browser' { 'Open https://example.com in the isolated browser and return only BROWSER_OPEN_OBSERVED.' }
        default { return $false }
    }
    $body = @{ model = $ModelId; message = $message; task_id = ('pack-' + $PackName + '-' + [guid]::NewGuid().ToString('N')) } | ConvertTo-Json -Depth 8
    $answer = Invoke-ApiLive '/v1/task' $body -Authenticated -Label "$PackName pack smoke"
    if ($null -eq $answer) { return $false }
    $text = Get-AssistantText $answer
    if ($PackName -eq 'research') { return ($text -match 'RESEARCH_FETCH_OK' -and @($answer.tools_used | Where-Object name -eq 'research_fetch').Count -gt 0) }
    if ($PackName -eq 'browser') { return ($text -match 'BROWSER_OPEN_OBSERVED' -and @($answer.tools_used | Where-Object name -eq 'browser_open_url').Count -gt 0) }
    return ($text -match 'COMMAND_EXECUTION_RESULT' -and @($answer.tools_used | Where-Object name -eq 'run_command').Count -gt 0)
}

function Install-Packs {
    param([Parameter(Mandatory = $true)][string]$Name)
    $installed = @(Get-InstalledPacks)
    foreach ($packName in @($Pack | Select-Object -Unique)) {
        if ($packName -eq 'core' -or $packName -eq 'gpu') { continue }
        if ($packName -in @('coding', 'media', 'documents', 'browser', 'research')) {
            $previous = @($installed)
            if ($installed -notcontains $packName) { $installed += $packName }
            Save-InstalledPacks $installed
            Ensure-RuntimeEnv
            if ($packName -in @('coding', 'media', 'documents', 'browser')) {
                $buildServices = @('gateway', 'agent')
                if ($packName -eq 'browser') { $buildServices += 'browser' }
                $build = Invoke-ComposeLive $Name (@('--progress', 'plain', 'build', '--pull') + $buildServices) ("$packName pack image build")
                if ($build.ExitCode -ne 0) {
                    Save-InstalledPacks $previous
                    Ensure-RuntimeEnv
                    [Console]::Out.WriteLine("LOCALAI_DOCKER_PACK_UNAVAILABLE pack=$packName reason=capability image build failed")
                    return $Exit.Pack
                }
            }
            $up = Invoke-ComposeLive $Name (@('up', '-d', '--force-recreate', '--pull', 'never', '--no-build') + (Get-AppServices)) ("$packName pack activation")
            if ($up.ExitCode -ne 0) {
                Save-InstalledPacks $previous
                Ensure-RuntimeEnv
                [Console]::Out.WriteLine("LOCALAI_DOCKER_PACK_UNAVAILABLE pack=$packName reason=capability activation failed")
                return $Exit.Pack
            }
            $ready = Wait-ForGateway
            $receipt = Get-Receipt
            if ($null -eq $ready -or $null -eq $receipt -or -not (Invoke-PackSmoke $packName ([string]$receipt.model_id))) {
                Save-InstalledPacks $previous
                Ensure-RuntimeEnv
                [void](Invoke-ComposeLive $Name ((@('up', '-d', '--force-recreate', '--pull', 'never', '--no-build') + (Get-AppServices))) "$packName pack rollback")
                [Console]::Out.WriteLine("LOCALAI_DOCKER_PACK_UNAVAILABLE pack=$packName reason=acceptance probe failed")
                return $Exit.Pack
            }
            Update-DeploymentPack $packName 'verified'
            [Console]::Out.WriteLine("LOCALAI_DOCKER_PACK_READY pack=$packName")
            continue
        }
        if ($packName -eq 'browser') { [Console]::Out.WriteLine('LOCALAI_DOCKER_PACK_UNAVAILABLE pack=browser reason=isolated browser service is not yet verified.'); return $Exit.Pack }
        if ($packName -eq 'containers') { [Console]::Out.WriteLine('LOCALAI_DOCKER_PACK_UNAVAILABLE pack=containers reason=rootless nested engine is not yet verified.'); return $Exit.Pack }
        if ($packName -eq 'harness') { [Console]::Out.WriteLine('LOCALAI_DOCKER_PACK_UNAVAILABLE pack=harness reason=pinned harness image is not configured.'); return $Exit.Pack }
        [Console]::Out.WriteLine("LOCALAI_DOCKER_PACK_UNAVAILABLE pack=$packName reason=unknown capability pack.")
        return $Exit.Pack
    }
    if ($Pack -contains 'gpu' -and $Name -eq 'native-linux-gpu') {
        if ($installed -notcontains 'gpu') { $installed += 'gpu'; Save-InstalledPacks $installed; Update-DeploymentPack 'gpu' 'verified' }
    }
    return 0
}

function Get-AssistantText {
    param([Parameter(Mandatory = $true)]$Response)
    try { return [string]$Response.choices[0].message.content } catch { return '' }
}

function Invoke-ProfileBenchmark {
    param([Parameter(Mandatory = $true)][string]$ModelId, [Parameter(Mandatory = $true)][string]$ProfileName)
    $profiles = Read-JsonFile (Join-Path $ConfigRoot 'profiles.json')
    $profile = $profiles.profiles.$ProfileName
    if ($null -eq $profile) { return [pscustomobject]@{ Passed = $false; Reason = "Profile is not defined: $ProfileName" } }
    $marker = 'LOCALAI_PROFILE_BENCHMARK_OK'
    $body = @{ model = $ModelId; messages = @(@{ role = 'user'; content = "Reply with exactly $marker and nothing else." }); temperature = 0; max_tokens = 16; stream = $false } | ConvertTo-Json -Depth 8
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-ApiLive '/v1/chat/completions' $body -Authenticated -Label "$ProfileName profile benchmark" -TimeoutSeconds 180 -ExtraUsage
    $clock.Stop()
    if ($null -eq $response) { return [pscustomobject]@{ Passed = $false; Reason = 'Benchmark inference failed.' } }
    $visible = ''
    try { $visible = [string]$response.choices[0].message.content } catch { }
    if ($visible -notmatch [regex]::Escape($marker)) { return [pscustomobject]@{ Passed = $false; Reason = 'Benchmark returned no verified visible marker.' } }
    $tokens = 0
    try { $tokens = [int]$response.usage.completion_tokens } catch { }
    if ($tokens -le 0) { return [pscustomobject]@{ Passed = $false; Reason = 'Model response did not report completion_tokens.'; elapsed_ms = $clock.ElapsedMilliseconds } }
    $seconds = [Math]::Max(0.001, $clock.Elapsed.TotalSeconds)
    # This is the end-to-end completion rate: it includes queueing, prompt
    # processing, generation, transport, and response parsing.  It is the
    # same metric LocalAI's benchmark command documents, and must not be
    # mislabeled as decode-only llama.cpp speed.
    $endToEndTokensPerSecond = [Math]::Round($tokens / $seconds, 3)
    $minimum = [double]$profile.minimum_generation_tps
    $timingGenerationMs = $null
    $decodeOnlyTokensPerSecond = $null
    try {
        $timingGenerationMs = [double]$response.usage.timing_token_generation
        if ($timingGenerationMs -gt 0) { $decodeOnlyTokensPerSecond = [Math]::Round($tokens / ($timingGenerationMs / 1000.0), 3) }
    } catch { }
    [pscustomobject]@{
        Passed = ($endToEndTokensPerSecond -ge $minimum)
        Reason = if ($endToEndTokensPerSecond -ge $minimum) { 'Measured end-to-end profile floor passed.' } else { "Measured end-to-end completion rate is below the profile floor ($minimum tokens/second)." }
        model_id = $ModelId; profile = $ProfileName; completion_tokens = $tokens
        elapsed_ms = $clock.ElapsedMilliseconds; metric = 'end_to_end_completion_tokens_per_second'
        end_to_end_completion_tokens_per_second = $endToEndTokensPerSecond
        minimum_end_to_end_completion_tokens_per_second = $minimum
        timing_token_generation_ms = $timingGenerationMs
        decode_only_completion_tokens_per_second = $decodeOnlyTokensPerSecond
    }
}

function Start-Interactive {
    param([Parameter(Mandatory = $true)][string]$Name)
    $status = Test-Ready
    if (-not $status.Ready) { Show-Status $status; return $status.Code }
    $modelId = [string]$status.Receipt.model_id
    Write-RunProgress "interactive mode starting backend=$Name model=$modelId"
    $bridgeState = if ($status.PSObject.Properties.Name -contains 'HostBridgeAvailable' -and $status.HostBridgeAvailable) { 'ready' } else { 'unavailable' }
    [Console]::Out.WriteLine("LOCALAI_INTERACTIVE_READY backend=$Name model=$modelId host_bridge=$bridgeState endpoint=http://127.0.0.1:8080")
    [Console]::Out.WriteLine('Type /help for commands, /exit to stop. Enter a message to chat.')
    while ($true) {
        try {
            $prompt = Read-Host -Prompt 'You'
        } catch {
            [Console]::Error.WriteLine('LOCALAI_INTERACTIVE_INTERRUPTED')
            Write-RunProgress 'interactive mode interrupted'
            return $Exit.Interrupted
        }
        if ($null -eq $prompt) {
            [Console]::Out.WriteLine('LOCALAI_INTERACTIVE_CLOSED reason=input-closed')
            Write-RunProgress 'interactive mode finished'
            return 0
        }
        $prompt = $prompt.Trim()
        if ([string]::IsNullOrWhiteSpace($prompt)) { continue }
        $handledCommand = $false
        switch ($prompt.ToLowerInvariant()) {
            '/exit' { [Console]::Out.WriteLine('LOCALAI_INTERACTIVE_CLOSED'); Write-RunProgress 'interactive mode finished'; return 0 }
            '/quit' { [Console]::Out.WriteLine('LOCALAI_INTERACTIVE_CLOSED'); Write-RunProgress 'interactive mode finished'; return 0 }
            '/help' {
                [Console]::Out.WriteLine('/help  show commands')
                [Console]::Out.WriteLine('/status show gateway status')
                [Console]::Out.WriteLine('/exit   close interactive mode')
                $handledCommand = $true
            }
            '/status' {
                $health = Invoke-Api '/health'
                if ($null -ne $health) { [Console]::Out.WriteLine("LOCALAI_INTERACTIVE_STATUS ready=true model=$modelId") }
                else { [Console]::Out.WriteLine('LOCALAI_INTERACTIVE_STATUS ready=false') }
                $handledCommand = $true
            }
        }
        if ($handledCommand) { continue }
        Write-RunProgress 'interactive agent task started'
        $body = @{ model = $modelId; message = $prompt; task_id = ('interactive-' + [guid]::NewGuid().ToString('N')) } | ConvertTo-Json -Depth 8
        $answer = Invoke-ApiLive '/v1/task' $body -Authenticated -Label 'interactive agent task' -TimeoutSeconds 330
        if ($null -eq $answer) {
            [Console]::Error.WriteLine('LOCALAI_INTERACTIVE_ERROR reason=agent-task-failed')
            Write-RunProgress 'interactive agent task finished status=failed'
            continue
        }
        $text = Get-AssistantText $answer
        if ([string]::IsNullOrWhiteSpace($text)) {
            [Console]::Error.WriteLine('LOCALAI_INTERACTIVE_ERROR reason=empty-visible-answer')
            Write-RunProgress 'interactive agent task finished status=empty'
            continue
        }
        $toolSummary = ''
        try { $toolSummary = (@($answer.tools_used | ForEach-Object { $_.name + ':' + $_.status }) -join ',') } catch { }
        Write-RunProgress "interactive agent task finished status=verified tools=$toolSummary"
        [Console]::Out.WriteLine('AI>')
        [Console]::Out.WriteLine($text)
    }
}

function Run-Benchmark {
    $status = Test-Ready
    if (-not $status.Ready) { Show-Status $status; return $status.Code }
    $body = @{ model = $status.Receipt.model_id; messages = @(@{ role = 'user'; content = 'Reply with exactly BENCHMARK_OK and nothing else.' }); max_tokens = 8; stream = $false } | ConvertTo-Json -Depth 8
    $start = [Diagnostics.Stopwatch]::StartNew()
    $answer = Invoke-Api '/v1/chat/completions' $body -Authenticated
    $start.Stop()
    if ($null -eq $answer) { [Console]::Error.WriteLine('Benchmark inference failed.'); return $Exit.Server }
    $report = [ordered]@{ schema_version = 1; backend = $status.Backend; model_id = $status.Receipt.model_id; elapsed_ms = $start.ElapsedMilliseconds; response = $answer }
    $path = Join-Path $ProjectRoot ('evidence\benchmark-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '.json')
    Write-AtomicText $path ($report | ConvertTo-Json -Depth 20)
    [Console]::Out.WriteLine("BENCHMARK_PASSED evidence=$path")
    return 0
}

function Run-Main {
    $selected = @(@($SelfTest, $Check, $Doctor, $Install, $Launch, $Repair, $Models, $Benchmark) | Where-Object { $_ })
    if ($selected.Count -gt 1) { [Console]::Error.WriteLine('Choose one primary operation.'); return $Exit.Invalid }
    if ($Models) { [Console]::Out.WriteLine((Read-JsonFile (Join-Path $ConfigRoot 'models.lock.json') | ConvertTo-Json -Depth 12)); return 0 }
    if ($Benchmark) { return Run-Benchmark }
    $name = Get-BackendName
    if ($Install) {
        if ($Pack -contains 'gpu' -and $name -ne 'native-linux-gpu') { [Console]::Error.WriteLine('The GPU pack requires -Backend native-linux-gpu.'); return $Exit.Backend }
        $code = Install-Core $name
        if ($code -ne 0) { return $code }
        return Install-Packs $name
    }
    if ($Repair) {
        return Start-Runtime $name -ForceRecreate
    }
    if ($Doctor) {
        $status = Test-Ready
        $status | Add-Member -NotePropertyName project_root -NotePropertyValue $ProjectRoot
        $context = 'unavailable'
        try { $context = (Invoke-Docker @('context', 'show')).Output.Trim() } catch { }
        $status | Add-Member -NotePropertyName docker_context -NotePropertyValue $context
        Show-Status $status
        return $status.Code
    }
    if ($SelfTest -or $Check) {
        $status = Test-Ready
        Show-Status $status
        return $status.Code
    }
    if (-not $Launch -and -not $Task) {
        $startCode = Start-Runtime $name
        if ($startCode -ne 0) { return $startCode }
        return Start-Interactive -Name $name
    }
    $startCode = Start-Runtime $name
    if ($startCode -ne 0) { return $startCode }
    $status = Test-Ready
    if (-not $status.Ready) { Show-Status $status; return $status.Code }
    if ($Task -and $Task.Count -gt 0) {
        Write-RunProgress 'agent task started'
        $body = @{ model = $status.Receipt.model_id; message = ($Task -join ' '); task_id = ('oneshot-' + [guid]::NewGuid().ToString('N')) } | ConvertTo-Json -Depth 8
        $answer = Invoke-Api '/v1/task' $body -Authenticated
        if ($null -eq $answer) { return $Exit.Server }
        Write-RunProgress 'agent task finished'
        [Console]::Out.WriteLine(($answer | ConvertTo-Json -Depth 20))
    }
    return Start-Interactive -Name $name
}

try {
    Write-RunProgress "launcher started project=$ProjectRoot"
    $exitCode = Run-Main
    Write-RunProgress "launcher finished exit=$exitCode"
    exit $exitCode
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    Write-RunProgress "launcher finished exit=$($Exit.Invalid) error"
    exit $Exit.Invalid
}

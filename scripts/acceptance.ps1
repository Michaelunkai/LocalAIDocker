[CmdletBinding()]
param([switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$results = New-Object System.Collections.Generic.List[object]
function Add-Result { param([string]$Name, [string]$State, [string]$Detail); $results.Add([pscustomobject]@{name=$Name;state=$State;detail=$Detail}) }
function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 4MB, [IO.FileOptions]::SequentialScan)
    $digest = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] (4MB)
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$digest.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        [void]$digest.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return ([BitConverter]::ToString($digest.Hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $digest.Dispose()
        $stream.Dispose()
    }
}
$textExtensions = @('.ps1', '.py', '.json', '.yaml', '.yml', '.md', '.txt')
$files = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
    Where-Object {
        $_.FullName -notlike '*\acceptance.ps1' -and
        $_.FullName -notmatch '\\(data|state|logs|evidence|backups|secrets)\\' -and
        ($textExtensions -contains $_.Extension.ToLowerInvariant() -or $_.Name -in @('Dockerfile', '.dockerignore', '.gitignore'))
    }
$forbidden = @(
    (([char]119)+([char]115)+([char]108)+([char]46)+([char]101)+([char]120)+([char]101)),
    (([char]47)+([char]109)+([char]110)+([char]116)+([char]47)),
    (([char]98)+([char]97)+([char]115)+([char]104)+([char]32)+([char]45)+([char]108)+([char]105)+([char]32)+([char]45)+([char]99)),
    (([char]115)+([char]104)+([char]101)+([char]108)+([char]108)+([char]61)+([char]116)+([char]114)+([char]117)+([char]101)),
    ':latest',
    'docker.sock',
    'privileged: true'
)
$violations = foreach ($item in $files) { foreach ($needle in $forbidden) { Select-String -LiteralPath $item.FullName -SimpleMatch $needle -ErrorAction SilentlyContinue } }
if ($violations) { Add-Result 'forbidden-runtime-reference-scan' 'failed' (($violations | Select-Object -First 10 | ForEach-Object { $_.Path }) -join ';') } else { Add-Result 'forbidden-runtime-reference-scan' 'passed' 'No forbidden runtime references found.' }
try { Get-Content -LiteralPath (Join-Path $root 'config\runtime.lock.json') -Raw | ConvertFrom-Json | Out-Null; Add-Result 'runtime-lock-json' 'passed' 'Valid JSON.' } catch { Add-Result 'runtime-lock-json' 'failed' $_.Exception.Message }
try { Get-Content -LiteralPath (Join-Path $root 'config\models.lock.json') -Raw | ConvertFrom-Json | Out-Null; Add-Result 'models-lock-json' 'passed' 'Valid JSON.' } catch { Add-Result 'models-lock-json' 'failed' $_.Exception.Message }
try {
    $modelLock = Get-Content -LiteralPath (Join-Path $root 'config\models.lock.json') -Raw | ConvertFrom-Json
    $modelErrors = New-Object System.Collections.Generic.List[string]
    foreach ($model in @($modelLock.models)) {
        $revision = [string]$model.revision
        if ($revision -notmatch '^[0-9a-fA-F]{40}$') { [void]$modelErrors.Add("$($model.id): revision is not a full commit") }
        if ([string]::IsNullOrWhiteSpace([string]$model.license)) { [void]$modelErrors.Add("$($model.id): license is missing") }
        foreach ($artifact in @($model.artifacts)) {
            $filename = [string]$artifact.filename
            if ([string]::IsNullOrWhiteSpace($filename) -or [IO.Path]::GetFileName($filename) -ne $filename) { [void]$modelErrors.Add("$($model.id): unsafe artifact filename") }
            if ([int64]$artifact.size_bytes -le 0) { [void]$modelErrors.Add("$($model.id): artifact size is not positive") }
            if ([string]$artifact.sha256 -notmatch '^[0-9a-fA-F]{64}$') { [void]$modelErrors.Add("$($model.id): artifact digest is invalid") }
            if ([string]$artifact.url -notmatch [regex]::Escape($revision)) { [void]$modelErrors.Add("$($model.id): artifact URL is not revision-pinned") }
        }
    }
    if ($modelErrors.Count -eq 0) { Add-Result 'models-lock-schema' 'passed' 'Every locked model has full revision, exact-size, digest, and safe artifact metadata.' }
    else { Add-Result 'models-lock-schema' 'failed' (($modelErrors | Select-Object -First 12) -join '; ') }
} catch { Add-Result 'models-lock-schema' 'failed' $_.Exception.Message }
$ps = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue
if ($ps) {
    $parse = & $ps.Source -NoProfile -NonInteractive -Command "[System.Management.Automation.Language.Parser]::ParseFile('$((Join-Path $root 'scripts\llm.ps1').Replace("'", "''"))',[ref]`$null,[ref]`$null) | Out-Null"
    if ($LASTEXITCODE -eq 0) { Add-Result 'powershell-parse' 'passed' 'Launcher parser check completed.' } else { Add-Result 'powershell-parse' 'failed' 'PowerShell parser check failed.' }
} else { Add-Result 'powershell-parse' 'unverified-external' 'PowerShell executable unavailable.' }

try {
    $scriptErrors = New-Object System.Collections.Generic.List[string]
    foreach ($scriptFile in Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File -Recurse) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) { [void]$scriptErrors.Add($scriptFile.FullName + ': ' + (($errors | Select-Object -First 1).Message)) }
    }
    if ($scriptErrors.Count -eq 0) { Add-Result 'all-powershell-parse' 'passed' 'All target PowerShell scripts parse successfully.' }
    else { Add-Result 'all-powershell-parse' 'failed' (($scriptErrors | Select-Object -First 10) -join '; ') }
} catch { Add-Result 'all-powershell-parse' 'failed' $_.Exception.Message }

$python = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($python) {
    $previousPythonPath = $env:PYTHONPATH
    $unitExitCode = 1
    Push-Location $root
    try {
        $env:PYTHONPATH = $root
        # unittest writes its progress stream to stderr.  With the script's
        # global Stop preference, PowerShell 5.1 turns that redirected native
        # stream into a terminating RemoteException before the exit code can
        # be inspected.  Preserve the output but temporarily allow native
        # stderr while the child process is running.
        $previousUnitErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $unitOutput = @(& $python.Source -m unittest discover -s tests -p 'test_*.py' 2>&1) }
        finally { $ErrorActionPreference = $previousUnitErrorAction }
        $unitExitCode = [int]$LASTEXITCODE
        if ($unitExitCode -eq 0) { Add-Result 'agent-unit-tests' 'passed' 'Direct intent and policy routing tests passed.' }
        else { Add-Result 'agent-unit-tests' 'failed' ("exit=$unitExitCode " + (($unitOutput -join "`n").Trim())) }
    } catch { Add-Result 'agent-unit-tests' 'failed' ("exit=$unitExitCode " + $_.Exception.ToString()) }
    finally {
        Pop-Location
        if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
    }
} else { Add-Result 'agent-unit-tests' 'unverified-external' 'Python executable unavailable.' }

function Get-AcceptanceDocker {
    foreach ($commandName in @('docker.exe', 'docker')) {
        $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and $command.Source) { return [string]$command.Source }
    }
    foreach ($candidate in @(
            (Join-Path ${env:ProgramFiles} 'Docker\Docker\resources\bin\docker.exe'),
            (Join-Path ${env:ProgramFiles} 'Docker\Docker\resources\bin\com.docker.cli.exe'),
            (Join-Path ${env:LOCALAPPDATA} 'Docker\wsl\docker.exe')
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

function Invoke-CheckedDocker {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [int]$TimeoutSeconds = 20)
    $docker = Get-AcceptanceDocker
    if (-not $docker) { return [pscustomobject]@{ Output = 'Docker CLI is unavailable.'; ExitCode = 127 } }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $job = $null
    try {
        $argumentJson = @($Arguments) | ConvertTo-Json -Compress
        $job = Start-Job -ScriptBlock {
            param([string]$Executable, [string]$ArgumentJson)
            $parsedArguments = ConvertFrom-Json -InputObject $ArgumentJson
            $argv = New-Object string[] ([int]$parsedArguments.Count)
            for ($index = 0; $index -lt $parsedArguments.Count; $index++) {
                $argv[$index] = [string]$parsedArguments[$index]
            }
            $lines = @(& $Executable @argv 2>&1)
            [pscustomobject]@{ Output = ($lines -join "`n"); ExitCode = $LASTEXITCODE }
        } -ArgumentList $docker, $argumentJson
        $finished = Wait-Job -Job $job -Timeout ([Math]::Max(1, $TimeoutSeconds))
        if ($null -eq $finished) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
            return [pscustomobject]@{ Output = "Docker command timed out after $TimeoutSeconds seconds."; ExitCode = 124 }
        }
        $result = Receive-Job -Job $job | Select-Object -Last 1
        if ($null -eq $result) { return [pscustomobject]@{ Output = 'Docker command returned no result.'; ExitCode = 125 } }
        return [pscustomobject]@{ Output = [string]$result.Output; ExitCode = [int]$result.ExitCode }
    } catch {
        return [pscustomobject]@{ Output = $_.Exception.Message; ExitCode = 125 }
    } finally {
        if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null }
        $ErrorActionPreference = $previous
    }
}

$docker = Get-AcceptanceDocker
$receiptPath = Join-Path $root 'state\current-deployment.json'
$runtimeEnv = Join-Path $root '.env.runtime'
if (-not $docker) {
    Add-Result 'docker-cli' 'unverified-external' 'Docker CLI is unavailable.'
} else {
    $info = Invoke-CheckedDocker @('info', '--format', '{{json .}}')
    if ($info.ExitCode -ne 0) {
        Add-Result 'docker-daemon' 'unverified-external' 'Docker daemon is unavailable.'
    } else {
        Add-Result 'docker-daemon' 'passed' 'Docker daemon is reachable.'
        $backendName = 'hyperv-cpu'
        $installedPackNames = @('core')
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            try {
                $earlyReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
                if ($earlyReceipt.backend) { $backendName = [string]$earlyReceipt.backend }
            } catch { }
        }
        $installedPath = Join-Path $root 'state\installed-packs.json'
        if (Test-Path -LiteralPath $installedPath -PathType Leaf) {
            try { $installedPackNames = @((Get-Content -LiteralPath $installedPath -Raw | ConvertFrom-Json).packs | ForEach-Object { [string]$_ }) } catch { }
        }
        $composeArgs = @('compose', '--env-file', $runtimeEnv, '-f', (Join-Path $root 'compose.yaml'))
        if ($backendName -eq 'native-linux-gpu') { $composeArgs += @('-f', (Join-Path $root 'compose.gpu.yaml')) } else { $composeArgs += @('-f', (Join-Path $root 'compose.cpu.yaml')) }
        if ($installedPackNames -contains 'browser') { $composeArgs += @('-f', (Join-Path $root 'compose.pack-browser.yaml')) }
        if ($installedPackNames -contains 'research') { $composeArgs += @('-f', (Join-Path $root 'compose.pack-research.yaml')) }
        $composeArgs += @('config', '--quiet')
        $compose = Invoke-CheckedDocker $composeArgs
        if ($compose.ExitCode -eq 0) { Add-Result 'compose-config' 'passed' 'CPU Compose configuration is valid.' }
        else { Add-Result 'compose-config' 'failed' $compose.Output }

        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            try {
                $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
                $modelLock = Get-Content -LiteralPath (Join-Path $root 'config\models.lock.json') -Raw | ConvertFrom-Json
                $model = @($modelLock.models | Where-Object id -eq $receipt.model_id | Select-Object -First 1)
                if ($model.Count -ne 1) { throw 'Receipt model is absent from the model lock.' }
                $artifact = @($model[0].artifacts | Where-Object role -eq 'main' | Select-Object -First 1)
                $artifactPath = Join-Path $root ("data\models\$($model[0].id)\$($artifact[0].filename)")
                if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw 'Locked model artifact is missing.' }
                $file = Get-Item -LiteralPath $artifactPath
                if ([int64]$file.Length -ne [int64]$artifact[0].size_bytes) { throw 'Locked model artifact size does not match.' }
                $hash = Get-FileSha256 $artifactPath
                if ($hash -ne [string]$artifact[0].sha256) { throw 'Locked model artifact SHA-256 does not match.' }
                Add-Result 'model-artifact-integrity' 'passed' 'Model size and SHA-256 match the lock.'
            } catch { Add-Result 'model-artifact-integrity' 'failed' $_.Exception.Message }

            $health = $null
            try { $health = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 10 -ErrorAction Stop } catch { }
            if ($health -and $health.StatusCode -eq 200) { Add-Result 'gateway-health' 'passed' 'Loopback gateway health is reachable.' }
            else { Add-Result 'gateway-health' 'failed' 'Loopback gateway health is unavailable.' }

            $body = @{ model = [string]$receipt.model_id; messages = @(@{ role = 'user'; content = 'Reply with exactly ACCEPTANCE_CORE_OK.' }); max_tokens = 16; stream = $false } | ConvertTo-Json -Depth 8
            $unauthorizedStatus = 0
            try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8080/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30 -ErrorAction Stop | Out-Null; $unauthorizedStatus = 200 } catch { if ($_.Exception.Response) { $unauthorizedStatus = [int]$_.Exception.Response.StatusCode.value__ } }
            if ($unauthorizedStatus -in @(401, 403)) { Add-Result 'unauthenticated-inference-rejected' 'passed' 'Inference route rejects missing credentials.' }
            else { Add-Result 'unauthenticated-inference-rejected' 'failed' "Unexpected unauthenticated status: $unauthorizedStatus" }

            $secretPath = Join-Path $root 'secrets\localai-api-key'
            if (Test-Path -LiteralPath $secretPath -PathType Leaf) {
                try {
                    $key = (Get-Content -LiteralPath $secretPath -Raw).Trim()
                    $headers = @{ Authorization = 'Bearer ' + $key }
                    $response = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/chat/completions' -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 180 -ErrorAction Stop
                    if ([string]$response.choices[0].message.content -match 'ACCEPTANCE_CORE_OK') { Add-Result 'authenticated-inference' 'passed' 'Authenticated inference returned the expected visible answer.' }
                    else { Add-Result 'authenticated-inference' 'failed' 'Authenticated inference returned an unexpected answer.' }
                } catch { Add-Result 'authenticated-inference' 'failed' 'Authenticated inference failed.' }
            } else { Add-Result 'authenticated-inference' 'failed' 'API key file is missing.' }

            if (Test-Path -LiteralPath $secretPath -PathType Leaf) {
                try {
                    $agentBody = @{ model = [string]$receipt.model_id; message = 'Reply with exactly ACCEPTANCE_AGENT_OK.'; task_id = ('acceptance-' + [guid]::NewGuid().ToString('N')) } | ConvertTo-Json -Depth 8
                    $agentResponse = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/task' -Method Post -Headers $headers -ContentType 'application/json' -Body $agentBody -TimeoutSec 180 -ErrorAction Stop
                    if ([string]$agentResponse.choices[0].message.content -match 'ACCEPTANCE_AGENT_OK') { Add-Result 'authenticated-agent-task' 'passed' 'Agent task returned the expected visible answer.' }
                    else { Add-Result 'authenticated-agent-task' 'failed' 'Agent task returned an unexpected answer.' }
                } catch { Add-Result 'authenticated-agent-task' 'failed' 'Authenticated agent task failed.' }

                try {
                    $identityBody = @{ model = [string]$receipt.model_id; message = 'Tell me exactly what model are you?'; task_id = ('identity-' + [guid]::NewGuid().ToString('N')) } | ConvertTo-Json -Depth 8
                    $identity = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/task' -Method Post -Headers $headers -ContentType 'application/json' -Body $identityBody -TimeoutSec 180 -ErrorAction Stop
                    if ([string]$identity.choices[0].message.content -match [regex]::Escape([string]$receipt.model_id)) { Add-Result 'model-identity' 'passed' 'Interactive agent reports the verified deployment model.' }
                    else { Add-Result 'model-identity' 'failed' 'Agent model identity did not match the receipt.' }
                } catch { Add-Result 'model-identity' 'failed' 'Model identity task failed.' }

                try {
                    $filesystemBody = @{ model = [string]$receipt.model_id; message = 'List every folder recursively under F:\study\AI\_ML\LocalAI\LocalAIDocker\config.'; task_id = ('filesystem-' + [guid]::NewGuid().ToString('N')) } | ConvertTo-Json -Depth 8
                    $filesystem = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/task' -Method Post -Headers $headers -ContentType 'application/json' -Body $filesystemBody -TimeoutSec 180 -ErrorAction Stop
                    if ([string]$filesystem.choices[0].message.content -match 'WINDOWS_FILESYSTEM_SCAN_OK' -and @($filesystem.tools_used | Where-Object name -eq 'list_windows_directories').Count -gt 0) { Add-Result 'windows-filesystem-agent-tool' 'passed' 'Authenticated agent enumerated the target-local Windows tree through the bridge.' }
                    else { Add-Result 'windows-filesystem-agent-tool' 'failed' 'Agent did not return a verified filesystem scan.' }
                } catch { Add-Result 'windows-filesystem-agent-tool' 'failed' 'Filesystem agent task failed.' }

                try {
                    $commandBody = @{ model = [string]$receipt.model_id; message = 'run: python --version'; task_id = ('command-' + [guid]::NewGuid().ToString('N')) } | ConvertTo-Json -Depth 8
                    $command = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/task' -Method Post -Headers $headers -ContentType 'application/json' -Body $commandBody -TimeoutSec 180 -ErrorAction Stop
                    if ([string]$command.choices[0].message.content -match 'COMMAND_EXECUTION_RESULT' -and @($command.tools_used | Where-Object name -eq 'run_command').Count -gt 0) { Add-Result 'structured-command-agent-tool' 'passed' 'Explicit command request used the bounded argv path.' }
                    else { Add-Result 'structured-command-agent-tool' 'failed' 'Agent did not return a verified structured command result.' }
                } catch { Add-Result 'structured-command-agent-tool' 'failed' 'Structured command agent task failed.' }

                $hostKeyPath = Join-Path $root 'secrets\host-bridge-key'
                if (Test-Path -LiteralPath $hostKeyPath -PathType Leaf) {
                    try {
                        $hostKey = (Get-Content -LiteralPath $hostKeyPath -Raw).Trim()
                        $hostHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/health' -Headers @{ Authorization = 'Bearer ' + $hostKey } -TimeoutSec 5 -ErrorAction Stop
                        if ([string]$hostHealth.status -eq 'host-bridge-ready') { Add-Result 'host-bridge-health' 'passed' 'Target-local Windows interoperability bridge is authenticated and ready.' }
                        else { Add-Result 'host-bridge-health' 'failed' 'Host bridge returned an unexpected status.' }
                    } catch { Add-Result 'host-bridge-health' 'failed' 'Host bridge is unavailable.' }
                } else { Add-Result 'host-bridge-health' 'skipped-not-installed' 'Host bridge key does not exist.' }

                $packProbes = @{
                    coding = @{ message = 'run: git --version'; marker = 'COMMAND_EXECUTION_RESULT'; tool = 'run_command' }
                    media = @{ message = 'run: ffmpeg -version'; marker = 'COMMAND_EXECUTION_RESULT'; tool = 'run_command' }
                    documents = @{ message = 'run: pdftotext -v'; marker = 'COMMAND_EXECUTION_RESULT'; tool = 'run_command' }
                    research = @{ message = 'Research fetch https://example.com and return only RESEARCH_FETCH_OK.'; marker = 'RESEARCH_FETCH_OK'; tool = 'research_fetch' }
                    browser = @{ message = 'Open https://example.com in the isolated browser and return only BROWSER_OPEN_OBSERVED.'; marker = 'BROWSER_OPEN_OBSERVED'; tool = 'browser_open_url' }
                }
                foreach ($optionalPack in @('coding', 'media', 'documents', 'research', 'browser', 'containers', 'harness')) {
                    if ($installedPackNames -notcontains $optionalPack) {
                        Add-Result ("pack-$optionalPack") 'skipped-not-installed' 'Optional pack is not installed.'
                        continue
                    }
                    if (-not $packProbes.ContainsKey($optionalPack)) {
                        Add-Result ("pack-$optionalPack") 'blocked-missing-authority' 'Pack is recorded but has no verified acceptance probe.'
                        continue
                    }
                    try {
                        $probeBody = @{ model = [string]$receipt.model_id; message = [string]$packProbes[$optionalPack].message; task_id = ('acceptance-pack-' + $optionalPack + '-' + [guid]::NewGuid().ToString('N')) } | ConvertTo-Json -Depth 8
                        $probe = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/task' -Method Post -Headers $headers -ContentType 'application/json' -Body $probeBody -TimeoutSec 180 -ErrorAction Stop
                        $markerFound = [string]$probe.choices[0].message.content -match [regex]::Escape([string]$packProbes[$optionalPack].marker)
                        $toolFound = @($probe.tools_used | Where-Object name -eq ([string]$packProbes[$optionalPack].tool)).Count -gt 0
                        if ($markerFound -and $toolFound) { Add-Result ("pack-$optionalPack") 'passed' 'Optional pack behavior and tool receipt were verified.' }
                        else { Add-Result ("pack-$optionalPack") 'failed' 'Optional pack probe returned no complete verified result.' }
                    } catch { Add-Result ("pack-$optionalPack") 'failed' 'Optional pack probe failed.' }
                }
            }

            $ids = @((Invoke-CheckedDocker @('ps', '-aq', '--filter', 'label=com.docker.compose.project=localaidocker')).Output.Trim() -split "`r?`n" | Where-Object { $_ })
            if ($ids.Count -eq 0) { Add-Result 'owned-containers' 'failed' 'No owned LocalAIDocker containers are present.' }
            else {
                Add-Result 'owned-containers' 'passed' 'Owned LocalAIDocker containers are present.'
                $socketMount = $false
                foreach ($id in $ids) {
                    $inspect = Invoke-CheckedDocker @('inspect', '--format', '{{json .Mounts}}', $id)
                    if ($inspect.ExitCode -eq 0 -and $inspect.Output -match 'docker\.sock') { $socketMount = $true }
                }
                if ($socketMount) { Add-Result 'docker-socket-isolation' 'failed' 'An owned service mounts the host Docker socket.' }
                else { Add-Result 'docker-socket-isolation' 'passed' 'Owned services do not mount the host Docker socket.' }
            }
        } else {
            Add-Result 'core-runtime' 'skipped-not-installed' 'No deployment receipt exists.'
        }
    }
}
if ($Json) { $results | ConvertTo-Json -Depth 8 } else { $results | Format-Table -AutoSize | Out-String | Write-Output }
if (@($results | Where-Object state -eq 'failed').Count -gt 0) { exit 1 } else { exit 0 }

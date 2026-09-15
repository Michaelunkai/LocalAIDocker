[CmdletBinding()]
param([ValidateSet('hyperv-cpu', 'native-linux-gpu')][string]$Backend = 'hyperv-cpu', [switch]$Json)
$scriptPath = Join-Path $PSScriptRoot 'llm.ps1'
& $scriptPath -Doctor -Backend $Backend -Json:$Json
exit $LASTEXITCODE


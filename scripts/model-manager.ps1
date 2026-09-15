[CmdletBinding()]
param([ValidateSet('hyperv-cpu', 'native-linux-gpu')][string]$Backend = 'hyperv-cpu')
$scriptPath = Join-Path $PSScriptRoot 'llm.ps1'
& $scriptPath -Install -Backend $Backend -Pack core
exit $LASTEXITCODE


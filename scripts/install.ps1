[CmdletBinding()]
param([ValidateSet('hyperv-cpu', 'native-linux-gpu')][string]$Backend = 'hyperv-cpu', [string[]]$Pack = @('core'))
$scriptPath = Join-Path $PSScriptRoot 'llm.ps1'
& $scriptPath -Install -Backend $Backend -Pack $Pack
exit $LASTEXITCODE

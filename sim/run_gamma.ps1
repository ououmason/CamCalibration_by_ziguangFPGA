$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
Push-Location $projectDir
try {
    foreach ($testName in @('gamma', 'gamma_chain', 'gamma_system')) {
        $testLog = "sim/$testName.log"
        & vsim -c -do "sim/$testName.do" -l $testLog
        if ($LASTEXITCODE -ne 0) { throw "$testName simulator failed" }
        # Some ModelSim versions exit zero after $fatal: inspect diagnostics too.
        $testOutput = Get-Content -LiteralPath $testLog -Raw
        if ($testOutput -match '\*\* (Fatal|Error):' -or $testOutput -notmatch '# PASS') {
            throw "$testName checks failed; see $testLog"
        }
    }
} finally {
    Pop-Location
}

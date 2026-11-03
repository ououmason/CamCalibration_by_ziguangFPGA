$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
Push-Location $projectDir
try {
    & node sim/make_he_vectors.cjs
    if ($LASTEXITCODE -ne 0) { throw 'HE reference generation failed' }
    foreach ($testName in @('he', 'he_short_blank', 'he_color', 'he_hd_cdf', 'he_system')) {
        $testLog = "sim/$testName.log"
        & vsim -c -do "sim/$testName.do" -l $testLog
        if ($LASTEXITCODE -ne 0) { throw "$testName simulator failed" }
        $testOutput = Get-Content -LiteralPath $testLog -Raw
        if ($testOutput -match '\*\* (Fatal|Error):' -or $testOutput -notmatch '# PASS') {
            throw "$testName checks failed; see $testLog"
        }
    }
} finally {
    Pop-Location
}

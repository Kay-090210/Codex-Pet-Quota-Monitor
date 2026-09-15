$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    & go test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go tests failed.' }
    & go build -trimpath -o ../../bin/codex-pet-ping.exe ./cmd/pet-ping
    if ($LASTEXITCODE -ne 0) { throw 'Go build failed.' }
} finally {
    Pop-Location
}

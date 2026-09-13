param(
    [ValidateSet('Start', 'Status', 'Stop')]
    [string]$Action = 'Start',
    [string]$Distribution = 'Debian'
)

$ErrorActionPreference = 'Stop'
$TaskRepository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$TaskWslRepository = (& wsl.exe -d $Distribution --exec wslpath -a -u $TaskRepository).Trim()
if ($LASTEXITCODE -ne 0) { throw 'The repository is not accessible in the selected WSL distribution.' }
$TaskAcceptanceRoot = (& wsl.exe -d $Distribution --exec python3 -c "from pathlib import Path; print(Path.home() / '.local/share/bilicomics-acceptance')").Trim()
if ($LASTEXITCODE -ne 0) { throw 'Python is unavailable in the selected WSL distribution.' }
$TaskLauncher = "$TaskWslRepository/spec/local/launch_koreader.py"
$TaskProfile = "$TaskAcceptanceRoot/profile"

if ($Action -eq 'Start') {
    & wsl.exe -d $Distribution --exec python3 "$TaskWslRepository/spec/local/prepare_runtime.py"
    if ($LASTEXITCODE -ne 0) { throw 'Official KOReader runtime preparation failed.' }
    & wsl.exe -d $Distribution --exec python3 $TaskLauncher `
        --runtime "$TaskAcceptanceRoot/runtime-v2026.07.1/lib/koreader" `
        --plugin "$TaskWslRepository/dist/bilicomics-0.1.0-dev.zip" `
        --profile $TaskProfile
} else {
    $TaskMode = if ($Action -eq 'Status') { '--status' } else { '--stop' }
    & wsl.exe -d $Distribution --exec python3 $TaskLauncher --profile $TaskProfile $TaskMode
}
if ($LASTEXITCODE -ne 0) { throw 'The local acceptance launcher did not complete successfully.' }

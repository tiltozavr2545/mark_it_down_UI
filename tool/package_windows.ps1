param(
    [Parameter(Mandatory)]
    [string]$Compiler
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repo 'app\build\windows\x64\runner\Release'
$app = Get-Item -LiteralPath (Join-Path $releaseDir 'markitdown_ui.exe')

$pubspec = Get-Content -LiteralPath (Join-Path $repo 'app\pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:[ \t]*(\d+\.\d+\.\d+)\+(\d+)[ \t]*\r?$') {
    throw 'Expected a MAJOR.MINOR.PATCH+BUILD version in app/pubspec.yaml.'
}
$version = $Matches[1]
$build = $Matches[2]
$fileInfo = $app.VersionInfo
$fileVersion = '{0}.{1}.{2}.{3}' -f $fileInfo.FileMajorPart, $fileInfo.FileMinorPart,
    $fileInfo.FileBuildPart, $fileInfo.FilePrivatePart
if ($fileVersion -ne "$version.$build") {
    throw "Rebuild the Windows app for $version+$build before packaging."
}

# Install the x64 C++ runtime beside the app so Setup can stay per-user.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -version '[17.0,18.0)' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vs) {
    throw 'Visual Studio 2022 with the C++ desktop tools is required.'
}
$runtime = Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Redist\MSVC') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+(\.\d+)?$' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
    Select-Object -First 1
if (-not $runtime) {
    throw 'The Visual Studio 2022 x64 Visual C++ redistributable files were not found.'
}

& $Compiler '/Qp' "/DAppVersion=$version" "/DAppBuild=$build" `
    "/DReleaseDir=$releaseDir" "/DVCRuntimeDir=$runtime" `
    (Join-Path $PSScriptRoot 'windows-installer.iss')
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compiler exited with code $LASTEXITCODE."
}

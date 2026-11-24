# Parses every T-SQL script with Microsoft's own parser (ScriptDom). It does not need a SQL Server.
# sqlcmd directives (:r, :setvar, :on error) are blanked and $(variables) are replaced before parsing.
$ErrorActionPreference = 'Stop'
$version = '180.107.0'
$sha256 = 'D815856F46486FFB576096DA86BD7613F80D3E3F333BE17BC6D05C2EB913E21A'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$work = Join-Path ([IO.Path]::GetTempPath()) "scriptdom-$version"
New-Item -ItemType Directory -Force $work | Out-Null
$zip = Join-Path $work 'scriptdom.zip'
if (-not (Test-Path $zip)) {
    $id = 'microsoft.sqlserver.transactsql.scriptdom'
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$id/$version/$id.$version.nupkg" -OutFile $zip
}
if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $sha256) { throw 'Unexpected SHA-256 for the ScriptDom package' }
Expand-Archive $zip (Join-Path $work 'x') -Force
Add-Type -Path (Join-Path $work 'x/lib/netstandard2.1/Microsoft.SqlServer.TransactSql.ScriptDom.dll')

$parser = [Microsoft.SqlServer.TransactSql.ScriptDom.TSql170Parser]::new($true)
$scripts = Get-ChildItem $root -Directory | Where-Object Name -ne 'vuelos-eeuu-postgresql' |
    ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'sql') -Filter *.sql -ErrorAction SilentlyContinue }
$bad = 0
foreach ($s in $scripts) {
    $lines = [IO.File]::ReadAllText($s.FullName) -split "`n"
    $text = ($lines | ForEach-Object { if ($_ -match '^\s*:') { '' } else { $_ -replace '\$\(\w+\)', '1' } }) -join "`n"
    $errors = $null
    [void]$parser.Parse([IO.StringReader]::new($text), [ref]$errors)
    foreach ($e in $errors) {
        $bad++
        Write-Output "::error file=$([IO.Path]::GetRelativePath($root, $s.FullName)),line=$($e.Line)::$($e.Message)"
    }
}
Write-Output "$($scripts.Count) T-SQL scripts parsed, $bad errors"
if ($scripts.Count -eq 0 -or $bad) { exit 1 }
exit 0

<#
.SYNOPSIS
    Ejecuta el pipeline completo (sql\00_EJECUTAR_TODO.sql) desde cualquier carpeta.
.DESCRIPTION
    Calcula la ruta de esta carpeta y se la pasa a sqlcmd como la variable "Proyecto",
    así no hay que editar ninguna ruta a mano. La ruta de la carpeta no puede tener espacios.
.EXAMPLE
    .\ejecutar.ps1
    .\ejecutar.ps1 -Servidor "localhost\SQLEXPRESS" -SinBenchmark
#>
param(
    [string]$Servidor = 'localhost\SQLEXPRESS',
    [switch]$SinBenchmark   # salta el laboratorio rowstore/columnstore (~20 min)
)

$ErrorActionPreference = 'Stop'
$env:Proyecto = $PSScriptRoot
$env:BenchmarkCompleto = if ($SinBenchmark) { '0' } else { '1' }

sqlcmd -S $Servidor -E -C -I -b -f 65001 -i (Join-Path $PSScriptRoot 'sql\00_EJECUTAR_TODO.sql')
exit $LASTEXITCODE

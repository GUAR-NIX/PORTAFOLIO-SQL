"""Exporta a reports/tablas/ las cifras del README que no salen de las figuras.

Solo lee de la base (vistas rpt y marts); no modifica nada. Requiere el pipeline ya ejecutado.
Uso (desde la carpeta del proyecto):  .venv/Scripts/python scripts/exportar_hallazgos.py
"""
from __future__ import annotations

from pathlib import Path

from conexion import consultar

TABLAS = Path(__file__).resolve().parents[1] / "reports" / "tablas"

CONSULTAS = {
    # Retención sin la cohorte censurada (dic-2009) ni meses incompletos: 20,7 / 17,3 / 17,9 % en los meses 1, 6 y 12
    "retencion_promedio.csv": """
        SELECT mes_desde,
               CAST(AVG(tasa_retencion) AS DECIMAL(8,6)) AS retencion_promedio,
               CAST(SUM(clientes_activos) * 1.0 / SUM(tamano_cohorte) AS DECIMAL(8,6)) AS retencion_ponderada,
               COUNT(*) AS cohortes
        FROM rpt.cohorte_retencion
        WHERE censurada_izquierda = 0 AND mes_incompleto = 0 AND mes_desde IN (1, 3, 6, 12)
        GROUP BY mes_desde ORDER BY mes_desde""",
    # Pareto de clientes identificados (ingreso neto de mart.cliente_rfm)
    "pareto_clientes.csv": """
        WITH c AS (
            SELECT monto,
                   ROW_NUMBER() OVER (ORDER BY monto DESC) AS pos,
                   COUNT(*) OVER () AS total,
                   SUM(monto) OVER () AS monto_total,
                   SUM(monto) OVER (ORDER BY monto DESC ROWS UNBOUNDED PRECEDING) AS acumulado
            FROM mart.cliente_rfm)
        SELECT MAX(total) AS clientes,
               CAST(SUM(CASE WHEN pos <= total * 0.2 THEN monto END) / MAX(monto_total) AS DECIMAL(8,6)) AS pct_ingreso_top20,
               SUM(CASE WHEN pos <= total * 0.01 THEN 1 ELSE 0 END) AS clientes_top1,
               CAST(SUM(CASE WHEN pos <= total * 0.01 THEN monto END) / MAX(monto_total) AS DECIMAL(8,6)) AS pct_ingreso_top1,
               CAST(MIN(CASE WHEN acumulado >= monto_total * 0.8 THEN pos END) * 1.0 / MAX(total) AS DECIMAL(8,6)) AS pct_clientes_para_80
        FROM c""",
    # Mercados por ventas netas (Irlanda: 3,2 % de las ventas con 3 clientes)
    "mercados_top.csv": """
        SELECT TOP (10) p.pais_es AS pais, SUM(f.importe) AS ventas_netas,
               CAST(SUM(f.importe) / SUM(SUM(f.importe)) OVER () AS DECIMAL(8,6)) AS pct_ventas,
               COUNT(DISTINCT NULLIF(f.clave_cliente, -1)) AS clientes
        FROM dw.fact_linea AS f JOIN dw.dim_pais AS p ON p.clave_pais = f.clave_pais
        GROUP BY p.pais_es ORDER BY ventas_netas DESC""",
    # Tasa de devolución por país con al menos 50 mil GBP vendidos (España: 13,3 %)
    "devoluciones_por_pais.csv": """
        SELECT pais, importe_vendido, importe_devuelto,
               CAST(importe_devuelto / importe_vendido AS DECIMAL(8,6)) AS tasa_devolucion_importe
        FROM rpt.devoluciones_pais WHERE importe_vendido >= 50000
        ORDER BY tasa_devolucion_importe DESC""",
    # Plazo de la devolución (el 64 % del importe vuelve en los primeros 7 días)
    "devoluciones_plazo.csv": """
        SELECT rango, lineas, importe,
               CAST(importe / SUM(importe) OVER () AS DECIMAL(8,6)) AS pct_importe
        FROM rpt.devoluciones_tiempo ORDER BY orden""",
}


def main() -> None:
    TABLAS.mkdir(parents=True, exist_ok=True)
    for nombre, sql in CONSULTAS.items():
        df = consultar(sql)
        df.to_csv(TABLAS / nombre, index=False)
        print(f"{nombre}: {len(df)} filas")


if __name__ == "__main__":
    main()

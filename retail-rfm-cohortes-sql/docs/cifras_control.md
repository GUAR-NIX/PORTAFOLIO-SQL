# Cifras de control

Valores obtenidos en la ejecución real (SQL Server 2025 Express, 19-oct-2026). Si tu corrida no da estos números, algo cambió en la fuente o en el pipeline.

## Fuente (`data/cifras_control.json`, calculado del Excel con Python)

| Hoja | Filas | Unidades (`Quantity`) | Importe (`Quantity × Price`), GBP |
|---|---:|---:|---:|
| Year 2009-2010 | 525.461 | 5.432.041 | 9.539.484,634 |
| Year 2010-2011 | 541.910 | 5.176.451 | 9.747.765,934 |
| **Total** | **1.067.371** | **10.608.492** | **19.287.250,568** |

SHA-256 del Excel: `bcbe73b35f5b7babf197fb0cb983a11f5d9ff929078d4aa53d171b1f2df2e980`

## Limpieza (`limpio.factura_linea`)

| Motivo | Líneas | Importe, GBP |
|---|---:|---:|
| (entra al modelo) | 1.021.254 | 18.927.435,650 |
| DUPLICADO (22.523 entre hojas + 11.812 dentro de una hoja) | 34.335 | 431.716,870 |
| CODIGO_NO_PRODUCTO | 5.812 | 75.712,128 |
| MOVIMIENTO_INVENTARIO | 3.393 | 0,000 |
| PRECIO_CERO | 2.571 | 0,000 |
| AJUSTE_DEUDA | 6 | −147.614,080 |
| **Total = fuente** | **1.067.371** | **19.287.250,568** |

## Modelo y analítica

| Objeto | Valor |
|---|---:|
| `dw.fact_linea` | 1.021.254 líneas (17.914 devoluciones, 227.089 sin cliente) |
| `dw.dim_cliente` | 5.875 clientes + miembro −1 (23 solo tienen devoluciones) |
| `dw.dim_producto` · `dw.dim_pais` · `dw.dim_fecha` | 4.738 · 43 · 739 días |
| Facturas de venta | 39.516 |
| Ventas brutas · devoluciones · netas | £19.643.861,62 · £716.425,97 · £18.927.435,65 |
| `mart.cliente_rfm` | 5.852 clientes, fecha de corte 2011-12-10 |
| `mart.cohorte_mes` | 325 celdas (25 cohortes) |
| `mart.devolucion_linea` | 17.914 líneas |
| `mart.canasta_par` | 28.635 pares |
| `qa.sp_validar_calidad` | 27 OK, 0 en ALERTA |

-- Prueba de humo del CI: se ejecuta después de sql/01..06 y 08 sobre el fixture de 7 vuelos.
-- Cada ASSERT que falla detiene psql con error.
\set ON_ERROR_STOP on
DO $$
DECLARE
    v_motivos text[];
BEGIN
    ASSERT (SELECT estado = 'OK' AND filas_copiadas = 7 AND filas_tipadas = 7 FROM control.carga_mes WHERE anio_mes = 202401),
        'la carga del mes no quedó en OK con 7 filas';
    ASSERT (SELECT count(*) FROM dw.fact_vuelo) = 5, 'el hecho debe tener 5 vuelos';
    ASSERT (SELECT count(*) FROM dw.fact_vuelo_2024_01) = 5, 'los 5 vuelos deben estar en la partición de enero';
    ASSERT (SELECT count(*) FROM dw.fact_vuelo_fuera_de_rango) = 0, 'la partición DEFAULT debe estar vacía';
    ASSERT (SELECT sum(abs(diferencia)) FROM control.v_reconciliacion) = 0, 'copiadas debe ser hecho + cuarentena';

    SELECT array_agg(m ORDER BY m) INTO v_motivos
      FROM calidad.vuelo_cuarentena, unnest(motivos) m;
    ASSERT v_motivos = ARRAY['Q_DUPLICADO', 'Q_VELOCIDAD_IMPOSIBLE'], format('motivos de cuarentena: %s', v_motivos);
    ASSERT (SELECT vuelos FROM calidad.conteo_regla WHERE codigo = 'M_CANCELADO') = 1, 'un cancelado';
    ASSERT (SELECT vuelos FROM calidad.conteo_regla WHERE codigo = 'M_CRUZA_MEDIANOCHE') = 1, 'un cruce de medianoche';

    ASSERT (SELECT sum(programados) FROM dw.mv_puntualidad_diaria) = 5, 'la vista materializada debe cuadrar con el hecho';
    ASSERT (SELECT array_agg(n_tramo ORDER BY paso) FROM analisis.cadenas_retraso(date '2024-01-10', date '2024-01-10'))
           = ARRAY[2, 3]::bigint[], 'la cadena de N1CI debe ir del tramo 2 al 3';
    RAISE NOTICE 'Prueba de humo: OK';
END $$;

-- La carga es reanudable: repetir el rango no cambia nada.
CALL control.cargar_rango(2024, 1, 1);
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM stg.vuelo) = 7, 'recargar un mes en OK no debe duplicar filas';
END $$;

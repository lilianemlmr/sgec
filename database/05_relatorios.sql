-- =============================================================================
-- 05_relatorios.sql — Taxa de ocupação e dica de consistência nos relatórios
-- =============================================================================

-- Taxa de ocupação por espaço em um período [p_inicio, p_fim) (fim exclusivo)
--   horas_disponiveis = soma das janelas is_external_allowed de cada dia do período
--   horas_reservadas  = reservas APPROVED, recortadas para dentro do período
--   taxa_ocupacao     = reservadas / disponíveis (0 a ~1; NULL se não há janela)
-- Uma função (e não view) porque recebe parâmetros.
CREATE OR REPLACE FUNCTION fn_taxa_ocupacao(p_inicio date, p_fim date)
RETURNS TABLE (
  space_id          integer,
  space_name        text,
  horas_disponiveis numeric,
  horas_reservadas  numeric,
  taxa_ocupacao     numeric
)
LANGUAGE sql STABLE AS $$
  WITH dias AS (
    SELECT d::date AS dia
    FROM generate_series(p_inicio, p_fim - 1, interval '1 day') AS d
  ),
  janelas AS (
    SELECT sa.space_id,
           (dias.dia + sa.start_time) AT TIME ZONE 'America/Sao_Paulo' AS ini,
           (dias.dia + sa.end_time)   AT TIME ZONE 'America/Sao_Paulo' AS fim
    FROM dias
    JOIN space_availability sa
      ON sa.day_of_week = EXTRACT(dow FROM dias.dia)::int
     AND sa.is_external_allowed
  ),
  disp AS (
    SELECT space_id, SUM(EXTRACT(EPOCH FROM (fim - ini)) / 3600) AS horas
    FROM janelas
    GROUP BY space_id
  ),
  res AS (
    SELECT b.space_id,
           SUM(EXTRACT(EPOCH FROM (
             LEAST(b.end_datetime,   p_fim::timestamp    AT TIME ZONE 'America/Sao_Paulo')
           - GREATEST(b.start_datetime, p_inicio::timestamp AT TIME ZONE 'America/Sao_Paulo')
           )) / 3600) AS horas
    FROM bookings b
    WHERE b.status = 'APPROVED'
      AND b.start_datetime < (p_fim::timestamp    AT TIME ZONE 'America/Sao_Paulo')
      AND b.end_datetime   > (p_inicio::timestamp AT TIME ZONE 'America/Sao_Paulo')
    GROUP BY b.space_id
  )
  SELECT s.id,
         s.name,
         ROUND(COALESCE(disp.horas, 0)::numeric, 2),
         ROUND(COALESCE(res.horas, 0)::numeric, 2),
         ROUND(COALESCE(res.horas, 0)::numeric / NULLIF(disp.horas, 0)::numeric, 4)
  FROM spaces s
  LEFT JOIN disp ON disp.space_id = s.id
  LEFT JOIN res  ON res.space_id  = s.id
  WHERE s.is_active
  ORDER BY s.name;
$$;

-- -----------------------------------------------------------------------------
-- CONCORRÊNCIA NO RELATÓRIO
-- Um relatório roda várias consultas (ocupação, picos, perfil). Se alguém
-- aprovar uma reserva no meio, as consultas poderiam mostrar números de
-- "momentos" diferentes. Para ter uma foto única do banco, o backend abre a
-- transação assim (leitura não bloqueia nem é bloqueada por reservas):
--
--   BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
--     SELECT * FROM fn_taxa_ocupacao('2026-11-01', '2026-12-01');
--     SELECT * FROM vw_horarios_pico;
--     SELECT * FROM vw_perfil_solicitantes;
--   COMMIT;
--
-- Em REPEATABLE READ todas as consultas enxergam o mesmo snapshot, tirado na
-- primeira consulta. Não precisa de lock: o MVCC do Postgres cuida disso.
-- -----------------------------------------------------------------------------

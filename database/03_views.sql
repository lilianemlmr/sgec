-- =============================================================================
-- 03_views.sql — Views de apoio ao front e aos relatórios
-- Todas consideram o fuso America/Sao_Paulo para "dia da semana" e "hora".
-- =============================================================================

-- Fila de aprovação (painel do admin): pendentes, mais antigas primeiro -------
CREATE OR REPLACE VIEW vw_fila_aprovacao AS
SELECT b.id            AS booking_id,
       b.created_at,
       b.start_datetime,
       b.end_datetime,
       b.notes,
       s.id            AS space_id,
       s.name          AS space_name,
       s.type          AS space_type,
       u.id            AS user_id,
       u.name          AS user_name,
       u.email         AS user_email,
       c.trade_name    AS company_name
FROM bookings b
JOIN spaces s ON s.id = b.space_id
JOIN users  u ON u.id = b.user_id
LEFT JOIN companies c ON c.id = u.company_id
WHERE b.status = 'PENDING'
ORDER BY b.created_at;

-- Agenda ocupada (calendário do solicitante) ----------------------------------
-- Não expõe dados do solicitante: só mostra QUE o horário está ocupado.
CREATE OR REPLACE VIEW vw_agenda_ocupada AS
SELECT b.id AS booking_id,
       b.space_id,
       b.start_datetime,
       b.end_datetime,
       b.status                       -- PENDING = "em análise", APPROVED = "ocupado"
FROM bookings b
WHERE b.status IN ('PENDING', 'APPROVED');

-- Horas de uso por espaço/mês (só reservas aprovadas) -------------------------
-- Reserva que cruza a virada do mês é contada no mês em que começa.
CREATE OR REPLACE VIEW vw_horas_uso_mensal AS
SELECT s.id   AS space_id,
       s.name AS space_name,
       date_trunc('month', b.start_datetime AT TIME ZONE 'America/Sao_Paulo')::date AS mes,
       COUNT(*)                                                             AS reservas,
       ROUND(SUM(EXTRACT(EPOCH FROM (b.end_datetime - b.start_datetime)) / 3600)::numeric, 2) AS horas_uso
FROM bookings b
JOIN spaces s ON s.id = b.space_id
WHERE b.status = 'APPROVED'
GROUP BY s.id, s.name, 3;

-- Horários de pico: quantas reservas aprovadas cobrem cada hora do dia --------
-- Uma reserva de 9h às 11h conta na faixa das 9 e na das 10.
CREATE OR REPLACE VIEW vw_horarios_pico AS
SELECT s.id   AS space_id,
       s.name AS space_name,
       EXTRACT(dow  FROM h.hora)::int AS day_of_week,
       EXTRACT(hour FROM h.hora)::int AS hora,
       COUNT(*)                       AS reservas
FROM bookings b
JOIN spaces s ON s.id = b.space_id
CROSS JOIN LATERAL generate_series(
  date_trunc('hour', b.start_datetime AT TIME ZONE 'America/Sao_Paulo'),
  (b.end_datetime AT TIME ZONE 'America/Sao_Paulo') - interval '1 second',
  interval '1 hour'
) AS h(hora)
WHERE b.status = 'APPROVED'
GROUP BY s.id, s.name, 3, 4;

-- Perfil dos solicitantes (empresas e pessoas físicas) ------------------------
CREATE OR REPLACE VIEW vw_perfil_solicitantes AS
SELECT u.id                                   AS user_id,
       u.name                                 AS user_name,
       c.id                                   AS company_id,
       COALESCE(c.trade_name, c.corporate_name) AS company_name,
       CASE WHEN c.id IS NULL THEN 'PESSOA_FISICA' ELSE 'EMPRESA' END AS tipo,
       COUNT(b.id)                                         AS total_reservas,
       COUNT(b.id) FILTER (WHERE b.status = 'APPROVED')    AS aprovadas,
       COUNT(b.id) FILTER (WHERE b.status = 'REJECTED')    AS recusadas,
       COUNT(b.id) FILTER (WHERE b.status = 'CANCELLED')   AS canceladas,
       COUNT(b.id) FILTER (WHERE b.status = 'PENDING')     AS pendentes,
       ROUND(COALESCE(SUM(EXTRACT(EPOCH FROM (b.end_datetime - b.start_datetime)) / 3600)
             FILTER (WHERE b.status = 'APPROVED'), 0)::numeric, 2) AS horas_aprovadas
FROM users u
LEFT JOIN companies c ON c.id = u.company_id
LEFT JOIN bookings  b ON b.user_id = u.id
WHERE u.role = 'CLIENT'
GROUP BY u.id, u.name, c.id, c.trade_name, c.corporate_name;

-- Catálogo de espaços (tela "Catálogo de Espaços" do solicitante) --------------
-- Só espaços ativos; equipamentos vêm agregados em JSON: [{"name":..., "quantity":...}]
CREATE OR REPLACE VIEW vw_catalogo_espacos AS
SELECT s.id,
       s.name,
       s.type,
       s.capacity,
       s.description,
       s.terms_of_use,
       COALESCE(
         jsonb_agg(jsonb_build_object('name', e.name, 'quantity', e.quantity) ORDER BY e.name)
           FILTER (WHERE e.id IS NOT NULL),
         '[]'::jsonb
       ) AS equipamentos
FROM spaces s
LEFT JOIN space_equipment e ON e.space_id = s.id
WHERE s.is_active
GROUP BY s.id;

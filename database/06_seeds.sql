-- =============================================================================
-- 06_seeds.sql — Dados de teste (APENAS DESENVOLVIMENTO)
-- ⚠ Apaga tudo e recarrega (TRUNCATE). Não rode em banco com dados reais.
-- Todos os usuários têm a senha:  senha123   (hash bcrypt abaixo)
-- Datas fixas de nov/2026 (semana 02–06, 09–13 e 16–20) para os relatórios
-- terem histórico e a fila de aprovação ter pendências.
-- =============================================================================

TRUNCATE booking_status_history, bookings, space_availability, space_equipment, spaces, users, companies
  RESTART IDENTITY CASCADE;

-- Empresas (CNPJs válidos de teste) -------------------------------------------
INSERT INTO companies (corporate_name, trade_name, cnpj, phone, legal_rep_name, legal_rep_cpf) VALUES
  ('Alfa Tecnologia Ltda',           'Alfa Tech', '11222333000181', '(48) 3000-1111', 'Roberto Alfa',  '52998224725'),
  ('Beta Pesquisa e Análises S.A.',  'Beta Lab',  '34567890000130', '(48) 3000-2222', 'Helena Beta',   '12345678909');

-- Usuários --------------------------------------------------------------------
-- Hash bcrypt de "senha123" (custo 10)
INSERT INTO users (name, email, password_hash, role, cpf_cnpj, company_id)
SELECT v.name, v.email, '$2b$10$UMXfC0UXQnj0zlltL7/xGukdoiE0JbpD8Z9cuFPBfAdE3L541dasW',
       v.role, v.doc, c.id
FROM (VALUES
  ('Maria Gestora',    'gestor@sgec.local',    'ADMIN',     NULL,             NULL),
  ('Carlos Recepção',  'recepcao@sgec.local',  'RECEPTION', NULL,             NULL),
  ('Ana Autônoma',     'ana@exemplo.com',      'CLIENT',    '12345678909',    NULL),
  ('Paulo Pesquisador','paulo@exemplo.com',    'CLIENT',    '98765432100',    NULL),
  ('Bruno (Alfa Tech)','bruno@alfatech.com',   'CLIENT',    '11222333000181', '11222333000181'),
  ('Carla (Beta Lab)', 'carla@betalab.com',    'CLIENT',    '34567890000130', '34567890000130')
) AS v(name, email, role, doc, company_cnpj)
LEFT JOIN companies c ON c.cnpj = v.company_cnpj;

-- Espaços ---------------------------------------------------------------------
INSERT INTO spaces (name, type, capacity, description, terms_of_use, is_active) VALUES
  ('Coworking Open Space',      'COWORKING',    20, 'Estações compartilhadas com internet e café',
     'Manter o silêncio nas chamadas; devolver o espaço organizado.',                       true),
  ('Sala de Reunião A',         'MEETING_ROOM',  8, 'TV 55", quadro branco e videoconferência',
     'Proibido alimentos; apagar o quadro ao sair.',                                        true),
  ('Sala de Reunião B',         'MEETING_ROOM', 12, 'Mesa grande e projetor',
     'Proibido alimentos; desligar o projetor ao sair.',                                    true),
  ('Laboratório de Eletrônica', 'LAB',          10, 'Osciloscópios, fontes e kits de solda',
     'Uso de jaleco e óculos obrigatório; menores de idade só acompanhados.',               true),
  ('Laboratório de Biologia',   'LAB',           6, 'Microscópios e capela de fluxo laminar',
     'Descarte de material biológico conforme protocolo; EPI obrigatório.',                 true),
  ('Laboratório de Prototipagem 3D', 'LAB',      4, 'Em reforma — indisponível',
     NULL,                                                                                  false);

-- Equipamentos vinculados aos espaços -----------------------------------------
INSERT INTO space_equipment (space_id, name, quantity)
SELECT s.id, v.equip, v.qtd
FROM (VALUES
  ('Coworking Open Space',      'Estação de trabalho',   20),
  ('Coworking Open Space',      'Impressora',             1),
  ('Sala de Reunião A',         'TV 55"',                 1),
  ('Sala de Reunião A',         'Kit de videoconferência',1),
  ('Sala de Reunião B',         'Projetor',               1),
  ('Laboratório de Eletrônica', 'Osciloscópio',           4),
  ('Laboratório de Eletrônica', 'Kit de solda',           6),
  ('Laboratório de Eletrônica', 'Fonte de bancada',       5),
  ('Laboratório de Biologia',   'Microscópio',            3),
  ('Laboratório de Biologia',   'Capela de fluxo laminar',1)
) AS v(espaco, equip, qtd)
JOIN spaces s ON s.name = v.espaco;

-- Matriz de disponibilidade ---------------------------------------------------
-- Espaços comuns: seg–sex, 08:00–18:00 liberado ao público externo
INSERT INTO space_availability (space_id, day_of_week, start_time, end_time, is_external_allowed)
SELECT s.id, d, '08:00', '18:00', true
FROM spaces s, generate_series(1, 5) AS d
WHERE s.name IN ('Coworking Open Space', 'Sala de Reunião A', 'Sala de Reunião B', 'Laboratório de Eletrônica');

-- Coworking também abre sábado de manhã
INSERT INTO space_availability (space_id, day_of_week, start_time, end_time, is_external_allowed)
SELECT id, 6, '08:00', '12:00', true FROM spaces WHERE name = 'Coworking Open Space';

-- Lab de Biologia: externo só ter/qui (duas janelas); seg/qua/sex uso interno
INSERT INTO space_availability (space_id, day_of_week, start_time, end_time, is_external_allowed)
SELECT s.id, d, w.ini::time, w.fim::time, true
FROM spaces s, (VALUES (2), (4)) AS dias(d), (VALUES ('08:00','12:00'), ('14:00','18:00')) AS w(ini, fim)
WHERE s.name = 'Laboratório de Biologia';

INSERT INTO space_availability (space_id, day_of_week, start_time, end_time, is_external_allowed)
SELECT s.id, d, '08:00', '18:00', false
FROM spaces s, (VALUES (1), (3), (5)) AS dias(d)
WHERE s.name = 'Laboratório de Biologia';

-- Reservas --------------------------------------------------------------------
-- Entram todas como PENDING (comportamento normal do sistema) e depois o ADMIN
-- decide, passando pelo trigger de transição e pelo de histórico — assim a
-- tabela booking_status_history já nasce preenchida.
-- Obs.: a "Sala de Reunião B" fica livre de propósito (os testes usam ela).
CREATE TEMP TABLE _seed_reservas (
  espaco text, email text, ini timestamptz, fim timestamptz,
  obs text, status_final text, motivo text
);
INSERT INTO _seed_reservas VALUES
  -- semana passada (02–06/11) e retrasada (09–13/11): histórico aprovado
  ('Sala de Reunião A',         'ana@exemplo.com',    '2026-11-03 09:00-03', '2026-11-03 11:00-03', 'Reunião com cliente',                  'APPROVED',  NULL),
  ('Laboratório de Eletrônica', 'paulo@exemplo.com',  '2026-11-04 14:00-03', '2026-11-04 17:00-03', 'Precisa de osciloscópio e kit de solda', 'APPROVED',  NULL),
  ('Coworking Open Space',      'bruno@alfatech.com', '2026-11-05 08:00-03', '2026-11-05 12:00-03', 'Equipe de 5 pessoas',                  'APPROVED',  NULL),
  ('Laboratório de Biologia',   'carla@betalab.com',  '2026-11-05 14:00-03', '2026-11-05 18:00-03', 'Análise de amostras',                  'APPROVED',  NULL),
  ('Sala de Reunião A',         'bruno@alfatech.com', '2026-11-10 10:00-03', '2026-11-10 12:00-03', 'Planejamento trimestral',               'APPROVED',  NULL),
  ('Coworking Open Space',      'ana@exemplo.com',    '2026-11-10 08:00-03', '2026-11-10 17:00-03', NULL,                                   'APPROVED',  NULL),
  ('Laboratório de Eletrônica', 'bruno@alfatech.com', '2026-11-11 08:00-03', '2026-11-11 12:00-03', 'Testes de protótipo',                  'APPROVED',  NULL),
  ('Laboratório de Biologia',   'carla@betalab.com',  '2026-11-12 08:00-03', '2026-11-12 12:00-03', 'Cultura de células',                   'APPROVED',  NULL),
  ('Sala de Reunião A',         'paulo@exemplo.com',  '2026-11-13 14:00-03', '2026-11-13 16:00-03', 'Orientação de projeto',                'APPROVED',  NULL),
  -- recusada e cancelada
  ('Laboratório de Eletrônica', 'ana@exemplo.com',    '2026-11-12 14:00-03', '2026-11-12 18:00-03', 'Montagem de placa',                    'REJECTED',  'Equipamento em calibração nesse período'),
  ('Coworking Open Space',      'paulo@exemplo.com',  '2026-11-13 08:00-03', '2026-11-13 12:00-03', NULL,                                   'CANCELLED', NULL),
  -- semana que vem (16–20/11): aprovadas e pendentes
  ('Sala de Reunião A',         'carla@betalab.com',  '2026-11-17 09:00-03', '2026-11-17 11:00-03', 'Apresentação de resultados',           'APPROVED',  NULL),
  ('Laboratório de Eletrônica', 'paulo@exemplo.com',  '2026-11-18 08:00-03', '2026-11-18 11:00-03', 'Kit de solda e multímetro',            'PENDING',   NULL),
  ('Laboratório de Biologia',   'carla@betalab.com',  '2026-11-19 08:00-03', '2026-11-19 12:00-03', 'Microscópio x2',                       'PENDING',   NULL),
  ('Coworking Open Space',      'bruno@alfatech.com', '2026-11-19 08:00-03', '2026-11-19 18:00-03', 'Sprint da equipe',                     'PENDING',   NULL),
  ('Sala de Reunião A',         'ana@exemplo.com',    '2026-11-20 15:00-03', '2026-11-20 16:00-03', NULL,                                   'PENDING',   NULL);

INSERT INTO bookings (space_id, user_id, start_datetime, end_datetime, notes)
SELECT s.id, u.id, r.ini, r.fim, r.obs
FROM _seed_reservas r
JOIN spaces s ON s.name  = r.espaco
JOIN users  u ON u.email = r.email
ORDER BY r.ini;

-- A partir daqui "quem está agindo" é a gestora
SELECT set_config('app.current_user_id', (SELECT id::text FROM users WHERE email = 'gestor@sgec.local'), false);

UPDATE bookings b
   SET status = r.status_final,
       rejection_reason = r.motivo
  FROM _seed_reservas r
  JOIN spaces s ON s.name = r.espaco
 WHERE b.space_id = s.id
   AND b.start_datetime = r.ini
   AND r.status_final <> 'PENDING';

SELECT set_config('app.current_user_id', '', false);
DROP TABLE _seed_reservas;

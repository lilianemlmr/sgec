-- =============================================================================
-- 07_testes.sql — Testes automáticos das regras do banco
-- Rodar DEPOIS do 06_seeds.sql:   psql -d sgec -v ON_ERROR_STOP=1 -f 07_testes.sql
-- Tudo roda dentro de uma transação que termina em ROLLBACK: não suja o banco.
-- Se alguma regra falhar, o script para com "TESTE FALHOU: ...".
-- =============================================================================
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
\echo '--- Rodando testes do SGEC ---'

BEGIN;

-- Dia de teste: terça-feira da PRÓXIMA semana (sempre no futuro e dentro da
-- janela seg–sex 08–18 da Sala de Reunião B, que não tem reservas nos seeds)
CREATE TEMP TABLE _t AS
SELECT (date_trunc('week', now() AT TIME ZONE 'America/Sao_Paulo')::date + 8) AS terca;

-- Helper: executa um SQL e exige que ele falhe com o SQLSTATE esperado
CREATE FUNCTION pg_temp.esperar_erro(p_sql text, p_estado text, p_nome text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE EXCEPTION 'TESTE FALHOU [%]: nenhum erro (esperado %)', p_nome, p_estado USING ERRCODE = 'TF001';
EXCEPTION WHEN OTHERS THEN
  IF SQLSTATE = 'TF001' THEN RAISE; END IF;
  IF SQLSTATE <> p_estado THEN
    RAISE EXCEPTION 'TESTE FALHOU [%]: esperado %, veio % (%)', p_nome, p_estado, SQLSTATE, SQLERRM USING ERRCODE = 'TF001';
  END IF;
  RAISE NOTICE 'ok  %', p_nome;
END $$;

CREATE FUNCTION pg_temp.afirmar(p_ok boolean, p_nome text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'TESTE FALHOU [%]', p_nome USING ERRCODE = 'TF001';
  END IF;
  RAISE NOTICE 'ok  %', p_nome;
END $$;

-- Atalhos de ids usados nos SQLs dos testes
CREATE FUNCTION pg_temp.uid(p_email text) RETURNS integer LANGUAGE sql AS
  $$ SELECT id FROM users WHERE email = p_email $$;
CREATE FUNCTION pg_temp.sid(p_nome text) RETURNS integer LANGUAGE sql AS
  $$ SELECT id FROM spaces WHERE name = p_nome $$;
CREATE FUNCTION pg_temp.hora(p_hora text) RETURNS timestamptz LANGUAGE sql AS
  $$ SELECT ((SELECT terca FROM _t) + p_hora::time) AT TIME ZONE 'America/Sao_Paulo' $$;

-- 1. Validação de CPF/CNPJ ----------------------------------------------------
SELECT pg_temp.afirmar(fn_valida_cpf('52998224725'),          'CPF válido aceito');
SELECT pg_temp.afirmar(NOT fn_valida_cpf('52998224726'),      'CPF com dígito errado rejeitado');
SELECT pg_temp.afirmar(NOT fn_valida_cpf('11111111111'),      'CPF com dígitos repetidos rejeitado');
SELECT pg_temp.afirmar(fn_valida_cnpj('11222333000181'),      'CNPJ válido aceito');
SELECT pg_temp.afirmar(NOT fn_valida_cnpj('11222333000182'),  'CNPJ com dígito errado rejeitado');
SELECT pg_temp.esperar_erro(
  $$INSERT INTO users (name, email, password_hash, cpf_cnpj) VALUES ('X','x@x.com','h','12345678900')$$,
  '23514', 'usuário com CPF inválido bloqueado');
SELECT pg_temp.esperar_erro(
  $$INSERT INTO users (name, email, password_hash, role) VALUES ('X','y@x.com','h','CLIENT')$$,
  '23514', 'solicitante sem documento bloqueado');
SELECT pg_temp.esperar_erro(
  $$INSERT INTO users (name, email, password_hash, cpf_cnpj) VALUES ('X','ANA@exemplo.com','h','52998224725')$$,
  '23505', 'e-mail duplicado (case-insensitive) bloqueado');

-- 2. Criação e histórico ------------------------------------------------------
CREATE TEMP TABLE _r AS
SELECT * FROM criar_reserva(pg_temp.uid('ana@exemplo.com'), pg_temp.sid('Sala de Reunião B'),
                            pg_temp.hora('14:00'), pg_temp.hora('16:00'), 'teste');

SELECT pg_temp.afirmar((SELECT status FROM _r) = 'PENDING', 'reserva nasce PENDING');
SELECT pg_temp.afirmar((SELECT count(*) FROM booking_status_history WHERE booking_id = (SELECT id FROM _r)) = 1,
                       'histórico registra a criação');

-- 3. Conflito de horário ------------------------------------------------------
SELECT pg_temp.esperar_erro(
  format('SELECT criar_reserva(%s, %s, %L, %L)', pg_temp.uid('paulo@exemplo.com'), pg_temp.sid('Sala de Reunião B'),
         pg_temp.hora('15:00'), pg_temp.hora('17:00')),
  'SG007', 'sobreposição parcial bloqueada');
SELECT pg_temp.esperar_erro(
  format('SELECT criar_reserva(%s, %s, %L, %L)', pg_temp.uid('paulo@exemplo.com'), pg_temp.sid('Sala de Reunião B'),
         pg_temp.hora('14:30'), pg_temp.hora('15:30')),
  'SG007', 'reserva contida em outra bloqueada');
SELECT pg_temp.esperar_erro(
  format('INSERT INTO bookings (space_id,user_id,start_datetime,end_datetime) VALUES (%s,%s,%L,%L)',
         pg_temp.sid('Sala de Reunião B'), pg_temp.uid('paulo@exemplo.com'), pg_temp.hora('14:00'), pg_temp.hora('16:00')),
  '23P01', 'INSERT direto também respeita a exclusion constraint');

-- Reservas encostadas (fim = início) NÃO conflitam
SELECT criar_reserva(pg_temp.uid('paulo@exemplo.com'), pg_temp.sid('Sala de Reunião B'), pg_temp.hora('16:00'), pg_temp.hora('17:00'));
SELECT criar_reserva(pg_temp.uid('paulo@exemplo.com'), pg_temp.sid('Sala de Reunião B'), pg_temp.hora('13:00'), pg_temp.hora('14:00'));
SELECT pg_temp.afirmar(true, 'reservas encostadas (16–17 e 13–14) permitidas');

-- Mesmo horário em OUTRO espaço é permitido
SELECT criar_reserva(pg_temp.uid('paulo@exemplo.com'), pg_temp.sid('Sala de Reunião A'), pg_temp.hora('14:00'), pg_temp.hora('16:00'));
SELECT pg_temp.afirmar(true, 'mesmo horário em outro espaço permitido');

-- 4. Regras de disponibilidade e espaço ---------------------------------------
-- hora em outro dia: p_dias a partir da terça de teste (+1 = quarta, +4 = sábado, +5 = domingo)
CREATE FUNCTION pg_temp.hora_dia(p_dias integer, p_hora text) RETURNS timestamptz LANGUAGE sql AS
  $$ SELECT ((SELECT terca FROM _t) + p_dias + p_hora::time) AT TIME ZONE 'America/Sao_Paulo' $$;

SELECT pg_temp.esperar_erro(
  format('SELECT criar_reserva(%s, %s, %L, %L)', pg_temp.uid('ana@exemplo.com'), pg_temp.sid('Sala de Reunião B'),
         pg_temp.hora('17:00'), pg_temp.hora('19:00')),
  'SG002', 'reserva terminando fora da janela (19h) bloqueada');
SELECT pg_temp.esperar_erro(
  format('SELECT criar_reserva(%s, %s, %L, %L)', pg_temp.uid('ana@exemplo.com'), pg_temp.sid('Sala de Reunião B'),
         pg_temp.hora_dia(5, '10:00'), pg_temp.hora_dia(5, '11:00')),
  'SG002', 'domingo (sem janela) bloqueado');
SELECT pg_temp.esperar_erro(
  format('SELECT criar_reserva(%s, %s, %L, %L)', pg_temp.uid('ana@exemplo.com'), pg_temp.sid('Laboratório de Biologia'),
         pg_temp.hora_dia(1, '09:00'), pg_temp.hora_dia(1, '10:00')),
  'SG002', 'janela com is_external_allowed = false bloqueada para solicitante');
SELECT pg_temp.esperar_erro(
  format('SELECT criar_reserva(%s, %s, %L, %L)', pg_temp.uid('ana@exemplo.com'), pg_temp.sid('Sala de Reunião B'),
         pg_temp.hora('17:00'), pg_temp.hora_dia(1, '09:00')),
  'SG002', 'reserva que atravessa a meia-noite bloqueada');
SELECT pg_temp.esperar_erro(
  format('SELECT criar_reserva(%s, %s, %L, %L)', pg_temp.uid('ana@exemplo.com'), pg_temp.sid('Laboratório de Prototipagem 3D'),
         pg_temp.hora('09:00'), pg_temp.hora('10:00')),
  'SG003', 'espaço inativo bloqueado');
SELECT pg_temp.esperar_erro(
  format('SELECT criar_reserva(%s, %s, %L, %L)', pg_temp.uid('ana@exemplo.com'), pg_temp.sid('Sala de Reunião B'),
         now() - interval '2 days', now() - interval '1 day'),
  'SG004', 'reserva no passado bloqueada');
SELECT pg_temp.esperar_erro(
  format('INSERT INTO bookings (space_id,user_id,start_datetime,end_datetime) VALUES (%s,%s,%L,%L)',
         pg_temp.sid('Sala de Reunião A'), pg_temp.uid('ana@exemplo.com'), pg_temp.hora('10:00'), pg_temp.hora('09:00')),
  '23514', 'fim antes do início bloqueado');

-- ADMIN pode reservar fora da janela externa (uso interno), ex.: Lab Biologia na quarta
SELECT criar_reserva(pg_temp.uid('gestor@sgec.local'), pg_temp.sid('Laboratório de Biologia'),
                     pg_temp.hora_dia(1, '09:00'), pg_temp.hora_dia(1, '10:00'), 'uso interno');
SELECT pg_temp.afirmar(true, 'ADMIN pode reservar em janela interna');

-- 5. Aprovar / recusar / cancelar ---------------------------------------------
SELECT pg_temp.esperar_erro(
  format('SELECT aprovar_reserva(%s, %s)', (SELECT id FROM _r), pg_temp.uid('ana@exemplo.com')),
  'SG006', 'solicitante não pode aprovar');
SELECT pg_temp.esperar_erro(
  format('SELECT recusar_reserva(%s, %s, %L)', (SELECT id FROM _r), pg_temp.uid('gestor@sgec.local'), '   '),
  'SG008', 'recusa sem justificativa bloqueada');
SELECT pg_temp.esperar_erro(
  format('UPDATE bookings SET status = %L WHERE id = %s', 'REJECTED', (SELECT id FROM _r)),
  '23514', 'UPDATE direto para REJECTED sem motivo bloqueado (CHECK)');
SELECT pg_temp.esperar_erro(
  format('SELECT aprovar_reserva(%s, %s)', 999999, pg_temp.uid('gestor@sgec.local')),
  'SG005', 'reserva inexistente');

SELECT aprovar_reserva((SELECT id FROM _r), pg_temp.uid('gestor@sgec.local'));
SELECT pg_temp.afirmar((SELECT status FROM bookings WHERE id = (SELECT id FROM _r)) = 'APPROVED', 'ADMIN aprova reserva pendente');
SELECT pg_temp.afirmar(
  (SELECT changed_by FROM booking_status_history WHERE booking_id = (SELECT id FROM _r) AND new_status = 'APPROVED')
    = pg_temp.uid('gestor@sgec.local'),
  'histórico registra QUEM aprovou');

-- Cancelamento: outro solicitante não pode; o dono pode; o slot é liberado
SELECT pg_temp.esperar_erro(
  format('SELECT cancelar_reserva(%s, %s)', (SELECT id FROM _r), pg_temp.uid('paulo@exemplo.com')),
  'SG006', 'outro solicitante não pode cancelar');
SELECT cancelar_reserva((SELECT id FROM _r), pg_temp.uid('ana@exemplo.com'));
SELECT pg_temp.afirmar((SELECT status FROM bookings WHERE id = (SELECT id FROM _r)) = 'CANCELLED', 'dono cancela a própria reserva');

-- CANCELLED é estado final: não volta a ser aprovada
SELECT pg_temp.esperar_erro(
  format('SELECT aprovar_reserva(%s, %s)', (SELECT id FROM _r), pg_temp.uid('gestor@sgec.local')),
  'SG001', 'transição CANCELLED → APPROVED bloqueada');

-- Slot liberado: outra pessoa reserva o mesmo horário
SELECT criar_reserva(pg_temp.uid('carla@betalab.com'), pg_temp.sid('Sala de Reunião B'), pg_temp.hora('14:00'), pg_temp.hora('16:00'));
SELECT pg_temp.afirmar(true, 'horário cancelado volta a ficar livre');

-- Recusa com justificativa: grava motivo e histórico
CREATE TEMP TABLE _r2 AS
SELECT * FROM criar_reserva(pg_temp.uid('ana@exemplo.com'), pg_temp.sid('Sala de Reunião B'),
                            pg_temp.hora('09:00'), pg_temp.hora('10:00'));
SELECT recusar_reserva((SELECT id FROM _r2), pg_temp.uid('gestor@sgec.local'), 'Sala reservada para evento interno');
SELECT pg_temp.afirmar(
  (SELECT reason FROM booking_status_history
    WHERE booking_id = (SELECT id FROM _r2) AND new_status = 'REJECTED') = 'Sala reservada para evento interno',
  'histórico guarda a justificativa da recusa');

-- 6. Histórico imutável -------------------------------------------------------
SELECT pg_temp.esperar_erro('UPDATE booking_status_history SET new_status = ''PENDING''', 'SG006', 'UPDATE no histórico bloqueado');
SELECT pg_temp.esperar_erro('DELETE FROM booking_status_history', 'SG006', 'DELETE no histórico bloqueado');
SELECT pg_temp.esperar_erro(
  format('DELETE FROM bookings WHERE id = %s', (SELECT id FROM _r)),
  '23503', 'reserva com histórico não pode ser apagada');

-- 7. Relatórios e views -------------------------------------------------------
SELECT pg_temp.afirmar(
  (SELECT count(*) FROM fn_taxa_ocupacao('2026-11-01', '2026-12-01') WHERE taxa_ocupacao BETWEEN 0 AND 1) = 5,
  'taxa de ocupação: 5 espaços ativos, todas entre 0 e 1');
SELECT pg_temp.afirmar((SELECT count(*) FROM vw_fila_aprovacao) >= 4, 'fila de aprovação lista pendentes');
SELECT pg_temp.afirmar((SELECT count(*) FROM vw_horas_uso_mensal) > 0, 'view de horas de uso responde');
SELECT pg_temp.afirmar((SELECT count(*) FROM vw_horarios_pico) > 0, 'view de horários de pico responde');
SELECT pg_temp.afirmar((SELECT count(*) FROM vw_perfil_solicitantes) = 4, 'perfil: 4 solicitantes');
SELECT pg_temp.afirmar((SELECT count(*) FROM vw_agenda_ocupada WHERE status NOT IN ('PENDING','APPROVED')) = 0,
                       'agenda ocupada só mostra PENDING/APPROVED');

-- 8. Responsável legal, equipamentos e catálogo -------------------------------
SELECT pg_temp.esperar_erro(
  $$INSERT INTO companies (corporate_name, cnpj, legal_rep_name, legal_rep_cpf)
    VALUES ('Gama Ltda', '04252011000110', 'Fulano', '12345678900')$$,
  '23514', 'empresa com CPF do responsável inválido bloqueada');
SELECT pg_temp.esperar_erro(
  $$INSERT INTO companies (corporate_name, cnpj, legal_rep_name, legal_rep_cpf)
    VALUES ('Gama Ltda', '04252011000110', '   ', '52998224725')$$,
  '23514', 'empresa com nome do responsável em branco bloqueada');
SELECT pg_temp.esperar_erro(
  format('INSERT INTO space_equipment (space_id, name) VALUES (%s, %L)', pg_temp.sid('Laboratório de Eletrônica'), 'Osciloscópio'),
  '23505', 'equipamento duplicado no mesmo espaço bloqueado');
SELECT pg_temp.esperar_erro(
  format('INSERT INTO space_equipment (space_id, name, quantity) VALUES (%s, %L, 0)', pg_temp.sid('Sala de Reunião B'), 'Lousa'),
  '23514', 'quantidade de equipamento zero bloqueada');
SELECT pg_temp.afirmar(
  (SELECT jsonb_array_length(equipamentos) FROM vw_catalogo_espacos WHERE name = 'Laboratório de Eletrônica') = 3,
  'catálogo lista os 3 equipamentos do Lab de Eletrônica');
SELECT pg_temp.afirmar(
  (SELECT count(*) FROM vw_catalogo_espacos WHERE name = 'Laboratório de Prototipagem 3D') = 0,
  'catálogo omite espaço inativo');

ROLLBACK;
\echo '--- Todos os testes passaram (alterações revertidas com ROLLBACK) ---'

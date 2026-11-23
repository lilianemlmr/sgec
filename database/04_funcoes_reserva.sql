-- =============================================================================
-- 04_funcoes_reserva.sql — Operações transacionais de reserva
-- Cada função roda dentro da transação do chamador (no Node: BEGIN ... COMMIT).
-- Se der erro, o chamador faz ROLLBACK e nada fica pela metade.
-- Todas gravam em app.current_user_id quem está agindo (usado pelo trigger de
-- histórico). set_config(..., true) vale só até o fim da transação atual.
-- =============================================================================

-- Criar reserva ---------------------------------------------------------------
-- Regras: espaço ativo, início no futuro, solicitante externo só dentro das
-- janelas is_external_allowed (mesmo dia local), sem sobreposição (garantido
-- pela EXCLUSION CONSTRAINT mesmo com concorrência).
CREATE OR REPLACE FUNCTION criar_reserva(
  p_user_id   integer,
  p_space_id  integer,
  p_inicio    timestamptz,
  p_fim       timestamptz,
  p_observacoes text DEFAULT NULL
) RETURNS bookings
LANGUAGE plpgsql AS $$
DECLARE
  v_tz      constant text := 'America/Sao_Paulo';
  v_user    users%ROWTYPE;
  v_space   spaces%ROWTYPE;
  v_booking bookings%ROWTYPE;
  v_ini_loc timestamp := p_inicio AT TIME ZONE v_tz;
  v_fim_loc timestamp := p_fim    AT TIME ZONE v_tz;
BEGIN
  SELECT * INTO v_user FROM users WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuário % não encontrado', p_user_id USING ERRCODE = 'SG006';
  END IF;
  PERFORM set_config('app.current_user_id', p_user_id::text, true);

  -- FOR SHARE: impede que o espaço seja desativado/alterado até o fim desta transação
  SELECT * INTO v_space FROM spaces WHERE id = p_space_id FOR SHARE;
  IF NOT FOUND OR NOT v_space.is_active THEN
    RAISE EXCEPTION 'Espaço % inexistente ou inativo', p_space_id USING ERRCODE = 'SG003';
  END IF;

  IF p_inicio <= now() THEN
    RAISE EXCEPTION 'O horário de início precisa ser futuro' USING ERRCODE = 'SG004';
  END IF;

  -- Solicitante externo: precisa caber inteiro numa janela liberada (mesmo dia)
  IF v_user.role = 'CLIENT' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM space_availability sa
      WHERE sa.space_id = p_space_id
        AND sa.is_external_allowed
        AND sa.day_of_week = EXTRACT(dow FROM v_ini_loc)::int
        AND v_ini_loc::date = v_fim_loc::date
        AND v_ini_loc::time >= sa.start_time
        AND v_fim_loc::time <= sa.end_time
    ) THEN
      RAISE EXCEPTION 'Horário fora da disponibilidade liberada para uso externo'
        USING ERRCODE = 'SG002';
    END IF;
  END IF;

  BEGIN
    INSERT INTO bookings (space_id, user_id, start_datetime, end_datetime, notes)
    VALUES (p_space_id, p_user_id, p_inicio, p_fim, p_observacoes)
    RETURNING * INTO v_booking;
  EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Já existe reserva (pendente ou aprovada) nesse horário'
      USING ERRCODE = 'SG007';
  END;

  RETURN v_booking;
END $$;

-- Aprovar ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aprovar_reserva(p_booking_id integer, p_admin_id integer)
RETURNS bookings
LANGUAGE plpgsql AS $$
DECLARE
  v_booking bookings%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_admin_id AND role = 'ADMIN') THEN
    RAISE EXCEPTION 'Apenas ADMIN pode aprovar reservas' USING ERRCODE = 'SG006';
  END IF;
  PERFORM set_config('app.current_user_id', p_admin_id::text, true);

  -- FOR UPDATE: se dois admins agirem na mesma reserva, o segundo espera o primeiro
  -- e então cai na regra de transição (SG001) em vez de sobrescrever.
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva % não encontrada', p_booking_id USING ERRCODE = 'SG005';
  END IF;

  UPDATE bookings SET status = 'APPROVED' WHERE id = p_booking_id RETURNING * INTO v_booking;
  RETURN v_booking;
END $$;

-- Recusar (justificativa obrigatória) -----------------------------------------
CREATE OR REPLACE FUNCTION recusar_reserva(p_booking_id integer, p_admin_id integer, p_motivo text)
RETURNS bookings
LANGUAGE plpgsql AS $$
DECLARE
  v_booking bookings%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_admin_id AND role = 'ADMIN') THEN
    RAISE EXCEPTION 'Apenas ADMIN pode recusar reservas' USING ERRCODE = 'SG006';
  END IF;
  IF length(btrim(coalesce(p_motivo, ''))) = 0 THEN
    RAISE EXCEPTION 'A justificativa da recusa é obrigatória' USING ERRCODE = 'SG008';
  END IF;
  PERFORM set_config('app.current_user_id', p_admin_id::text, true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva % não encontrada', p_booking_id USING ERRCODE = 'SG005';
  END IF;

  UPDATE bookings
     SET status = 'REJECTED', rejection_reason = btrim(p_motivo)
   WHERE id = p_booking_id
  RETURNING * INTO v_booking;
  RETURN v_booking;
END $$;

-- Cancelar (dono da reserva ou ADMIN) -----------------------------------------
CREATE OR REPLACE FUNCTION cancelar_reserva(p_booking_id integer, p_user_id integer)
RETURNS bookings
LANGUAGE plpgsql AS $$
DECLARE
  v_booking bookings%ROWTYPE;
  v_role    text;
BEGIN
  SELECT role INTO v_role FROM users WHERE id = p_user_id;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Usuário % não encontrado', p_user_id USING ERRCODE = 'SG006';
  END IF;
  PERFORM set_config('app.current_user_id', p_user_id::text, true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva % não encontrada', p_booking_id USING ERRCODE = 'SG005';
  END IF;

  IF v_booking.user_id <> p_user_id AND v_role <> 'ADMIN' THEN
    RAISE EXCEPTION 'Só o dono da reserva ou um ADMIN pode cancelar' USING ERRCODE = 'SG006';
  END IF;
  IF v_booking.status = 'APPROVED' AND v_booking.start_datetime <= now() THEN
    RAISE EXCEPTION 'Reserva já iniciada não pode ser cancelada' USING ERRCODE = 'SG004';
  END IF;

  UPDATE bookings SET status = 'CANCELLED' WHERE id = p_booking_id RETURNING * INTO v_booking;
  RETURN v_booking;
END $$;

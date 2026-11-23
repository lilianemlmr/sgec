-- =============================================================================
-- 02_triggers.sql — Triggers do SGEC
--   1) updated_at automático em bookings
--   2) validação de transição de status
--   3) histórico de status (auditoria)
--   4) histórico imutável (sem UPDATE/DELETE)
-- Códigos de erro próprios (SQLSTATE) usados no projeto — ver README:
--   SG001 transição inválida | SG002 fora da disponibilidade | SG003 espaço inativo
--   SG004 horário no passado | SG005 reserva não encontrada | SG006 sem permissão
--   SG007 conflito de horário | SG008 justificativa obrigatória
-- =============================================================================

-- 1) updated_at ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_bookings_updated_at
  BEFORE UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 2) Transições permitidas ----------------------------------------------------
--    PENDING  → APPROVED | REJECTED | CANCELLED
--    APPROVED → CANCELLED
--    REJECTED e CANCELLED são finais.
CREATE OR REPLACE FUNCTION fn_bookings_valida_transicao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF (OLD.status = 'PENDING'  AND NEW.status IN ('APPROVED', 'REJECTED', 'CANCELLED'))
  OR (OLD.status = 'APPROVED' AND NEW.status = 'CANCELLED') THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Transição de status inválida: % -> %', OLD.status, NEW.status
    USING ERRCODE = 'SG001';
END $$;

CREATE TRIGGER trg_bookings_valida_transicao
  BEFORE UPDATE OF status ON bookings
  FOR EACH ROW EXECUTE FUNCTION fn_bookings_valida_transicao();

-- 3) Histórico de status ------------------------------------------------------
--    Quem fez a mudança vem da variável de sessão app.current_user_id, que o
--    backend (ou as funções de 04_funcoes_reserva.sql) define com set_config()
--    dentro da transação. Se não vier, na criação usamos o dono da reserva.
CREATE OR REPLACE FUNCTION fn_bookings_historico() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_user integer := nullif(current_setting('app.current_user_id', true), '')::integer;
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO booking_status_history (booking_id, old_status, new_status, changed_by)
    VALUES (NEW.id, NULL, NEW.status, COALESCE(v_user, NEW.user_id));
  ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO booking_status_history (booking_id, old_status, new_status, changed_by, reason)
    VALUES (NEW.id, OLD.status, NEW.status, v_user,
            CASE WHEN NEW.status = 'REJECTED' THEN NEW.rejection_reason END);
  END IF;
  RETURN NULL;   -- AFTER trigger: o retorno é ignorado
END $$;

CREATE TRIGGER trg_bookings_historico
  AFTER INSERT OR UPDATE OF status ON bookings
  FOR EACH ROW EXECUTE FUNCTION fn_bookings_historico();

-- 4) Histórico imutável -------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_history_imutavel() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'booking_status_history é somente-inserção (rastreabilidade)'
    USING ERRCODE = 'SG006';
END $$;

CREATE TRIGGER trg_history_imutavel
  BEFORE UPDATE OR DELETE ON booking_status_history
  FOR EACH ROW EXECUTE FUNCTION fn_history_imutavel();

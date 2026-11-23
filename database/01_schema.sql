-- =============================================================================
-- 01_schema.sql — Estrutura do banco do SGEC (PostgreSQL 14+)
-- Cria: extensão, funções de validação (CPF/CNPJ), tabelas, constraints e índices.
-- Rodar primeiro. Ordem completa: 01 → 02 → 03 → 04 → 05 → 06 (ver 00_run_all.sql)
-- =============================================================================

-- btree_gist permite misturar "=" (inteiros) e "&&" (sobreposição de intervalos)
-- no mesmo índice GiST. É isso que viabiliza a EXCLUSION CONSTRAINT de reservas.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- -----------------------------------------------------------------------------
-- 1. Funções de validação de documentos (usadas em CHECK)
--    Recebem só dígitos (sem pontos/traço/barra). O backend deve limpar a
--    máscara antes de gravar.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_valida_cpf(p text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d int[];
  soma int;
  i int;
  dv1 int;
  dv2 int;
BEGIN
  IF p IS NULL OR p !~ '^[0-9]{11}$' THEN RETURN false; END IF;
  IF p ~ '^(.)\1{10}$' THEN RETURN false; END IF;      -- 11111111111 etc.
  FOR i IN 1..11 LOOP d[i] := substr(p, i, 1)::int; END LOOP;

  soma := 0;
  FOR i IN 1..9 LOOP soma := soma + d[i] * (11 - i); END LOOP;
  dv1 := (soma * 10) % 11; IF dv1 = 10 THEN dv1 := 0; END IF;
  IF dv1 <> d[10] THEN RETURN false; END IF;

  soma := 0;
  FOR i IN 1..10 LOOP soma := soma + d[i] * (12 - i); END LOOP;
  dv2 := (soma * 10) % 11; IF dv2 = 10 THEN dv2 := 0; END IF;
  RETURN dv2 = d[11];
END $$;

CREATE OR REPLACE FUNCTION fn_valida_cnpj(p text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  w1 int[] := ARRAY[5,4,3,2,9,8,7,6,5,4,3,2];
  w2 int[] := ARRAY[6,5,4,3,2,9,8,7,6,5,4,3,2];
  d int[];
  soma int;
  i int;
  r int;
  dv1 int;
  dv2 int;
BEGIN
  IF p IS NULL OR p !~ '^[0-9]{14}$' THEN RETURN false; END IF;
  IF p ~ '^(.)\1{13}$' THEN RETURN false; END IF;
  FOR i IN 1..14 LOOP d[i] := substr(p, i, 1)::int; END LOOP;

  soma := 0;
  FOR i IN 1..12 LOOP soma := soma + d[i] * w1[i]; END LOOP;
  r := soma % 11; dv1 := CASE WHEN r < 2 THEN 0 ELSE 11 - r END;
  IF dv1 <> d[13] THEN RETURN false; END IF;

  soma := 0;
  FOR i IN 1..13 LOOP soma := soma + d[i] * w2[i]; END LOOP;
  r := soma % 11; dv2 := CASE WHEN r < 2 THEN 0 ELSE 11 - r END;
  RETURN dv2 = d[14];
END $$;

-- -----------------------------------------------------------------------------
-- 2. companies — empresas solicitantes
-- -----------------------------------------------------------------------------
CREATE TABLE companies (
  id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  corporate_name  text        NOT NULL,                 -- razão social
  trade_name      text,                                 -- nome fantasia
  cnpj            varchar(14) NOT NULL,
  phone           text,
  legal_rep_name  text        NOT NULL,                 -- responsável legal
  legal_rep_cpf   varchar(11) NOT NULL,                 -- CPF do responsável legal
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_companies_cnpj UNIQUE (cnpj),
  CONSTRAINT ck_companies_cnpj CHECK (fn_valida_cnpj(cnpj)),
  CONSTRAINT ck_companies_rep_nome CHECK (length(btrim(legal_rep_name)) > 0),
  CONSTRAINT ck_companies_rep_cpf CHECK (fn_valida_cpf(legal_rep_cpf))
);

-- -----------------------------------------------------------------------------
-- 3. users — usuários internos e externos
--    cpf_cnpj: documento de login do solicitante (CPF se pessoa física, CNPJ se
--    empresa). Único: uma conta por documento. ADMIN/RECEPTION podem não ter.
-- -----------------------------------------------------------------------------
CREATE TABLE users (
  id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name           text        NOT NULL,
  email          text        NOT NULL,
  password_hash  text        NOT NULL,                  -- NUNCA a senha pura (bcrypt/argon2)
  role           text        NOT NULL DEFAULT 'CLIENT',
  cpf_cnpj       varchar(14),
  company_id     integer     REFERENCES companies(id),  -- NO ACTION: não apaga empresa com usuários
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_users_role CHECK (role IN ('ADMIN', 'CLIENT', 'RECEPTION')),
  CONSTRAINT ck_users_email CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  CONSTRAINT ck_users_documento CHECK (
    cpf_cnpj IS NULL OR fn_valida_cpf(cpf_cnpj) OR fn_valida_cnpj(cpf_cnpj)
  ),
  -- Solicitante externo sempre tem documento
  CONSTRAINT ck_users_client_documento CHECK (role <> 'CLIENT' OR cpf_cnpj IS NOT NULL),
  CONSTRAINT uq_users_cpf_cnpj UNIQUE (cpf_cnpj)        -- NULLs não conflitam entre si
);
-- E-mail único sem diferenciar maiúsculas/minúsculas
CREATE UNIQUE INDEX uq_users_email_lower ON users (lower(email));
CREATE INDEX ix_users_company ON users (company_id);    -- FKs não ganham índice automático

-- -----------------------------------------------------------------------------
-- 4. spaces — salas, bancadas e laboratórios
-- -----------------------------------------------------------------------------
CREATE TABLE spaces (
  id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name         text        NOT NULL,
  type         text        NOT NULL,
  capacity     integer     NOT NULL,
  description  text,
  terms_of_use text,                                    -- termos de uso exibidos ao solicitante
  is_active    boolean     NOT NULL DEFAULT true,       -- "desativar" em vez de apagar
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_spaces_name UNIQUE (name),
  CONSTRAINT ck_spaces_type CHECK (type IN ('COWORKING', 'LAB', 'MEETING_ROOM')),
  CONSTRAINT ck_spaces_capacity CHECK (capacity > 0)
);

-- -----------------------------------------------------------------------------
-- 4b. space_equipment — equipamentos vinculados a cada espaço
--     (tabela própria em vez de uma coluna de texto: dá para listar, contar e,
--     no futuro, anexar equipamentos específicos a uma reserva)
-- -----------------------------------------------------------------------------
CREATE TABLE space_equipment (
  id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  space_id  integer NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  name      text    NOT NULL,
  quantity  integer NOT NULL DEFAULT 1,
  notes     text,
  CONSTRAINT uq_space_equipment UNIQUE (space_id, name),  -- também serve de índice por space_id
  CONSTRAINT ck_space_equipment_nome CHECK (length(btrim(name)) > 0),
  CONSTRAINT ck_space_equipment_qtd  CHECK (quantity > 0)
);

-- -----------------------------------------------------------------------------
-- 5. space_availability — matriz semanal de janelas por espaço
--    day_of_week segue o padrão do Postgres/JS: 0 = domingo ... 6 = sábado.
--    Horários são "de relógio" no fuso America/Sao_Paulo.
-- -----------------------------------------------------------------------------
CREATE TABLE space_availability (
  id                  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  space_id            integer  NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  day_of_week         smallint NOT NULL,
  start_time          time     NOT NULL,
  end_time            time     NOT NULL,
  is_external_allowed boolean  NOT NULL DEFAULT true,
  CONSTRAINT ck_availability_dow CHECK (day_of_week BETWEEN 0 AND 6),
  CONSTRAINT ck_availability_horas CHECK (end_time > start_time),
  -- Duas janelas do mesmo espaço no mesmo dia não podem se sobrepor.
  -- (date '2000-01-01' + time) só transforma "hora" em um timestamp qualquer
  -- para poder usar tsrange; a data em si é irrelevante.
  CONSTRAINT ex_availability_sem_sobreposicao EXCLUDE USING gist (
    space_id    WITH =,
    day_of_week WITH =,
    tsrange(date '2000-01-01' + start_time, date '2000-01-01' + end_time) WITH &&
  )
);

-- -----------------------------------------------------------------------------
-- 6. bookings — solicitações/reservas
-- -----------------------------------------------------------------------------
CREATE TABLE bookings (
  id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  space_id         integer     NOT NULL REFERENCES spaces(id),
  user_id          integer     NOT NULL REFERENCES users(id),
  start_datetime   timestamptz NOT NULL,
  end_datetime     timestamptz NOT NULL,
  status           text        NOT NULL DEFAULT 'PENDING',
  rejection_reason text,
  notes            text,                                 -- observações operacionais do solicitante
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_bookings_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')),
  CONSTRAINT ck_bookings_periodo CHECK (end_datetime > start_datetime),
  -- Recusa exige justificativa (não vazia)
  CONSTRAINT ck_bookings_justificativa CHECK (
    status <> 'REJECTED' OR length(btrim(coalesce(rejection_reason, ''))) > 0
  ),
  -- ★ REGRA PRINCIPAL: no mesmo espaço, dois períodos "ativos" não podem se sobrepor.
  --   '[)' = início inclusivo, fim exclusivo → 10:00–11:00 e 11:00–12:00 NÃO conflitam.
  --   Só PENDING e APPROVED ocupam o horário; REJECTED/CANCELLED liberam o slot.
  --   O banco garante isso mesmo com dois usuários reservando ao mesmo tempo.
  CONSTRAINT ex_bookings_sem_sobreposicao EXCLUDE USING gist (
    space_id WITH =,
    tstzrange(start_datetime, end_datetime, '[)') WITH &&
  ) WHERE (status IN ('PENDING', 'APPROVED'))
);

CREATE INDEX ix_bookings_user      ON bookings (user_id, created_at DESC);   -- "Meus agendamentos"
CREATE INDEX ix_bookings_space_ini ON bookings (space_id, start_datetime);   -- agenda/relatórios por espaço
CREATE INDEX ix_bookings_fila      ON bookings (created_at) WHERE status = 'PENDING'; -- fila de aprovação

-- -----------------------------------------------------------------------------
-- 7. booking_status_history — trilha de auditoria (preenchida por trigger)
-- -----------------------------------------------------------------------------
CREATE TABLE booking_status_history (
  id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  booking_id  integer     NOT NULL REFERENCES bookings(id),
  old_status  text,                                      -- NULL na criação
  new_status  text        NOT NULL,
  changed_by  integer     REFERENCES users(id),
  reason      text,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_history_new_status CHECK (new_status IN ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')),
  CONSTRAINT ck_history_old_status CHECK (old_status IS NULL OR old_status IN ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED'))
);
CREATE INDEX ix_history_booking ON booking_status_history (booking_id, changed_at);

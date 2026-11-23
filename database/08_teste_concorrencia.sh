#!/usr/bin/env bash
# =============================================================================
# 08_teste_concorrencia.sh — Duas pessoas reservando o MESMO horário ao mesmo tempo
#
# Mostra que a exclusion constraint resolve a "corrida": a sessão A abre a
# transação e reserva; a sessão B tenta o mesmo horário ENQUANTO A ainda não deu
# COMMIT. B fica esperando (bloqueada) e, quando A confirma, B falha com SG007.
# Nenhum caso termina com duas reservas no mesmo horário.
#
# Uso (banco já com 01..06 carregados). Usa as variáveis padrão do psql:
#   PGHOST=localhost PGUSER=postgres PGDATABASE=sgec ./08_teste_concorrencia.sh
# Ao final a reserva de teste é cancelada (fica no histórico como CANCELLED).
# =============================================================================
set -uo pipefail

PSQL="psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose"
SLEEP_A=3   # tempo que A segura a transação aberta

# Terça-feira da próxima semana (sempre futura e dentro da janela seg–sex 08–18)
DIA=$($PSQL -At -c "SELECT date_trunc('week', now() AT TIME ZONE 'America/Sao_Paulo')::date + 8")
INI="('$DIA 10:00'::timestamp AT TIME ZONE 'America/Sao_Paulo')"
FIM="('$DIA 11:00'::timestamp AT TIME ZONE 'America/Sao_Paulo')"
RESERVA="SELECT id FROM criar_reserva((SELECT id FROM users WHERE email = '%s'), (SELECT id FROM spaces WHERE name = 'Sala de Reunião B'), $INI, $FIM)"

echo "Slot disputado: Sala de Reunião B, $DIA 10:00–11:00"

# Sessão A: reserva e segura a transação aberta por alguns segundos
( $PSQL -At <<SQL
BEGIN;
$(printf "$RESERVA" 'ana@exemplo.com');
SELECT pg_sleep($SLEEP_A);
COMMIT;
SQL
) > /tmp/sgec_sessao_a.out 2>&1 &
PID_A=$!

sleep 1   # garante que A já inseriu e ainda não commitou

# Sessão B: mesmo horário, durante a transação de A
INICIO=$(date +%s)
$PSQL -At -c "$(printf "$RESERVA" 'paulo@exemplo.com')" > /tmp/sgec_sessao_b.out 2>&1
FIM_B=$(date +%s)
wait $PID_A

ESPERA=$((FIM_B - INICIO))
echo "--- Sessão A: $(tr '\n' ' ' < /tmp/sgec_sessao_a.out)"
echo "--- Sessão B: $(tr '\n' ' ' < /tmp/sgec_sessao_b.out)"
echo "--- B ficou esperando ~${ESPERA}s por A"

FALHAS=0
grep -qE '^[0-9]+$' /tmp/sgec_sessao_a.out || { echo "FALHOU: A deveria ter conseguido reservar"; FALHAS=1; }
grep -q 'SG007' /tmp/sgec_sessao_b.out      || { echo "FALHOU: B deveria ter recebido SG007"; FALHAS=1; }
[ "$ESPERA" -ge 2 ]                          || { echo "FALHOU: B não ficou bloqueada esperando A"; FALHAS=1; }

ATIVAS=$($PSQL -At -c "SELECT count(*) FROM bookings b JOIN spaces s ON s.id = b.space_id
  WHERE s.name = 'Sala de Reunião B' AND b.status IN ('PENDING','APPROVED')
    AND b.start_datetime = $INI")
[ "$ATIVAS" = "1" ] || { echo "FALHOU: esperado 1 reserva ativa no slot, achei $ATIVAS"; FALHAS=1; }

# Limpeza: cancela a reserva de teste (libera o slot)
$PSQL -c "SELECT cancelar_reserva(b.id, (SELECT id FROM users WHERE email = 'gestor@sgec.local'))
  FROM bookings b JOIN spaces s ON s.id = b.space_id
  WHERE s.name = 'Sala de Reunião B' AND b.start_datetime = $INI AND b.status = 'PENDING'" > /dev/null

if [ "$FALHAS" = "0" ]; then
  echo "OK: apenas uma reserva ativa no slot; a segunda foi barrada com SG007."
else
  exit 1
fi

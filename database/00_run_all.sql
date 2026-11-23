-- =============================================================================
-- 00_run_all.sql — Cria o banco do zero, na ordem certa
-- Uso (de dentro da pasta database/):
--   createdb sgec
--   psql -d sgec -v ON_ERROR_STOP=1 -f 00_run_all.sql
-- ⚠ Inclui os seeds (06), que apagam os dados. Só para ambiente de desenvolvimento.
-- Os testes (07 e 08) ficam de fora: rode depois, separadamente.
-- =============================================================================
\i 01_schema.sql
\i 02_triggers.sql
\i 03_views.sql
\i 04_funcoes_reserva.sql
\i 05_relatorios.sql
\i 06_seeds.sql

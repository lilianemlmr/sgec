# SGEC — Banco de dados (PostgreSQL)

Scripts do banco do Sistema de Gestão de Espaços Compartilhados. Testado no PostgreSQL 16 (funciona do 14 em diante). A extensão `btree_gist` vem junto com o Postgres.

## Como rodar

```bash
cd database
createdb sgec
psql -d sgec -v ON_ERROR_STOP=1 -f 00_run_all.sql     # cria tudo + dados de teste
psql -d sgec -v ON_ERROR_STOP=1 -f 07_testes.sql      # 49 testes de regras (termina em ROLLBACK)
./08_teste_concorrencia.sh                            # duas sessões disputando o mesmo horário (bash)
```

> ⚠ `06_seeds.sql` apaga os dados (TRUNCATE). Use só em desenvolvimento. Senha de todos os usuários de teste: `senha123`.

| Arquivo | O que tem |
|---|---|
| `01_schema.sql` | 7 tabelas, constraints, índices, validação de CPF/CNPJ, exclusion constraints |
| `02_triggers.sql` | `updated_at`, regra de transição de status, histórico de status, histórico imutável |
| `03_views.sql` | Fila de aprovação, agenda ocupada, horas de uso, horários de pico, perfil dos solicitantes, catálogo de espaços |
| `04_funcoes_reserva.sql` | `criar_reserva`, `aprovar_reserva`, `recusar_reserva`, `cancelar_reserva` |
| `05_relatorios.sql` | `fn_taxa_ocupacao(inicio, fim)` + como manter relatórios consistentes |
| `06_seeds.sql` | 2 empresas, 6 usuários, 6 espaços com equipamentos e termos de uso, janelas de disponibilidade, 16 reservas |
| `07_testes.sql` / `08_teste_concorrencia.sh` | Testes automáticos |

## Modelo ER

```mermaid
erDiagram
  companies ||--o{ users : "tem"
  users ||--o{ bookings : "solicita"
  spaces ||--o{ bookings : "recebe"
  spaces ||--o{ space_availability : "define janelas"
  spaces ||--o{ space_equipment : "possui"
  bookings ||--o{ booking_status_history : "registra"
  users ||--o{ booking_status_history : "changed_by"

  companies { int id PK; text corporate_name; text trade_name; varchar cnpj UK; text phone; text legal_rep_name; varchar legal_rep_cpf }
  users { int id PK; text name; text email UK; text password_hash; text role; varchar cpf_cnpj UK; int company_id FK }
  spaces { int id PK; text name UK; text type; int capacity; text description; text terms_of_use; bool is_active }
  space_equipment { int id PK; int space_id FK; text name; int quantity; text notes }
  space_availability { int id PK; int space_id FK; smallint day_of_week; time start_time; time end_time; bool is_external_allowed }
  bookings { int id PK; int space_id FK; int user_id FK; timestamptz start_datetime; timestamptz end_datetime; text status; text rejection_reason; text notes }
  booking_status_history { int id PK; int booking_id FK; text old_status; text new_status; int changed_by FK; text reason; timestamptz changed_at }
```

## O que o banco garante (sem depender do código)

- **Sem reservas sobrepostas** — `ex_bookings_sem_sobreposicao` (01_schema.sql, tabela `bookings`). Vale só para `PENDING` e `APPROVED`; recusada/cancelada libera o horário. Intervalo `[)`: 10–11h e 11–12h não conflitam. Funciona mesmo com dois usuários reservando ao mesmo tempo.
- **Justificativa obrigatória na recusa** — `ck_bookings_justificativa`.
- **Transições de status válidas** — trigger em `02_triggers.sql`: `PENDING → APPROVED/REJECTED/CANCELLED`, `APPROVED → CANCELLED`; o resto é final.
- **Histórico automático e imutável** — `booking_status_history` é preenchida por trigger e não aceita UPDATE/DELETE.
- **CPF/CNPJ válidos** (com dígito verificador), inclusive o CPF do responsável legal da empresa, e-mail único sem diferenciar maiúsculas, janelas de disponibilidade sem sobreposição.
- **Equipamentos por espaço** sem duplicar nome e com quantidade maior que zero (`space_equipment`). A tela de catálogo lê tudo pronto em `vw_catalogo_espacos` (equipamentos em JSON).

## Contrato para o back-end

Use as funções dentro de uma transação. Elas já gravam quem fez a ação no histórico.

```js
const client = await pool.connect();
try {
  await client.query('BEGIN');
  const { rows } = await client.query(
    'SELECT * FROM criar_reserva($1, $2, $3, $4, $5)',   // user, space, início, fim, observações
    [userId, spaceId, '2026-11-24T10:00:00-03:00', '2026-11-24T11:00:00-03:00', 'Reunião']
  );
  await client.query('COMMIT');
  return rows[0];
} catch (e) {
  await client.query('ROLLBACK');
  // e.code traz o SQLSTATE: veja a tabela abaixo
} finally { client.release(); }
```

- `aprovar_reserva(booking_id, admin_id)`, `recusar_reserva(booking_id, admin_id, motivo)`, `cancelar_reserva(booking_id, user_id)` — todas retornam a linha de `bookings`.
- Use sempre `SELECT * FROM criar_reserva(...)`. Evite `SELECT (criar_reserva(...)).*`: o Postgres executa a função uma vez por coluna.
- Datas: envie ISO 8601 **com fuso** (`-03:00`). Documentos (CPF/CNPJ): só dígitos, sem máscara.
- Se o back-end preferir fazer `INSERT` direto em `bookings`, a sobreposição continua barrada (erro `23P01`), mas as regras de disponibilidade/espaço ativo/passado só existem em `criar_reserva`.

| SQLSTATE | Significado | Sugestão HTTP |
|---|---|---|
| `SG001` | Transição de status inválida | 409 |
| `SG002` | Fora da janela liberada para uso externo | 422 |
| `SG003` | Espaço inexistente ou inativo | 404 / 422 |
| `SG004` | Horário no passado / reserva já iniciada | 422 |
| `SG005` | Reserva não encontrada | 404 |
| `SG006` | Sem permissão (ex.: não-admin aprovando) | 403 |
| `SG007` | Conflito de horário | 409 |
| `SG008` | Justificativa da recusa obrigatória | 400 |
| `23505` | Duplicado (e-mail, CPF/CNPJ, nome do espaço) | 409 |
| `23514` | Violou um CHECK (CPF inválido, fim antes do início…) | 422 |

**Relatórios** — para os números de vários endpoints baterem entre si, rode as consultas numa transação `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; ... COMMIT;` (exemplo em `05_relatorios.sql`). `fn_taxa_ocupacao('2026-11-01','2026-12-01')` devolve horas disponíveis, reservadas e taxa por espaço (fim do período é exclusivo).

## Decisões que o grupo pode revisar

1. **Pendente ocupa o horário.** Uma reserva `PENDING` já bloqueia o slot para outros, para não aprovar duas pessoas no mesmo horário. Se a equipe preferir que só `APPROVED` bloqueie, é trocar o `WHERE` da constraint.
2. **Buffer de 15 min entre reservas** (melhoria sugerida na especificação) **não foi implementado**. Dá para fazer, mas exige mexer na constraint ou numa regra extra em `criar_reserva`.
3. **Empresa.** O cadastro exige nome e CPF do responsável legal (`legal_rep_name`, `legal_rep_cpf`); o back-end precisa enviar os dois ao criar uma empresa.
4. **Documento do usuário.** `users.cpf_cnpj` guarda o documento de login: CPF para pessoa física, CNPJ para empresa (com `company_id` preenchido). É único: uma conta por documento. O validador só aceita CNPJ numérico; os novos CNPJs alfanuméricos não passam.
5. **Janelas externas.** `criar_reserva` só valida a janela `is_external_allowed` para quem tem perfil `CLIENT`; `ADMIN` pode reservar uso interno. Reserva de solicitante precisa começar e terminar no mesmo dia.
6. **Fuso.** Dia da semana e horas das janelas são interpretados em `America/Sao_Paulo`.
7. **Bloqueios de manutenção/eventos** (citados na spec) ainda não têm tabela própria; hoje dá para representar com janela `is_external_allowed = false`.

## Git (regras do grupo)

Branch `db/modelo-inicial` (a partir da `main` atualizada), commits no formato `db: cria schema com exclusion constraint de reservas`, PR para a `main`. Os scripts vão em `database/`.

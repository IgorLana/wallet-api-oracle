# C08 — Auditoria de saldo e imutabilidade do extrato

## Escopo

Migration `db/migration/owner/V6__wallet_triggers.sql`, aplicada com o usuário
`WALLET_OWNER` no PDB `FREEPDB1`, após a V5 do package.

- `TRG_WALLET_TRANSACTION_IMMUTABLE`: trigger **BEFORE UPDATE OR DELETE**,
  em nível de comando, que levanta `ORA-20030`. Não bloqueia INSERT, pois o
  package precisa registrar novas transações válidas.
- `TRG_WALLET_BALANCE_AUDIT`: trigger **AFTER UPDATE OF balance FOR EACH ROW**
  com condição `WHEN (OLD.balance <> NEW.balance)`. Insere na tabela do schema
  `WALLET_AUDIT` na mesma transação que atualizou o saldo.

## Fluxo de auditoria

1. `PKG_WALLET.REGISTER_TRANSACTION` registra `WALLET_TRANSACTION` e atualiza
   `WALLET.balance` junto com `last_transaction_id`.
2. A trigger de saldo recebe os pseudorregistros `:OLD` e `:NEW`.
3. Se o saldo realmente mudou, grava o ID da carteira, saldo anterior, saldo
   novo, timestamp `SYSTIMESTAMP`, usuário da sessão (`SESSION_USER`) e,
   se o identificador da última transação também mudou, o novo ID.
4. O `COMMIT` ou `ROLLBACK` é controlado pelo chamador; a trigger não executa
   transação autônoma. Logo, o registro de auditoria acompanha a operação.

Rejeições por saldo insuficiente não alteram `WALLET.balance`, portanto não
produzem auditoria de alteração de saldo. Elas são registradas em
`WALLET_OPERATION_REQUEST` pela V5.

## Por que o ID da auditoria pode ficar sem transaction_id?

Se alguém com privilégio suficiente executar `UPDATE wallet SET balance = ...`
sem alterar `last_transaction_id`, o ID anterior não será reutilizado na
trilha de auditoria; a trigger gravará `transaction_id = NULL`.

**Limitação:** esta regra reduz atribuições falsas, mas não autentica a origem
da transação. Um usuário privilegiado que alterar também `last_transaction_id`
para outro ID válido poderá influenciar a correlação. É uma limitação a
registrar na documentação, não uma proteção contra administradores.

## Imutabilidade: garantias e limites

- Com a trigger habilitada, `UPDATE`/`DELETE` no extrato são rejeitados,
  inclusive quando tentados por SQL direto. A trigger é de nível de comando,
  então bloqueia até um UPDATE/DELETE que não encontre linhas.
- A conta `WALLET_APP` também não recebe DML direto nas tabelas; suas escritas
  devem passar pelo package com `AUTHID DEFINER`.
- Não é uma garantia contra `TRUNCATE`, `DROP`, `ALTER TRIGGER DISABLE`,
  privilégios administrativos, nem contra `INSERT` direto feito por uma conta
  com autorização de inserção. Banco e credenciais devem ser protegidos.
- Não alteramos a V1 da auditoria, que já concedeu ao `WALLET_OWNER` somente
  `INSERT` em `BALANCE_AUDIT` e `SELECT` em `SEQ_BALANCE_AUDIT`.

## Como executar

Na raiz do projeto, após confirmar que V5 do C07 está aplicada:

```bash
bash db/scripts/migrate.sh
bash db/scripts/verify-c08.sh
```

O segundo script consulta dados em `WALLET_OWNER` e `WALLET_AUDIT`, por isso
utiliza `SYSDBA` local **apenas para teste**. A aplicação continua utilizando
`WALLET_APP`. Ele cria carteira, créditos e débitos dentro de uma transação,
valida os registros, testa modificações diretas e termina com `ROLLBACK`.

O script comprova:

- triggers válidas e habilitadas;
- crédito 0 → 100 gera uma auditoria associada ao lançamento;
- débito 100 → 60 gera outra auditoria associada;
- débito rejeitado não altera o saldo nem cria auditoria;
- alteração de metadados ou UPDATE que mantém o mesmo saldo não gera auditoria;
- UPDATE direto de saldo gera auditoria sem associar transação antiga;
- UPDATE/DELETE do extrato retornam `-20030`;
- ROLLBACK remove carteira, lançamentos e auditorias de teste.

## Diagnóstico

Se uma trigger aparecer como `INVALID`:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;
SELECT name, type, line, position, text
  FROM dba_errors
 WHERE owner = 'WALLET_OWNER'
   AND name IN ('TRG_WALLET_BALANCE_AUDIT',
                'TRG_WALLET_TRANSACTION_IMMUTABLE')
 ORDER BY name, sequence;
```

A migration Oracle contém DDL com commits implícitos. **Não edite a V6 após
aplicá-la**; uma mudança futura deve ser uma nova migration (V7, V8, ...).

## Próximas validações

O smoke test do C08 não substitui testes de integração com múltiplas sessões
Oracle (concorrência e retry após COMMIT), nem a revisão final da semântica de
`RAISE_APPLICATION_ERROR` para tentativas rejeitadas do C07.

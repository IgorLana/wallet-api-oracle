# C07 — Creditos, debitos e concorrencia no Oracle

> Status: implementacao inicial do caso de uso, ainda sem triggers (C08) e sem a integracao HTTP (C09). Este documento reflete **V5__pkg_wallet_transactions.sql**.

## 1. Objetivo

Implementar `WALLET_OWNER.PKG_WALLET.REGISTER_TRANSACTION` no Oracle Free (PDB `FREEPDB1`) garantindo, nos estados confirmados:

- saldo de carteira nunca negativo;
- operacoes na mesma carteira serializadas por lock pessimista;
- chave de idempotencia unica globalmente;
- replay de operacoes aplicadas com seu resultado historico;
- persistencia de rejeicoes por saldo insuficiente (sem gravar lancamento no extrato);
- extrato, saldo e solicitacao gravados numa unica transacao;
- Java nao recebe grants de DML direto nas tabelas.

## 2. Contrato do package no C07

A procedure `CREATE_WALLET` introduzida no C06 permanece igual. A nova procedure possui:

```sql
PROCEDURE register_transaction(
    p_wallet_id       IN  NUMBER,
    p_idempotency_key IN  VARCHAR2,
    p_type            IN  VARCHAR2, -- CREDIT ou DEBIT
    p_amount          IN  NUMBER,
    o_transaction_id  OUT NUMBER,
    o_balance_after   OUT NUMBER,
    o_result_status   OUT VARCHAR2, -- APPLIED ou REJECTED
    o_rejection_code  OUT VARCHAR2, -- INSUFFICIENT_FUNDS ou NULL
    o_completed_at    OUT TIMESTAMP WITH TIME ZONE,
    o_replayed        OUT VARCHAR2  -- Y ou N
);
```

`o_balance_after` e `o_transaction_id` sao `NULL` quando a tentativa foi rejeitada. O resultado de `REJECTED` fica registrado em `WALLET_OPERATION_REQUEST` e usa o timestamp `completed_at` original no replay. Para `APPLIED`, os OUTs de identificador e saldo historico vem de `WALLET_TRANSACTION`.

## 3. Ordem da execucao

1. Validar carteira, tipo, valor (>0 e ate duas casas) e chave (1-100 caracteres, sem espacos externos).
2. Bloquear a linha da carteira com `SELECT balance ... FOR UPDATE WAIT 5`.
3. Ler `WALLET_OPERATION_REQUEST` pela chave. Se existir, comparar **carteira + tipo + valor** e devolver replay ou erro -20005.
4. Se for um novo debito maior que o saldo, inserir somente `WALLET_OPERATION_REQUEST` com `REJECTED` e `INSUFFICIENT_FUNDS`.
5. Senao, calcular novo saldo, inserir `WALLET_OPERATION_REQUEST` como `APPLIED`, inserir `WALLET_TRANSACTION` e atualizar `WALLET`.
6. Retornar todos os OUTs. O package **nao faz COMMIT/ROLLBACK**; cabe ao chamador terminar a transacao corretamente.

### Por que travar antes de verificar a chave?

Se duas chamadas chegarem para a **mesma carteira**, a segunda espera a primeira liberar o lock. Em `READ COMMITTED`, a consulta seguinte pode ver a solicitacao confirmada e retornar replay. Se as chamadas usarem **carteiras diferentes** com a mesma chave, a PK global em `WALLET_OPERATION_REQUEST` impede a duplicacao. Uma insercao concorrente que encontrar `DUP_VAL_ON_INDEX` e traduzida para -20005 (conflito). O tratamento exato de bloqueios sera testado com duas sessoes no C10.

### Por que o extrato nao registra REJECTED?

A tabela `WALLET_TRANSACTION` representa movimento financeiro que realmente alterou saldo. Uma tentativa recusada nao movimentou dinheiro e aparece apenas na tabela de solicitacoes.

## 4. Decisao sobre erros de saldo insuficiente

**Escolha especifica do C07:** ao detectar saldo insuficiente, a procedure retorna `o_result_status='REJECTED'` e `o_rejection_code='INSUFFICIENT_FUNDS'`, sem emitir `RAISE_APPLICATION_ERROR(-20004)` nesse mesmo fluxo.

Motivo: queremos persistir a rejeicao **na mesma transacao** e permitir que um retry preserve o erro original. Se a procedure gerar uma excecao e o Spring executar rollback, o registro de rejeicao nao persistiria. Nao usamos `PRAGMA AUTONOMOUS_TRANSACTION` nem `COMMIT` dentro da procedure, pois quebrariam a fronteira transacional e complicariam a integridade.

**Trade-off frente ao enunciado:** o teste solicita `RAISE_APPLICATION_ERROR` para erros de negocio. Nosso package o usa para dados invalidos, wallet inexistente, conflito de idempotencia e timeout de lock, mas trata saldo insuficiente como **resultado de negocio**. No C09, a camada HTTP devera COMMITAR o resultado e traduzi-lo para `422 INSUFFICIENT_FUNDS`. Essa diferenca precisa ser defendida no `DECISIONS.md` e pode requerer revisao antes da entrega final.

No momento, `-20004` permanece reservado na specification para documentar a convencao do erro de saldo insuficiente, embora **nao seja levantado** pela procedure de debito.

## 5. Mapeamento de erros da procedure

| Codigo | Condicao | Efeito |
|---|---|---|
| -20001 | Valor <= 0, >2 casas ou fora da precisao | Excecao; nenhuma nova solicitacao confirmada |
| -20002 | Tipo diferente de CREDIT / DEBIT | Excecao |
| -20003 | Carteira invalida/inexistente | Excecao |
| -20005 | Chave existente com payload diferente ou colisao concorrente | Excecao |
| -20006 | Lock indisponivel apos WAIT 5 | Excecao transitoria |
| -20007 | Chave nula, vazia, >100 ou com espacos externos | Excecao |
| -20008 | Nome de titular invalido (create_wallet) | Excecao |
| -20009 | Solicitacao existente em PENDING ou status inesperado | Excecao de integridade/estado |
| Resultado REJECTED | Debito sem saldo | Resultado estruturado a confirmar; API futura retorna HTTP 422 |

## 6. Transacao e atomicidade

Para um debito aplicado, `INSERT OPERATION_REQUEST`, `INSERT WALLET_TRANSACTION` e `UPDATE WALLET` ocorrem na **mesma transacao Oracle**. O `LAST_TRANSACTION_ID` e atualizado junto com o saldo para a futura trigger C08 poder associar o evento de auditoria. Ate C08, a tabela BALANCE_AUDIT ainda nao sera populada automaticamente.

Uma transacao Java `@Transactional` devera executar COMMIT em resultado valido (`APPLIED` **ou** `REJECTED`) e ROLLBACK em falhas inesperadas. O controller podera devolver HTTP 422 **depois** de a rejeicao ter sido confirmada, sem lancar uma excecao que marque o metodo transacional para rollback.

A trigger de extrato imutavel, a trigger de auditoria e a protecao contra alteracoes diretas ainda serao acrescentadas no C08.

## 7. Como testar C07

```bash
bash db/scripts/migrate.sh
bash db/scripts/verify-c07.sh
```

O script testa como `WALLET_APP` (sem DML direto): credito de 50, debito de 30, rejeicao de outro debito de 30, novo credito de 100, replay da rejeicao e do debito original, conflito de payload, valor com tres casas, tipo e chave invalidos, carteira invalida, extrato com tres transacoes e rollback final.

O smoke test **nao executa COMMIT**, por isso nao deixa carteiras de teste no banco. Ele **nao comprova por si so** o comportamento com sessoes concorrentes e commits diferentes. Esses cenarios requerem testes de integracao reais (C10), usando ao menos duas conexoes e commit/rollback.

## 8. Criterios de aceite

- Flyway OWNER na V5; package e body VALID no Oracle.
- `WALLET_APP` executa `REGISTER_TRANSACTION` sem `INSERT/UPDATE` nas tabelas.
- Credito e debito valido alteram saldo e geram exatamente um lancamento.
- Tentativa de debito sem saldo retorna REJECTED, nao muda saldo nem cria lancamento.
- Mesma chave e mesmo payload produzem replay sem nova movimentacao.
- Mesma chave com payload diferente retorna erro -20005.
- Valores com mais de duas casas sao rejeitados antes de chegar a NUMBER(19,2).
- A operacao inteira pode sofrer ROLLBACK pelo chamador.

## 9. Limitacoes para C08/C09/C10

- C08: triggers para imutabilidade e auditoria; testes de DML direto.
- C09: traducao de resultados PL/SQL em HTTP e integracao `@Transactional`.
- C10: Testcontainers Oracle, `COMMIT` entre sessoes, lock timeout e chave igual em carteiras diferentes.
- Validar a politica de manter/alterar o retorno `REJECTED` em comparacao com a exigencia estrita de `RAISE_APPLICATION_ERROR(-20004)`.

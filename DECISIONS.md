# Decisoes tecnicas — Wallet API

Este documento registra **escolhas de projeto**, suas justificativas, alternativas e riscos. Ele complementa [`docs/architecture.md`](docs/architecture.md) e sera revisado quando os testes com Oracle real evidenciarem necessidades de ajuste.

Status: `ADOTADA` = decisao inicial; `ABERTA` = precisa ser resolvida antes de afirmar suporte; `LIMITACAO` = conscientemente fora da garantia implementada.

## DEC-01 — Consistencia financeira implementada no Oracle — ADOTADA

**Decisao:** criacao de carteira e registro de operacao por procedures em `WALLET_OWNER.PKG_WALLET`; Java nao executa DML direto nas tabelas.

**Motivo:** requisito explicito do teste; uma unica fonte para invariantes financeiros e concorrencia. A API atua como camada HTTP e de integracao.

**Alternativa rejeitada:** implementar debito inteiramente no `WalletService` com `read + save`.

**Consequencia:** mais logica PL/SQL, exigindo testes de integracao com Oracle real.

## DEC-02 — Tres schemas com menor privilegio — ADOTADA

**Decisao:** `WALLET_OWNER` possui objetos financeiros; `WALLET_APP` apenas executa o package e consulta views; `WALLET_AUDIT` possui a trilha de auditoria sem acesso de `WALLET_APP`.

**Motivo:** principio de menor privilegio e trilha segregada. O package opera com `AUTHID DEFINER` e grants diretos.

**Alternativa rejeitada:** aplicacao conectar como owner e ter acesso irrestrito as tabelas.

**Consequencia:** bootstrap/migrations devem gerenciar usuarios, quotas, objects e grants com ordem correta.

## DEC-03 — Migrations separadas da aplicacao — ADOTADA

**Decisao:** Docker Compose sobe Oracle; bootstrap versionado cria usuarios; Flyway migra `WALLET_AUDIT` antes de `WALLET_OWNER`, por passos independentes. A API utiliza somente `WALLET_APP`.

**Motivo:** reprodutibilidade e separacao de privilegios. Nada de `ddl-auto=update`.

**Alternativa rejeitada:** conceder `CREATE TABLE` ou privilegios de owner para `WALLET_APP`.

**Consequencia:** documentar fluxo de primeira inicializacao e migrations em README; testar do zero.

## DEC-04 — JDBC para chamada de procedures; leitura por views — ADOTADA

**Decisao:** usar JDBC (`CallableStatement`/`JdbcTemplate`) para chamar `PKG_WALLET`; leituras pelas views autorizadas.

**Motivo:** o centro das escritas e PL/SQL; JDBC reduz indirecao e torna o contrato SQL claro.

**Alternativa:** JPA/Hibernate para leituras, igualmente permitido pelo teste.

**Consequencia:** precisamos mapear cuidadosamente parametros OUT, `NUMBER`/`BigDecimal`, timestamps e exceptions.

## DEC-05 — Spring controla a transacao; package nao executa COMMIT — ADOTADA

**Decisao:** o `WalletService` delimita a transacao com `@Transactional` e o package nao realiza `COMMIT`/`ROLLBACK` voluntarios.

**Motivo:** manter uma unica fronteira transacional por caso de uso; confirmar lancamento, saldo e auditoria juntos.

**Risco/validacao:** mapear corretamente excecoes Oracle para provocar rollback. Uma excecao PL/SQL nao significa automaticamente rollback de tudo que ja ocorreu na sessao. Fazer teste real de falha no meio da operacao.

## DEC-06 — Lock pessimista por carteira — ADOTADA

**Decisao:** dentro da procedure de operacao, usar `SELECT ... FOR UPDATE WAIT 5` sobre a linha da carteira, antes de decidir saldo e de executar lancamento.

**Motivo:** serializar alteracoes conflitantes de uma mesma carteira sem serializar carteiras diferentes.

**Alternativa:** controle por versao otimista com retries, mais complexo neste escopo.

**Risco/validacao:** concorrencia pode gerar espera/timeout; mapear erro transitorio para `WALLET_BUSY` e HTTP 503.

## DEC-07 — Idempotency-Key global e resultado historico — ADOTADA

**Decisao:** `idempotency_key` obrigatoria e `UNIQUE` global na tabela de transacoes aplicadas; o payload logico inclui carteira, tipo e valor. Mesma chave + mesmo payload => retorna ID, saldo historico e instante originais; payload diferente => 409.

**Motivo:** protegemos retries apos falha de rede e impedimos debitagem duplicada, inclusive em carteiras diferentes por meio da restricao unica.

**Risco/validacao:** `UNIQUE` sozinha nao implementa replay; apos conflito em insercao concorrente deve-se reler a chave e comparar o payload. Testar duas carteiras concorrentes com chave igual.

## DEC-08 — Saldo materializado + extrato imutavel + auditoria por trigger — ADOTADA

**Decisao:** `WALLET.balance` armazena saldo atual; `WALLET_TRANSACTION` registra cada operacao aplicada e `balance_after`; trigger bloqueia `UPDATE/DELETE` no extrato; trigger de saldo insere `OLD/NEW` no `WALLET_AUDIT.BALANCE_AUDIT`.

**Motivo:** consulta rapida de saldo, replay exato e trilha automatica pelo banco.

**Risco/validacao:** `last_transaction_id` so deve correlacionar um evento de saldo quando alterado na mesma operacao; atualizacao direta sem essa mudanca deve ser auditada com `transaction_id = NULL`, evitando atribuicao falsa. Projetar e testar esse comportamento na implementacao da trigger.

## DEC-09 — Escopo da idempotencia de operacoes rejeitadas — ABERTA (bloqueia a implementacao final da procedure)

**Pergunta:** se uma tentativa de DEBIT falhar por saldo insuficiente e a mesma chave for repetida *depois de um credito*, a API deve repetir `422` ou permitir executar o debito?

**Modelo atual:** so registra na tabela de lancamentos operacoes **aplicadas**. Portanto, por si so, **nao garante replay de uma rejeicao**.

**Tensao tecnica:** o enunciado pede erros PL/SQL via `RAISE_APPLICATION_ERROR` e repeticao do mesmo resultado. Gravar rejeicao e depois propagar uma excecao que causa rollback na mesma transacao apagaria o registro de rejeicao. Para garantir replay de falhas e preciso desenhar um controle de idempotencia persistente, com semantica transacional explicita — e comprova-lo com testes.

**Encaminhamento:** decidir e documentar a semantica antes de implementar C07/C08; nao afirmar que o caso de falha esta coberto ate existir estrategia validada. Se o avaliador interpretar replay como aplicavel apenas a transacoes aplicadas, registrar essa premissa e justificativa; caso contrario, adotar persistencia explicita do resultado da tentativa rejeitada com cuidado para nao introduzir commits parciais.

## DEC-10 — BIGDECIMAL e validacao explicita de escala — ADOTADA

**Decisao:** valores monetarios em Java usam `BigDecimal` e no Oracle `NUMBER(19,2)`, com validacao de positividade e de maximo duas casas antes da gravacao.

**Motivo:** evitar imprecisao binaria e impedir que `NUMBER(19,2)` arredonde silenciosamente um valor recebido com tres casas decimais.

## DEC-11 — IDs por sequences explicitas — ADOTADA

**Decisao:** `SEQ_WALLET`, `SEQ_WALLET_TRANSACTION`, `SEQ_BALANCE_AUDIT`, com `CACHE` e `NOCYCLE` se adequado.

**Motivo:** exigencia do teste e desempenho. IDs nao sao sequenciais sem falhas e nao estabelecem ordem cronologica perfeita.

## DEC-12 — Contrato REST restrito e erros padronizados — ADOTADA

**Decisao:** quatro endpoints obrigatorios; API key via `X-API-Key`; `Idempotency-Key` em POST de transacao; `201` criacao, `404` inexistente, `409` conflito de chave, `422` saldo insuficiente e `503` timeout de lock.

**Motivo:** endpoints claros, sem frontend ou autenticacao de usuario final. O Java traduz erros `ORA-20xxx` sem vazar informacao interna.

## DEC-13 — Timestamps com fuso e extrato paginado — ADOTADA

**Decisao:** `TIMESTAMP WITH TIME ZONE` no Oracle e `OffsetDateTime` no Java; extrato paginado, filtro de periodo com `to` exclusivo e ordenacao por `created_at DESC, id DESC`.

**Motivo:** interoperabilidade e resultado previsivel em consultas grandes.

## DEC-14 — Limitacoes de imutabilidade — LIMITACAO

**Limite:** triggers DML impedem `UPDATE` e `DELETE`, mas nao garantem protecao contra `TRUNCATE`, `DROP`, desabilitacao de trigger ou administradores suficientemente privilegiados. Acesso sem DML de `WALLET_APP` reduz superficie de risco, mas nao torna objetos inviolaveis para um DBA.

**Evolucao futura:** avaliar recursos Oracle especificos para registros imutaveis/auditoria reforcada, conforme edicao, licenciamento e requisitos do ambiente.

## DEC-15 — Priorizar testes de consistencia, nao volume de funcionalidades — ADOTADA

**Decisao:** primeiro entregar nucleo completo; testes de integracao Oracle real para concorrencia, idempotencia, falta de saldo, trigger de extrato e auditoria. Adicionar teste de carga ou recursos opcionais apenas se houver tempo.

**Motivo:** o enunciado valoriza a qualidade, a justificativa das decisoes e a prova das invariantes mais do que o numero de funcionalidades.

---

## O que faria diferente com mais tempo

- Resolver com testes a semantica completa de replay para tentativas rejeitadas.
- Executar carga com k6 e verificar saldo, extrato e auditoria ao final, com cenarios deterministas.
- Reforcar observabilidade (correlation ID, logs estruturados e metricas).
- Avaliar mecanismos mais fortes de imutabilidade e restricao administrativa do Oracle.
- Acrescentar testes de falhas de rede, reinicio do banco e timeout de lock.

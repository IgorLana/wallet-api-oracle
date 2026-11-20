# Decisões técnicas — Wallet API

Este documento registra as decisoes implementadas, suas justificativas, alternativas e riscos. Complementa [`docs/architecture.md`](docs/architecture.md) e os testes de integracao com Oracle real.

Status: `ADOTADA` = decisão inicial; `ABERTA` = precisa ser resolvida antes de afirmar suporte; `LIMITACAO` = conscientemente fora da garantia implementada.

## DEC-01 — Consistência financeira implementada no Oracle — ADOTADA

**Decisão:** criação de carteira e registro de operação por procedures em `WALLET_OWNER.PKG_WALLET`; Java não executa DML direto nas tabelas.

**Motivo:** requisito explícito do teste; uma única fonte para invariantes financeiros e concorrência. A API atua como camada HTTP e de integração.

**Alternativa rejeitada:** implementar débito inteiramente no `WalletService` com `read + save`.

**Consequencia:** mais lógica PL/SQL, exigindo testes de integração com Oracle real.

## DEC-02 — Tres schemas com menor privilegio — ADOTADA

**Decisão:** `WALLET_OWNER` possui objetos financeiros; `WALLET_APP` apenas executa o package e consulta views; `WALLET_AUDIT` possui a trilha de auditoria sem acesso de `WALLET_APP`.

**Motivo:** principio de menor privilegio e trilha segregada. O package opera com `AUTHID DEFINER` e grants diretos.

**Alternativa rejeitada:** aplicação conectar como owner e ter acesso irrestrito as tabelas.

**Consequencia:** bootstrap/migrations devem gerenciar usuários, quotas, objects e grants com ordem correta.

## DEC-03 — Migrations separadas da aplicação — ADOTADA

**Decisão:** Docker Compose sobe Oracle; bootstrap versionado cria usuários; Flyway migra `WALLET_AUDIT` antes de `WALLET_OWNER`, por passos independentes. A API utiliza somente `WALLET_APP`.

**Motivo:** reprodutibilidade e separacao de privilegios. Nada de `ddl-auto=update`.

**Alternativa rejeitada:** conceder `CREATE TABLE` ou privilegios de owner para `WALLET_APP`.

**Consequencia:** documentar fluxo de primeira inicialização e migrations em README; testar do zero.

## DEC-04 — JDBC para chamada de procedures; leitura por views — ADOTADA

**Decisão:** usar JDBC (`CallableStatement`/`JdbcTemplate`) para chamar `PKG_WALLET`; leituras pelas views autorizadas.

**Motivo:** o centro das escritas e PL/SQL; JDBC reduz indirecao e torna o contrato SQL claro.

**Alternativa:** JPA/Hibernate para leituras, igualmente permitido pelo teste.

**Consequencia:** precisamos mapear cuidadosamente parâmetros OUT, `NUMBER`/`BigDecimal`, timestamps e exceptions.

## DEC-05 — Spring controla a transação; package não executa COMMIT — ADOTADA

**Decisão:** o `WalletService` delimita a transação com `@Transactional` e o package não realiza `COMMIT`/`ROLLBACK` voluntarios.

**Motivo:** manter uma única fronteira transacional por caso de uso; confirmar lancamento, saldo e auditoria juntos.

**Risco/validação:** mapear corretamente exceções Oracle para provocar rollback. Uma exceção PL/SQL não significa automaticamente rollback de tudo que já ocorreu na sessao. Fazer teste real de falha no meio da operação.

## DEC-06 — Lock pessimista por carteira — ADOTADA

**Decisão:** dentro da procedure de operação, usar `SELECT ... FOR UPDATE WAIT 5` sobre a linha da carteira, antes de decidir saldo e de executar lancamento.

**Motivo:** serializar alterações conflitantes de uma mesma carteira sem serializar carteiras diferentes.

**Alternativas:** controle por versao otimista com retries ou um
`UPDATE wallet SET balance = balance - :value WHERE id=:id AND balance >= :value`
seguido da verificacao de linhas afetadas. O `FOR UPDATE` foi escolhido
porque serializa explicitamente a leitura, verificacao de idempotencia e
movimento como uma unidade previsivel; o UPDATE condicional sozinho nao
resolve o registro de resultado historico nem os demais casos de credito.

**Risco/validação:** concorrência pode gerar espera/timeout; mapear erro transitorio para `WALLET_BUSY` e HTTP 503.

## DEC-07 — Idempotencia global por solicitacao — ADOTADA

**Decisao:** `WALLET_OPERATION_REQUEST.idempotency_key` e a chave primaria
Global. A tabela guarda carteira, tipo, valor e status terminal. Operacoes
`APPLIED` tem lancamento em `WALLET_TRANSACTION`; tentativas `REJECTED` por
saldo insuficiente nao geram lancamento ou auditoria.

**Invariantes:** mesma chave + mesmo payload (carteira, tipo, valor) retorna
resultado historico; chave reutilizada com payload diferente retorna conflito
ORA-20005 / HTTP 409; um pedido pode gerar no maximo um lancamento.

**Concorrencia:** primeiro se obtem o lock na carteira; depois se consulta a
chave existente. A PK global resolve disputas entre carteiras diferentes.
Timeout de lock retorna ORA-20006 / HTTP 503. O comportamento intencional
para uma disputa de mesma chave entre carteiras diferentes e conflito.

## DEC-08 — Saldo materializado + extrato imutavel + auditoria por trigger — ADOTADA

**Decisão:** `WALLET.balance` armazena saldo atual; `WALLET_TRANSACTION` registra cada operação aplicada e `balance_after`; trigger bloqueia `UPDATE/DELETE` no extrato; trigger de saldo insere `OLD/NEW` no `WALLET_AUDIT.BALANCE_AUDIT`.

**Motivo:** consulta rapida de saldo, replay exato e trilha automatica pelo banco.

**Risco/validação:** `last_transaction_id` só deve correlacionar um evento de saldo quando alterado na mesma operação; atualizacao direta sem essa mudanca deve ser auditada com `transaction_id = NULL`, evitando atribuicao falsa. Projetar e testar esse comportamento na implementação da trigger.

## DEC-09 — Persistencia de rejeicao por saldo insuficiente — ADOTADA

**Decisao implementada na V5:** uma tentativa DEBIT valida, porem sem saldo,
registra `WALLET_OPERATION_REQUEST.status='REJECTED'` e
`rejection_code='INSUFFICIENT_FUNDS'`. A procedure retorna esse resultado por
parametros `OUT`, sem `RAISE_APPLICATION_ERROR(-20004)` nesse caso especifico.
A transacao `@Transactional` do service confirma o registro de rejeicao e o
controller responde HTTP 422 somente depois de a transacao concluir.

**Motivo:** elevar uma excecao dentro da mesma transacao poderia cancelar
o registro duravel de rejeicao. Com o resultado retornado, uma nova tentativa
com a mesma chave reproduz a rejeicao historica mesmo apos creditos futuros.
Este caso foi coberto nos testes de integracao C10 e smoke HTTP C09.

**Sinalizacao de erro:** o enunciado solicita `RAISE_APPLICATION_ERROR` para
erros de negocio. Erros de formato, carteira inexistente, chave conflitante
e lock indisponivel utilizam ORA-20xxx. Somente saldo insuficiente utiliza
resultado terminal para preservar a idempotencia sem transacao autonoma.
E um desvio deliberado da forma de sinalizacao pedida, e nao deve ser
ocultado. Nao alterar esta regra sem revisar as garantias de replay.

**Estados:** o DDL aceita `PENDING`, mas a implementacao atual grava
`APPLIED` ou `REJECTED` diretamente, na mesma transacao. `PENDING` e um
estado reservado, nao uma etapa atualmente persistida.

## DEC-10 — BIGDECIMAL e validação explícita de escala — ADOTADA

**Decisão:** valores monetarios em Java usam `BigDecimal` e no Oracle `NUMBER(19,2)`, com validação de positividade e de máximo duas casas antes da gravacao.

**Motivo:** evitar imprecisao binaria e impedir que `NUMBER(19,2)` arredonde silenciosamente um valor recebido com três casas decimais.

## DEC-11 — IDs por sequences explicitas — ADOTADA

**Decisão:** `SEQ_WALLET`, `SEQ_WALLET_TRANSACTION`, `SEQ_BALANCE_AUDIT`, com `CACHE` e `NOCYCLE` se adequado.

**Motivo:** exigencia do teste e desempenho. IDs nao sao sequenciais sem falhas nem definem cronologia perfeita. `CACHE` acelera alocacao, mas reservas podem ser perdidas em restart e rollback nao devolve numeros. O `NOORDER` nao fornece ordenacao global em RAC; o extrato ordena por `created_at DESC, id DESC`.

## DEC-12 — Contrato REST restrito e erros padronizados — ADOTADA

**Decisão:** quatro endpoints obrigatorios; API key via `X-API-Key`; `Idempotency-Key` em POST de transação; `201` criação, `404` inexistente, `409` conflito de chave, `422` saldo insuficiente e `503` timeout de lock.

**Motivo:** endpoints claros, sem frontend ou autenticação de usuário final. O Java traduz erros `ORA-20xxx` sem vazar informacao interna.

## DEC-13 — Timestamps com fuso e extrato paginado — ADOTADA

**Decisão:** `TIMESTAMP WITH TIME ZONE` no Oracle e `OffsetDateTime` no Java; extrato paginado, filtro de periodo com `to` exclusivo e ordenacao por `created_at DESC, id DESC`.

**Motivo:** interoperabilidade e resultado previsivel em consultas grandes.

## DEC-14 — Limitacoes de imutabilidade — LIMITACAO

**Limite:** triggers DML impedem `UPDATE` e `DELETE`, mas não garantem proteção contra `TRUNCATE`, `DROP`, desabilitacao de trigger ou administradores suficientemente privilegiados. Acesso sem DML de `WALLET_APP` reduz superficie de risco, mas não torna objetos inviolaveis para um DBA.

**Evolucao futura:** avaliar DDL triggers e, quando disponivel, Oracle Immutable Tables ou Blockchain Tables, conforme versao, licenciamento e requisitos do ambiente.

## DEC-15 — Priorizar testes de consistência, não volume de funcionalidades — ADOTADA

**Decisão:** primeiro entregar nucleo completo; testes de integração Oracle real para concorrência, idempotencia, falta de saldo, trigger de extrato e auditoria. Adicionar teste de carga ou recursos opcionais apenas se houver tempo.

**Motivo:** o enunciado valoriza a qualidade, a justificativa das decisões e a prova das invariantes mais do que o número de funcionalidades.

---

## O que faria diferente com mais tempo

- Aprofundar casos extremos de replay entre carteiras e timeout de lock, preservando o modelo de rejeicao duravel.
- Expandir a carga k6 do C12 para testes sustentados depois da validacao local do cenario concorrente deterministico.
- Reforcar observabilidade (correlation ID, logs estruturados e metricas).
- Avaliar mecanismos mais fortes de imutabilidade e restrição administrativa do Oracle.
- Acrescentar testes de falhas de rede, reinicio do banco e timeout de lock.

# C10 - Testes unitarios e de integracao com Oracle Free

## Objetivo

Demonstrar as invariantes financeiras da Wallet API contra o Oracle real, sem
modificar o Oracle persistente do desenvolvedor (`docker compose up oracle`).

Usamos JUnit 6 (gerenciado pelo Spring Boot 4.1.2), Mockito, AssertJ/JUnit
Assertions, Testcontainers 2.0.5 e Oracle Free (mesma imagem versionada de
`docker-compose.yml`).

## Antes de rodar

- Java 21 (`java -version`), Maven Wrapper e Docker Desktop iniciados.
- O codigo do C09 deve estar compilando (`./mvnw -U clean compile`).
- As migrations V1-V6 devem estar presentes em `db/migration/` e o bootstrap
  `db/bootstrap/create-users.sh` deve existir.
- Deixe memoria suficiente para um Oracle temporario (recomendado >= 4 GiB livres).
- Na primeira execucao Testcontainers pode baixar a imagem e levar mais tempo.

## Comandos

```bash
./mvnw -U test       # apenas testes unitarios, nao exige Oracle nem Docker
./mvnw -U verify     # inclui testes *IT usando Oracle temporario isolado
bash scripts/verify-c10.sh  # executa ambos e verifica Docker Desktop
```

Relatorios de execucao:

- `target/surefire-reports/` para classes `*Test` / `*Tests`.
- `target/failsafe-reports/` para classes `*IT`.

## Arquivos

- `WalletApiApplicationTests.java`: teste unitario do filtro de API key.
  Substitui o `contextLoads` anterior, que usava credenciais falsas, pois a
  verificacao real do contexto agora esta em `WalletOracleIT`.
- `WalletServiceTest.java`: mocks Mockito; valida orquestracao, 404,
  paginacao e o retorno REJECTED como resultado de negocio, sem excecao.
- `GlobalExceptionHandlerTest.java`: mapeamento de ORA-20005 e erro 500
  sem expor detalhes internos.
- `integration/OracleTestDatabase.java`: inicia um Oracle Free isolado com
  Testcontainers, faz bootstrap dos tres schemas e aplica os SQL originais
  de audit/V1 e owner/V1..V6, depois verifica objetos compilados.
- `integration/WalletOracleIT.java`: sobe Spring Boot em porta aleatoria,
  passa as credenciais temporarias via DynamicPropertySource e exercita
  banco, transacoes, chamadas concorrentes, auditoria, imutabilidade e HTTP.

## Por que Testcontainers?

A suite precisa confirmar operacoes concorrentes com transacoes verdadeiras:
`SELECT ... FOR UPDATE WAIT 5`, commits, rollback, PK global de chave e triggers.
Um mock nao implementa regras de concorrencia nem constraints Oracle.

**Isolamento**: Testcontainers inicia um Oracle separado do `docker-compose.yml`
e usa senhas *exclusivas desse banco efemero*, declaradas nos testes. Nao le
`.env`, nao usa o volume `oracle_data` e nao apaga dados do Oracle local.

**Detalhe**: os scripts de migration sao executados diretamente com SQL*Plus
na ordem correta. Esta suite testa o SQL real das migrations, mas **nao testa
os metadados do Flyway ou o historico flyway_schema_history**. Para validar o
Flyway, continue usando `bash db/scripts/migrate.sh` no ambiente local.

## Invariantes cobertas

1. Carteira inicia com zero e pode ser consultada.
2. Credito/debito aplicados mantem saldo, extrato e auditoria coerentes.
3. Debito com saldo insuficiente devolve REJECTED sem lancamento ou auditoria.
4. Repetir uma rejeicao apos credito posterior nao executa o debito.
5. Mesma chave+mesmo payload devolve mesmo ID/saldo historico sem duplicar.
6. Mesma chave com payload diferente ou carteira diferente gera ORA-20005.
7. Dois debitos concorrentes de 30 sobre saldo 50: somente um aplica.
8. Duas tentativas concorrentes com mesma chave e mesma carteira: um
   processamento e um replay, um unico credito.
9. Chave global concorrente em duas carteiras: um sucesso e um conflito.
10. Timeout de lock resulta no erro Oracle de negocio -20006.
11. Transacao revertida nao deixa wallet/request/ledger/audit.
12. Trigger impede UPDATE e DELETE no extrato.
13. WALLET_APP nao possui UPDATE direto sobre WALLET.
14. HTTP 401, 201, 400, 422, replay e 409 via servidor real.

## Limitacoes e riscos que permanecem

- A suite pressupoe o comportamento da V5: saldo insuficiente e um resultado
  REJECTED que a camada transacional precisa confirmar. Nao lancamos uma
  excecao dentro do metodo `@Transactional` ao produzir REJECTED.
- O tratamento atual de disputa da mesma chave entre carteiras diferentes
  devolve 409 para a transacao perdedora, mesmo em certas disputas de retry.
  Isso e um comportamento conhecido para revisar na versao final.
- Os testes demonstram os cenarios cobertos, nao ausencia de bugs ou protecao
  contra operacoes de um administrador Oracle suficientemente privilegiado.
- Validacao local informada pelo autor: `./mvnw -U clean compile`, `./mvnw test`
  e `./mvnw -U verify` executados com sucesso no macOS em 19/11/2026,
  incluindo inicializacao do Oracle por Testcontainers. Os resultados nao
  substituem uma reproducao em outro ambiente nem uma pipeline de CI.
- O teste de carga opcional e verificacao de consistencia sob N requisicoes
  constam em `docs/load-testing-c12.md`. Resultados medidos sao publicados
  em `docs/load-test-results.md` somente depois de uma execucao com sucesso.

## Depuracao

```bash
./mvnw -U clean compile
./mvnw test
./mvnw verify
# Se falhar, consulte os XML/TXT em target/failsafe-reports/.
```

`Could not find a valid Docker environment` indica que o Docker Desktop
nao esta acessivel ao Testcontainers. `ORA-01017` normalmente aponta para
credenciais de teste que nao correspondem ao bootstrap. Se aparecer um
erro SQL ao aplicar as migrations, confira o log da classe `OracleTestDatabase`.


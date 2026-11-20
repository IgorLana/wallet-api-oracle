# Wallet API | Java 21 + Spring Boot + Oracle PL/SQL

API REST de carteiras digitais em reais (BRL). As regras de consistência financeira são garantidas no Oracle Database Free por meio de um package PL/SQL, sequences explícitas, constraints e triggers. O Spring Boot disponibiliza a API HTTP utilizando um usuário de banco com privilégios restritos.

> Projeto desenvolvido para uma avaliação técnica. Não inclui interface gráfica, contas de usuários finais, transferências entre carteiras, câmbio ou estornos.

## 1. Pré-requisitos

- Java 21 (`java -version`)
- Docker Desktop / Docker Compose (reserve pelo menos 4 GiB de memória para o Oracle Free)
- Terminal compatível com Bash (macOS, Linux ou Windows com WSL2)
- Acesso à internet para baixar as imagens Docker e dependências Maven na primeira execução
- `curl` para os exemplos HTTP; Python 3 para os scripts opcionais de verificação da API

Não é necessário instalar o Maven: o repositório já inclui o Maven Wrapper (`./mvnw`). A imagem do banco utiliza a versão fixa `gvenzl/oracle-free:23.26.4-slim-faststart`.

## 2. Execução a partir de um clone novo

```bash
git clone https://github.com/IgorLana/wallet-api-oracle.git
cd wallet-api-oracle
cp .env.example .env
```

O `.env.example` versionado contém **credenciais de demonstração prontas para uso local**. Em um clone novo, basta executar `cp .env.example .env`: não é necessário criar cinco senhas apenas para avaliar o projeto. Os valores de exemplo são:

```dotenv
# APENAS PARA DEMONSTRAÇÃO LOCAL — nunca reutilize em produção
ORACLE_PASSWORD=OracleLocalDev2026
WALLET_OWNER_PASSWORD=WalletOwnerDev2026
WALLET_APP_PASSWORD=WalletAppDev2026
WALLET_AUDIT_PASSWORD=WalletAuditDev2026
WALLET_API_KEY=WalletApiDemoKey2026
```

**Segurança:** essas credenciais são públicas e devem ser utilizadas somente em um ambiente local isolado. O arquivo `.env` real é ignorado pelo Git. Para ambientes compartilhados, remotos ou de produção, utilize segredos exclusivos, armazenamento seguro e HTTPS. As senhas dos três schemas devem ser **diferentes**, conter entre 12 e 64 caracteres, começar com uma letra e utilizar somente letras, números ou `_`. A API key deve conter pelo menos 16 caracteres.

**Se você já possui um `.env`, não o sobrescreva.** Os usuários Oracle existentes mantêm as senhas previamente cadastradas. Alterar somente o arquivo local pode provocar falhas de autenticação. Também não utilize `docker compose down -v` para resolver problemas de senha: esse comando remove os dados persistidos no volume local.

Inicie o Oracle, crie os schemas e aplique as migrations versionadas:

```bash
bash db/scripts/migrate.sh
```

Esse script inicia o container persistente do Oracle, cria os usuários com privilégios SYSDBA apenas durante o bootstrap e executa o Flyway primeiro para `WALLET_AUDIT` e depois para `WALLET_OWNER`. Ele pode ser executado novamente; o Flyway ignora as versões já aplicadas.

Valide a estrutura e o comportamento do banco:

```bash
bash db/scripts/verify-c04.sh
bash db/scripts/verify-c05.sh
bash db/scripts/verify-c06.sh
bash db/scripts/verify-c07.sh
bash db/scripts/verify-c08.sh
```

**Observação:** `verify-c08.sh` utiliza SYSDBA local para inspecionar ambos os schemas. A aplicação **nunca** se conecta com esse usuário. Não é necessário nem recomendado executar `docker compose down -v`, pois isso excluiria os dados locais do Oracle.

Carregue a configuração local no terminal e inicie a aplicação:

```bash
set -a
source ./.env
set +a
./mvnw -U spring-boot:run
```

A API estará disponível em `http://localhost:8080`. A aplicação utiliza `WALLET_APP` e não inicia se a senha do banco ou a API key obrigatória estiver ausente. No Windows, utilize o WSL2 ou outro ambiente compatível com Bash.

## 3. Swagger / OpenAPI

Com o Spring Boot em execução:

- Interface interativa: http://localhost:8080/swagger-ui.html
- Especificação OpenAPI em JSON: http://localhost:8080/v3/api-docs
- Especificação OpenAPI em YAML: http://localhost:8080/v3/api-docs.yaml

Clique em **Authorize** no Swagger UI e informe o valor de `WALLET_API_KEY` definido no seu `.env`. O cabeçalho `X-API-Key` protege as rotas `/wallets`. As rotas de documentação são públicas no ambiente de desenvolvimento local; não inclua senhas ou chaves secretas na descrição OpenAPI.

Para verificar a especificação gerada sem criar dados financeiros:

```bash
bash scripts/verify-c11.sh
```

A API precisa estar em execução em outro terminal.

## 4. Contrato HTTP

Todas as rotas de carteiras exigem `X-API-Key`. O registro de transações também exige o cabeçalho `Idempotency-Key` e um corpo JSON no formato `{ "type": "CREDIT|DEBIT", "amount": 0.01 }`.

| Método | Rota | Sucesso | Descrição |
| --- | --- | --- | --- |
| POST | `/wallets` | 201 | JSON opcional `{ "holderName": "Ana" }`; saldo inicial `0.00` |
| GET | `/wallets/{id}` | 200 | Retorna 404 se a carteira não existir |
| POST | `/wallets/{id}/transactions` | 201 | Aplica crédito/débito; 422 para saldo insuficiente; 409 para conflito de chave |
| GET | `/wallets/{id}/transactions` | 200 | `page` começa em 0; `size` entre 1 e 100; `from` inclusivo e `to` exclusivo |

Os valores financeiros são expressos em BRL, devem ser positivos e podem ter no máximo duas casas decimais. O extrato é ordenado por `created_at DESC, id DESC`. Tentativas rejeitadas não aparecem no extrato financeiro.

### Exemplo de utilização

Em um segundo terminal, carregue novamente o `.env` e crie uma carteira:

```bash
set -a; source ./.env; set +a
curl -i -X POST http://localhost:8080/wallets \
  -H "X-API-Key: $WALLET_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"holderName":"Ana"}'
```

Copie o `id` retornado e atribua o valor real à variável `WALLET_ID`:

```bash
WALLET_ID=1 # substitua pelo id retornado em POST /wallets
curl -i -X POST "http://localhost:8080/wallets/$WALLET_ID/transactions" \
  -H "X-API-Key: $WALLET_API_KEY" \
  -H 'Idempotency-Key: example-credit-001' \
  -H 'Content-Type: application/json' \
  -d '{"type":"CREDIT","amount":100.00}'

curl -i "http://localhost:8080/wallets/$WALLET_ID" \
  -H "X-API-Key: $WALLET_API_KEY"

curl -i "http://localhost:8080/wallets/$WALLET_ID/transactions?page=0&size=20" \
  -H "X-API-Key: $WALLET_API_KEY"
```

Repetir o POST de transação com a mesma chave e o mesmo conteúdo devolve o **resultado original** e o cabeçalho `Idempotent-Replayed: true`, sem alterar o saldo novamente. Reutilizar a chave com outra carteira, tipo ou valor resulta em **409 Conflict**.

Se um débito não tiver saldo suficiente, a API responde com **422** e registra a tentativa como `REJECTED`. Uma repetição com a mesma chave e os mesmos parâmetros mantém a rejeição original, mesmo após a carteira receber outro crédito. Para tentar novamente como uma nova operação, utilize outra chave.

Exemplo de resposta de erro:

```json
{
  "code": "INSUFFICIENT_FUNDS",
  "message": "Insufficient funds",
  "status": 422,
  "timestamp": "2026-11-19T21:00:00Z"
}
```

O formato de erro é `{code, message, status, timestamp}`. A data do exemplo é ilustrativa. Os nomes dos campos e códigos permanecem em inglês porque fazem parte do contrato da API.

### Mapeamento de erros

| Erro Oracle / condição | HTTP | Código público |
| --- | ---: | --- |
| ORA-20001 / valor inválido | 400 | `INVALID_AMOUNT` |
| ORA-20002 / tipo de transação inválido | 400 | `INVALID_TRANSACTION_TYPE` |
| ORA-20003 / carteira inexistente | 404 | `WALLET_NOT_FOUND` |
| Retorno `REJECTED` do Oracle / saldo insuficiente | 422 | `INSUFFICIENT_FUNDS` |
| ORA-20005 / chave reutilizada com parâmetros diferentes | 409 | `IDEMPOTENCY_KEY_CONFLICT` |
| ORA-20006 / tempo de espera pelo lock excedido | 503 | `WALLET_BUSY` |
| ORA-20007 / chave de idempotência inválida | 400 | `INVALID_IDEMPOTENCY_KEY` |
| ORA-20008 / nome do titular inválido | 400 | `INVALID_HOLDER_NAME` |
| ORA-20009 / solicitação incompleta | 409 | `INCOMPLETE_REQUEST` |
| Corpo ou parâmetros HTTP inválidos | 400 | `INVALID_REQUEST` |
| `X-API-Key` ausente ou inválida | 401 | `UNAUTHORIZED` |
| Método HTTP ou tipo de conteúdo não suportado | 405 / 415 | `METHOD_NOT_ALLOWED` / `UNSUPPORTED_MEDIA_TYPE` |
| Rota HTTP inexistente | 404 | `RESOURCE_NOT_FOUND` |
| Falha inesperada de banco ou servidor | 500 | `DATABASE_ERROR` / `INTERNAL_ERROR` |

**Decisão de projeto:** o código `-20004` está reservado no PL/SQL, mas não é lançado para saldo insuficiente. Nesse caso, o package retorna `REJECTED` para permitir que o registro da rejeição seja confirmado atomicamente antes da resposta HTTP 422. Não é criado lançamento no extrato nem registro de auditoria de saldo para essa rejeição. Repetições idênticas retornam o resultado original, mesmo após novos créditos.

## 5. Arquitetura e objetos do banco

```text
Cliente HTTP -- X-API-Key --> Controller Spring
                                    |
                                    v
                               WalletService
                               @Transactional
                                    |
                                    v
                              Repositório JDBC
                        CALL package / READ views
                                    |
                                    v
Oracle FREEPDB1: WALLET_OWNER.PKG_WALLET
  |-- WALLET                        (saldo atual)
  |-- WALLET_OPERATION_REQUEST      (tentativas aplicadas/rejeitadas; chave global)
  |-- WALLET_TRANSACTION            (extrato imutável de operações aplicadas)
  |-- V_WALLET, V_WALLET_TRANSACTION (views de leitura da API)
  |-- SEQ_WALLET, SEQ_WALLET_TRANSACTION
  |-- TRG_WALLET_TRANSACTION_IMMUTABLE
  `-- TRG_WALLET_BALANCE_AUDIT ----> WALLET_AUDIT.BALANCE_AUDIT
```

O projeto utiliza três usuários Oracle:

- **`WALLET_OWNER`:** proprietário das tabelas, views, sequences, procedures e triggers. Executa as migrations do domínio.
- **`WALLET_APP`:** usuário utilizado pela API. Possui `CREATE SESSION`, `EXECUTE` no package e `READ` nas views, sem DML direto nas tabelas do domínio nem acesso à auditoria.
- **`WALLET_AUDIT`:** proprietário da tabela de auditoria de saldo. O schema `WALLET_OWNER` recebe somente os privilégios necessários de `INSERT` na tabela e `SELECT` na sequence.

O modelo utiliza constraints (`PK`, `FK`, `UNIQUE` e `CHECK`) para garantir a integridade dos dados. `WALLET.balance` mantém o saldo materializado para consultas rápidas. Cada crédito ou débito aplicado cria um lançamento imutável e um registro de auditoria por trigger. Alterações diretas no saldo também são auditadas, com `transaction_id` nulo quando não há uma nova transação associada.

### Concorrência e idempotência

`PKG_WALLET.REGISTER_TRANSACTION` bloqueia a linha da carteira com `SELECT ... FOR UPDATE WAIT 5`. O bloqueio permanece até o `COMMIT` ou `ROLLBACK` do chamador, serializando operações concorrentes na mesma carteira. Uma chave primária global em `WALLET_OPERATION_REQUEST.idempotency_key` evita aplicações duplicadas entre carteiras. Antes de repetir um resultado, o package compara os parâmetros da requisição com os originais. O banco também utiliza uma constraint para impedir saldo negativo.

O Spring controla a transação; o package PL/SQL **não** executa `COMMIT` ou `ROLLBACK`. Em caso de saldo insuficiente, a procedure devolve o resultado terminal `REJECTED` em vez de lançar `ORA-20004`, permitindo que o Spring **confirme a rejeição** antes de o controller responder com HTTP 422. Essa é uma escolha consciente que difere da preferência literal do enunciado sobre sinalização de erros. A justificativa está em [`docs/final-review.md`](docs/final-review.md).

O trigger de imutabilidade bloqueia operações SQL de `UPDATE` e `DELETE` enquanto estiver habilitado. Administradores com privilégios de DDL ainda podem desabilitar triggers ou remover objetos; portanto, o modelo não equivale a um armazenamento WORM (*Write Once, Read Many*).

### Migrations

- Flyway de auditoria: `db/migration/audit/V1__balance_audit_and_grants.sql`
- Flyway do domínio: `db/migration/owner/V1` até `V6` (sequences, tabelas, views, package e triggers)
- Bootstrap de usuários: `db/bootstrap/create-users.sh`
- Script de orquestração: `db/scripts/migrate.sh`

O Flyway é executado fora da aplicação Spring; o usuário utilizado em tempo de execução não possui privilégios DDL. Executar somente `docker compose up` inicia o Oracle, **mas não cria os schemas**. Para preparar o ambiente completo, execute `bash db/scripts/migrate.sh`.

## 6. Testes

```bash
./mvnw -U test       # testes unitários; não exigem Docker
./mvnw -U verify     # inclui testes de integração com Oracle temporário (Testcontainers)
```

O Testcontainers inicializa uma instância Oracle isolada. A suíte verifica consistência financeira, idempotência, repetição de resultados, débitos concorrentes, timeout de lock, triggers de auditoria, imutabilidade, privilégios e rollback. Os scripts SQL originais são aplicados via SQL*Plus; o histórico de execução do Flyway é validado separadamente no fluxo normal de `migrate.sh`.

Relatórios gerados pelo Maven: `target/surefire-reports/` e `target/failsafe-reports/`.

```bash
bash scripts/verify-c09.sh    # teste HTTP opcional; cria dados persistentes de DESENVOLVIMENTO
bash scripts/verify-c11.sh    # verifica Swagger/OpenAPI; não cria carteiras
```

## 7. Teste de carga opcional C12 (k6)

O C12 verifica **consistência financeira sob concorrência**, não apenas tempos de resposta. O cenário envia 40 débitos distintos de R$ 1,00 contra uma carteira nova com saldo inicial de R$ 20,00, utilizando 10 usuários virtuais concorrentes por padrão. Cada débito é repetido imediatamente com a mesma chave de idempotência e os mesmos parâmetros.

**Resultado esperado no banco:** 20 débitos aplicados, 20 rejeições por saldo insuficiente, saldo final de R$ 0,00, 21 lançamentos imutáveis e 21 registros de auditoria correspondentes (incluindo o crédito inicial). O script verifica essas invariantes diretamente no Oracle antes de informar sucesso.

Pré-requisitos: aplicação em execução, Docker Desktop ativo, Python 3 instalado e `k6` disponível localmente:

```bash
brew install k6  # macOS, caso ainda não esteja instalado
bash scripts/run-c12.sh
```

O teste aceita **somente localhost** e cria registros persistentes **apenas para desenvolvimento** no volume Oracle existente. Não execute contra produção. Após todas as verificações passarem, ele gera um relatório de desempenho com métricas reais em `docs/load-test-results.md`.

O arquivo de resultados **não acompanha o projeto como um relatório vazio**: deve ser criado por uma execução local aprovada. Não registre nem versione métricas inventadas.

Para conhecer os parâmetros, os cuidados de segurança e as verificações detalhadas, consulte [`docs/load-testing-c12.md`](docs/load-testing-c12.md).

## 8. Decisões técnicas, limitações e documentação

- Arquitetura: [`docs/architecture.md`](docs/architecture.md)
- Decisões e alternativas: [`DECISIONS.md`](DECISIONS.md)
- Comparação com os requisitos e limitações: [`docs/final-review.md`](docs/final-review.md)
- Configuração local do Oracle: [`docs/oracle-local.md`](docs/oracle-local.md)
- Migrations: [`docs/oracle-migrations.md`](docs/oracle-migrations.md)
- Comportamento da API: [`docs/api-local.md`](docs/api-local.md)
- Testes de integração Oracle: [`docs/testing-c10.md`](docs/testing-c10.md)
- Teste de concorrência com k6: [`docs/load-testing-c12.md`](docs/load-testing-c12.md)
- Resultado real do k6: `docs/load-test-results.md`, gerado após `bash scripts/run-c12.sh` ser concluído com sucesso e então versionado com os valores medidos
- Diagrama editável: [`docs/diagrams/wallet-architecture.excalidraw`](docs/diagrams/wallet-architecture.excalidraw)

**Possíveis evoluções:** executar o próprio Flyway nos ambientes descartáveis de integração; disponibilizar um perfil de execução da aplicação em container; refinar o tratamento de retries em situações raras de concorrência e timeout; aprimorar observabilidade e métricas; avaliar controles mais fortes de imutabilidade da auditoria; realizar testes de carga prolongados e envolvendo múltiplas carteiras. Esses itens são propostas futuras, não funcionalidades apresentadas como implementadas.

## 9. Evidências de validação e entrega

Validações locais informadas pelo desenvolvedor no macOS, em 19 de novembro de 2026: `./mvnw -U clean compile`, `./mvnw test` e `./mvnw -U verify` concluídos com sucesso, utilizando Docker Desktop e Oracle temporário do Testcontainers. A verificação C08 das triggers Oracle também passou. Esses resultados não significam que a suíte foi executada em CI ou no ambiente do avaliador.

Antes de enviar esta revisão, execute novamente `./mvnw -U verify`, `bash scripts/verify-c11.sh` e o teste opcional `bash scripts/run-c12.sh`. Registre as métricas do C12 somente após a execução real do k6 e a reconciliação bem-sucedida com o Oracle. Inclua o relatório gerado no commit final.

Verifique também se o e-mail de autoria dos commits está associado à sua conta GitHub:

```bash
git log -1 --format='%an <%ae>'
```

Não é necessário reescrever o histórico existente apenas por motivos de apresentação.

O projeto deve ser entregue como **repositório público no GitHub**, com histórico de commits que permita acompanhar a evolução. Confirme que o link está acessível, que todos os arquivos necessários foram versionados e que não há credenciais reais no repositório.

Conforme o enunciado original, envie um e-mail para **avaliacao.tech@datum.inf.br**, com o assunto **Conclusão Avaliação – [Seu nome completo]**, incluindo no corpo o link público do GitHub. Antes do envio, confira o nome, o prazo e a identidade utilizada.

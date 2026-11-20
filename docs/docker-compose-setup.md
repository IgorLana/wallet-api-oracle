# Execucao integral com Docker Compose (Windows, macOS e Linux)

## Um comando para executar a aplicacao

Requisitos: Git, Docker Desktop (Linux containers) ou Docker Engine com Compose V2,
conectividade com Docker Hub e Maven Central, e memoria suficiente para Oracle Free
(recomendamos disponibilizar pelo menos 4 GiB ao Docker; mais durante o build Java).

```text
git clone https://github.com/IgorLana/wallet-api-oracle.git
cd wallet-api-oracle
docker compose up --build
```

No Windows, executar em **PowerShell**. Nao precisa de Ubuntu, WSL como terminal,
Git Bash, Java, Maven ou Python instalados para subir os quatro servicos.
O Docker Desktop pode usar WSL2 internamente; isso e separado da instalacao de Ubuntu.

O comando prepara a seguinte cadeia:

1. `oracle`: Oracle Database Free, volume persistente `oracle_data`.
2. `create-users.sh`: executado no container Oracle apos inicializar, com SYSDBA
   local. Cria os tres usuarios se necessario, sem trocar senhas de usuarios existentes.
3. `flyway-audit`: aplica migracoes da auditoria e encerra com status 0.
4. `flyway-owner`: inicia apos a auditoria e aplica migracoes do dominio.
5. `wallet-api`: inicia apos a conclusao do Flyway, com Java 21 em container
   separado e conexao interna ao Oracle pelo hostname `oracle`.

O primeiro startup pode demorar pelo download de imagens, dependencias Maven e
inicializacao do Oracle. Aguarde `wallet-api` iniciar antes de abrir o Swagger.

- Swagger: http://localhost:8080/swagger-ui.html
- OpenAPI: http://localhost:8080/v3/api-docs
- API key local: `WalletApiDemoKey2026` (digite em **Authorize** no Swagger).

## Configuracao opcional

**Nao e necessario criar `.env`** para avaliar um clone limpo. O Compose utiliza
credenciais de demonstracao preconfiguradas, iguais as do `.env.example`.
Para trocar valores **antes de iniciar um banco novo**, copie `.env.example` para
`.env` e edite-o; o Docker Compose le este arquivo automaticamente.

As portas `8080` e `1521` ficam vinculadas somente a `127.0.0.1` no host.
As credenciais publicas sao apenas para um banco descartavel de desenvolvimento.
Nao use esta configuracao em producao ou em maquinas expostas a outras pessoas.

**Volume antigo e senhas:** os usuarios Oracle existentes nao tem suas senhas
alteradas automaticamente pelo bootstrap. Se ja havia um volume Oracle, mantenha
as senhas compatíveis com as daquele banco. Alterar apenas `.env` nao muda uma
senha ja persistida. Em especial, nao execute `docker compose down -v` para
corrigir uma falha de autenticacao; isso apagaria o volume local.

## Operacao

```text
docker compose ps
docker compose logs -f wallet-api
docker compose logs flyway-audit flyway-owner
docker compose down
```

`docker compose down` para os containers, **preservando o volume**. Na proxima
subida, o bootstrap idempotente verifica os usuarios e o Flyway pula migracoes
ja aplicadas.

Se a porta 8080 estiver ocupada, pare a execucao Java que estiver usando a
mesma porta antes de executar o Compose. Para observar o estado, use
`docker compose ps -a` e `docker compose logs oracle`.

## Desenvolvimento e testes

O fluxo anterior permanece disponivel para quem quer executar o Spring Boot na
maquina, com Java 21 e Bash:

```bash
cp .env.example .env
bash db/scripts/migrate.sh
set -a; source .env; set +a
./mvnw spring-boot:run
```

Esse modo alternativo usa `localhost:1521` no `DB_URL`, enquanto o Docker usa
`oracle:1521` dentro da rede de containers. **Nao inicie simultaneamente a API
local e a API em container na mesma porta 8080.**

Os testes JUnit/Testcontainers continuam independentes, via `./mvnw -U verify`
com Java e Docker disponíveis no host. O build da imagem faz `mvn -DskipTests
package` porque Testcontainers nao deve depender de acesso ao daemon Docker
dentro do build. Isso nao substitui a suite de testes automatizados.
O teste de carga opcional C12 permanece um processo local separado, documentado
em `docs/load-testing-c12.md`.

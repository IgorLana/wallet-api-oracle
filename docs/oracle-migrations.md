# C04 - Schemas e Flyway (Oracle Free)

## Objetivo

Criar tres usuarios locais no PDB `FREEPDB1` e aplicar migrations versionadas, **sem usar `WALLET_APP` como usuario de migracao**. A API Spring Boot continuara sem datasource ate a integracao JDBC.

- `WALLET_AUDIT`: tabelas e sequences da auditoria; concede somente `INSERT` na tabela e `SELECT` na sequence para `WALLET_OWNER`.
- `WALLET_OWNER`: sequences e, nos proximos commits, tabelas, package, views e triggers de negocio.
- `WALLET_APP`: apenas `CREATE SESSION` por enquanto. Os `GRANT EXECUTE/READ` serao versionados apos a criacao do package e das views.

## Pre-requisitos

- Docker Desktop aberto e `docker compose` disponivel.
- Arquivos do C03, principalmente `docker-compose.yml`, com o servico `oracle` e volume de dados.
- `.env` local com quatro senhas definidas; NAO subir `.env` ao GitHub.

Copie `.env.example` para `.env` apenas quando ainda nao existir. **Se o C03 ja esta funcionando, preserve a senha ORACLE_PASSWORD atual**, pois alteracao posterior dessa variavel nao modifica a senha do usuario SYS em um volume existente.

Anexe ao seu `.env` local as novas entradas (com valores diferentes e fortes):

```dotenv
WALLET_OWNER_PASSWORD=SEU_VALOR
WALLET_AUDIT_PASSWORD=SEU_VALOR
WALLET_APP_PASSWORD=SEU_VALOR
```

As senhas dos tres usuarios devem usar 12-64 caracteres de letras, numeros e `_`, comecando com uma letra. Os valores nao devem conter `CHANGE_ME` nem ser identicos.

## Rodar pela primeira vez (ou rerodar)

```bash
bash db/scripts/migrate.sh
```

A automacao executa estas etapas, nesta ordem:

1. `docker compose up -d oracle` (nao apaga o volume).
2. Bootstrap de usuarios no `FREEPDB1` usando SQL*Plus com autenticacao OS como SYSDBA **dentro** do container Oracle.
3. Flyway de auditoria (usuario `WALLET_AUDIT`).
4. Flyway de dominio (usuario `WALLET_OWNER`).

Para consultar o resultado:

```bash
bash db/scripts/verify-c04.sh
```

## Como funcionam os dois Flyways

A configuracao esta em `docker-compose.migrations.yml`, executada como *override*:

```bash
docker compose -f docker-compose.yml -f docker-compose.migrations.yml run --rm flyway-audit
docker compose -f docker-compose.yml -f docker-compose.migrations.yml run --rm flyway-owner
```

Cada migrador tem suas **proprias credenciais, pasta SQL e tabela de historico Flyway**. Os usuarios existem previamente; por isso, o Flyway nao precisa de SYS/DBA.

Arquivos do C04:

```text
db/bootstrap/create-users.sh                         # DDL de usuarios e GRANTs de sistema; como SYSDBA
db/migration/audit/V1__balance_audit_and_grants.sql   # Tabela + sequence + grants
db/migration/owner/V1__wallet_sequences.sql           # Sequences do dominio
```

A segunda execucao das migrations aplicadas deve registrar que nao ha novas migrations pendentes, sem recriar tabelas e sequences.

## Seguranca e limitacoes

- O bootstrap e idempotente **para usuarios ja existentes**, mas NAO muda suas senhas. Se mudar uma senha no `.env` depois de criar os usuarios, o Flyway vai falhar na autenticacao. Ajuste explicitamente no Oracle; nao apague o volume por impulso.
- SQL de criacao de usuarios usa somente senhas validadas. Em ambientes reais, usariamos um gestor de segredos e fluxo privilegiado de provisionamento.
- Uma DDL Oracle normalmente confirma implicitamente a transacao: migrations que falham depois de algumas DDLs podem deixar objetos criados. O Flyway pode precisar de reparo apos diagnostico, nunca de `clean` automatico.
- O schema `WALLET_APP` nao tem acesso a auditoria nem DML direto; no proximo commit recebera apenas grants diretos nos objetos necessarios.
- Oracle SYS e o usuario dono do schema podem ter privilegios administrativos suficientes para alterar objetos. O conjunto de GRANTs e uma barreira de privilegio minimo da aplicacao, nao uma garantia contra um DBA mal-intencionado.

## Diagnostico

```bash
docker compose ps
docker compose logs --tail 80 oracle
docker compose -f docker-compose.yml -f docker-compose.migrations.yml run --rm flyway-audit info
docker compose -f docker-compose.yml -f docker-compose.migrations.yml run --rm flyway-owner info
```

`ORA-01017` indica credenciais invalidas; verifique se os usuarios ja existiam com senhas diferentes. `ORA-01920` ou `ORA-00955` indica conflito de nome/objeto; inspecione o banco antes de tentar novamente. Se falhar uma migration Oracle, revise o log e os objetos antes de considerar `flyway repair`.

## Proximos commits

- C05: tabelas financeiras, chaves, CHECKs, indices e views (e os seus grants de leitura).
- C06+: `PKG_WALLET`, triggers e concessao de `EXECUTE` para `WALLET_APP`.

O registro duravel das tentativas rejeitadas/idempotencia completa permanece uma decisao futura antes da procedure de registro de operacoes.

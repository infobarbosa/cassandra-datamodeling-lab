# Laboratório: Modelagem de Dados com Apache Cassandra

Author: Prof. Barbosa<br>
Contact: infobarbosa@gmail.com<br>
Github: [infobarbosa](https://github.com/infobarbosa)

Neste laboratório você vai aprender, na prática, o princípio central da modelagem de dados no **Apache Cassandra**: **as tabelas são desenhadas a partir das consultas** (padrão de acesso), e não a partir das entidades.

Para isso, usamos uma base real: os **pagamentos do programa Bolsa Família** (competência 2026-03, Portal da Transparência) — 18,5 milhões de registros já carregados em **4 tabelas diferentes com o mesmo dado**, cada uma modelada para um padrão de acesso distinto.

**Pré-requisito:** apenas Docker instalado. Todos os comandos são copy-paste no terminal Linux.

---

## Módulo 0 — Subindo o ambiente

```sh
docker pull ghcr.io/infobarbosa/cassandra-bolsafamilia-preloaded:5.0.8

```

```sh
docker run --name cassandra-bf -d -p 9042:9042 ghcr.io/infobarbosa/cassandra-bolsafamilia-preloaded:5.0.8

```

Aguarde o container ficar saudável (1 a 2 minutos):

```sh
until [ "$(docker inspect -f '{{.State.Health.Status}}' cassandra-bf)" = "healthy" ]; do
    echo "aguardando o Cassandra inicializar..."
    sleep 5
done
echo "Pronto!"

```

Você não precisa instalar o `cqlsh`: vamos usar o que já vem dentro do container. Crie um atalho para a sessão:

```sh
alias cql='docker exec -it cassandra-bf cqlsh -e'

```

Teste:

```sh
cql "SELECT cluster_name, release_version FROM system.local;"

```

Valide o ambiente (opcional):

```sh
curl -sS https://raw.githubusercontent.com/infobarbosa/cassandra-datamodeling-lab/main/scripts/check.sh | bash

```

---

## Módulo 1 — Conhecendo o modelo

No Cassandra, a `PRIMARY KEY` tem dois papéis:

- **Partition key**: decide **em qual nó e em qual partição** a linha mora. Toda consulta eficiente informa a partition key completa.
- **Clustering keys**: decidem **a ordem física das linhas dentro da partição**.

Veja as 4 tabelas — repare que as colunas são as mesmas; só a chave muda:

```sh
cql "DESCRIBE KEYSPACE bolsa_familia;"
```

| Tabela | PRIMARY KEY | Padrão de acesso |
|---|---|---|
| `pagamentos_por_nis` | `((nis), mes_referencia)` | parcelas de um beneficiário |
| `pagamentos_por_municipio` | `((uf, cd_municipio), nis, mes_referencia)` | beneficiários de um município |
| `pagamentos_por_municipio_valor` | `((uf, cd_municipio), valor_parcela, ...)` | maiores parcelas de um município |
| `pagamentos_por_uf` | `((uf), cd_municipio, nis, mes_referencia)` | ⚠️ anti-pattern proposital |

---

## Módulo 2 — Partition key de atributo único

Padrão de acesso: *"dado um NIS, quais as parcelas do beneficiário?"*

```sh
cql "SELECT mes_referencia, nome, nm_municipio, valor_parcela
     FROM bolsa_familia.pagamentos_por_nis
     WHERE nis = '26913139991';"

```

Repare: 10 parcelas (pagamentos retroativos), já ordenadas da referência mais recente para a mais antiga — a clustering key `mes_referencia DESC` fez isso no layout físico, sem `ORDER BY`.

A clustering key também permite **range scan dentro da partição**:

```sh
cql "SELECT mes_referencia, valor_parcela
     FROM bolsa_familia.pagamentos_por_nis
     WHERE nis = '26913139991' AND mes_referencia >= 202601;"

```

Ligue o `TRACING` e observe o custo: uma partição, uma leitura pontual.

```sh
time docker exec -it cassandra-bf cqlsh -e "
    TRACING ON;
    SELECT * FROM bolsa_familia.pagamentos_por_nis WHERE nis = '26913139991';"

```

Agora tente consultar por uma coluna que **não** é a partition key:

```sh
cql "SELECT * FROM bolsa_familia.pagamentos_por_nis WHERE nm_municipio = 'PEDRA LAVRADA';"

```

O Cassandra recusa: sem a partition key ele teria que varrer **todas** as partições do cluster. O `ALLOW FILTERING` sugerido no erro faz exatamente isso — experimente se tiver paciência, mas em produção a resposta correta é **outra tabela, modelada para essa consulta** (Módulo 3).

---

## Módulo 3 — Partition key composta

Padrão de acesso: *"dado um município, quais os beneficiários?"* A partition key agora é o **par** `(uf, cd_municipio)`:

```sh
cql "SELECT nis, nome, mes_referencia, valor_parcela
     FROM bolsa_familia.pagamentos_por_municipio
     WHERE uf = 'PB' AND cd_municipio = '2123'
     LIMIT 20;"

```

(PB / 2123 = Pedra Lavrada, ~1.200 pagamentos.)

Com partition key composta, **todos os componentes são obrigatórios**:

```sh
cql "SELECT * FROM bolsa_familia.pagamentos_por_municipio WHERE uf = 'PB' LIMIT 10;"

```

Falha: `uf` sozinho não identifica a partição — o hash é calculado sobre o par completo. Guarde esse erro: ele é a diferença entre partition key composta (este módulo) e múltiplas clustering keys (Módulo 5).

---

## Módulo 4 — Clustering key como ordenação

Padrão de acesso: *"as maiores parcelas de um município"* (top-N). No mundo relacional seria `ORDER BY valor DESC LIMIT 10` com sort em tempo de consulta. Aqui a ordenação **já está no disco**: `valor_parcela DESC` é a primeira clustering key.

```sh
cql "SELECT valor_parcela, nome, mes_referencia
     FROM bolsa_familia.pagamentos_por_municipio_valor
     WHERE uf = 'PB' AND cd_municipio = '2123'
     LIMIT 10;"

```

Range pela clustering key — "parcelas acima de R$ 900 em São Paulo capital":

```sh
cql "SELECT valor_parcela, nome
     FROM bolsa_familia.pagamentos_por_municipio_valor
     WHERE uf = 'SP' AND cd_municipio = '7107' AND valor_parcela >= 900
     LIMIT 20;"

```

O custo dessa mágica: uma tabela por ordenação. Espaço em disco é o preço; sort em tempo de leitura, a economia. **No Cassandra, escreve-se o dado N vezes para ler barato N vezes.**

---

## Módulo 5 — O anti-pattern: partições gigantes

A tabela `pagamentos_por_uf` particiona por UF — só 27 valores possíveis. A partição da Bahia tem **2,3 milhões de linhas (~224 MB compactados)**. Compare a mesma consulta (um município da BA) nas duas modelagens:

```sh
# Partição saudável (~24 mil linhas: Vitória da Conquista)
time docker exec -it cassandra-bf cqlsh -e "
    TRACING ON;
    SELECT nis, nome, valor_parcela FROM bolsa_familia.pagamentos_por_municipio
    WHERE uf = 'BA' AND cd_municipio = '3965' LIMIT 5;"

```

```sh
# Partição gigante (2,3M linhas: a Bahia inteira em uma partição)
time docker exec -it cassandra-bf cqlsh -e "
    TRACING ON;
    SELECT nis, nome, valor_parcela FROM bolsa_familia.pagamentos_por_uf
    WHERE uf = 'BA' AND cd_municipio = '3965' LIMIT 5;"

```

**Surpresa: as duas respondem rápido.** A leitura pontual usa o índice da partição + clustering keys para saltar direto ao trecho desejado — o tamanho da partição quase não pesa numa leitura assim. Então onde mora o problema? Em tudo que precisa **atravessar a partição inteira**:

```sh
# Varredura da partição saudável: instantânea
time docker exec -it cassandra-bf cqlsh -e "
    SELECT count(*) FROM bolsa_familia.pagamentos_por_municipio
    WHERE uf = 'PB' AND cd_municipio = '2123';"

```

```sh
# Varredura da partição gigante: o servidor DESISTE (ReadTimeout)
time docker exec -it cassandra-bf cqlsh -e "
    SELECT count(*) FROM bolsa_familia.pagamentos_por_uf WHERE uf = 'BA';"

```

A segunda consulta falha com `ReadTimeout`: o coordinator estoura o `read_request_timeout` do servidor antes de terminar de varrer 2,3M de linhas. A partição ficou grande demais até para ser **lida por inteiro** dentro do tempo padrão.

Veja as estatísticas físicas — repare em *Compacted partition maximum bytes*:

```sh
docker exec -it cassandra-bf nodetool tablestats bolsa_familia.pagamentos_por_uf

```

```sh
docker exec -it cassandra-bf nodetool tablehistograms bolsa_familia pagamentos_por_uf

```

Compare com a tabela bem particionada:

```sh
docker exec -it cassandra-bf nodetool tablestats bolsa_familia.pagamentos_por_municipio

```

```sh
docker exec -it cassandra-bf nodetool tablehistograms bolsa_familia pagamentos_por_municipio

```

Por que é grave em produção, mesmo quando as leituras pontuais parecem saudáveis: partições gigantes concentram carga em poucos nós (hotspots), pressionam heap/GC na leitura, na compactação e no repair, e não se dividem — **partição não escala horizontalmente; o cluster escala em número de partições**. Regra prática: manter partições abaixo de ~100 MB.

---

## Módulo 6 — Exercício de modelagem

Projete (e crie no keyspace `bolsa_familia`) uma tabela para cada padrão de acesso abaixo. Justifique a escolha de partition key e clustering keys, e estime o tamanho das partições:

1. *"Dado um município, listar os beneficiários em ordem alfabética de nome."*
2. *"Dado um NIS e um mês de referência exatos, retornar a parcela (uma linha)."*
3. *"Dada uma UF, o total pago por mês de referência."* — dica: pense se isso é uma consulta para o Cassandra resolver em tempo de leitura ou uma agregação para pré-computar na escrita.

Crie a tabela do item 1 e insira manualmente 3 a 5 linhas de teste (`INSERT INTO ...`) para validar a consulta com `SELECT`.

---

## Encerrando o ambiente

```sh
docker rm -f cassandra-bf

```

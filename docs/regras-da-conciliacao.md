# Regras da conciliação de repasses

O que o código faz hoje, campo por campo, com o que está medido e o que está errado.
Escrito em 2026-09-27 a partir da base do cliente (empresa #3), não de intenção.

Toda regra aqui tem um lugar no código. Quando as duas divergirem, o código é a
verdade e este arquivo está velho.

---

## 1. O que é um repasse

A linha `payout` do relatório de liberações do Mercado Pago: **dinheiro saindo da
conta do Mercado Pago para o banco do cliente**. No período medido são 36 linhas e
36 lotes, um para um — nenhuma transferência falta. O `external_id` é
`MLREL-<id do saque>-PAYOUT`.

Quem escolhe o valor é o cliente, ao sacar. **O valor sacado não tem relação com as
vendas anexadas ao lote**, e a medição de 2026-09-28 mostra o tamanho disso: em
**todos os 36** o líquido do lote difere do que saiu de verdade.

| | |
|---|---|
| saiu para o banco (36 linhas `payout`) | **R$ 194.551,00** |
| "líquido dos repasses" na tela | **R$ 482.683,78** |

Os valores sacados são redondos — 500, 1.530, 3.102, 17.035 — porque são saque, não
repasse casado com venda. O saldo corrente do marketplace (`BALANCE_AMOUNT`) termina
em R$ 13.087,20 depois do último saque: a conta não acumula os R$ 288 mil de
diferença, o que confirma que os dois números medem coisas diferentes.

**O objeto `PayoutBatch` mistura duas coisas**: a transferência (sua linha de origem)
e a janela de vendas liberadas até ela. `gross_amount`/`net_amount` são da janela,
exceto quando a janela está vazia — aí caem para o valor do extrato. É a inconsistência
que produziu o caso `saque` (§9).

O dinheiro **entra** por venda, em cada linha `payment`, que credita a conta virtual.
O repasse é o dinheiro **saindo** dela.

Relação com notas fiscais: **muitos para muitos**. Um repasse tem de 9 a 267 notas
(mediana 93) e de 13 a 287 vendas (mediana 100). Dezessete notas de 3.584 aparecem em
DOIS repasses — compra de dois itens, uma nota, liberações em datas diferentes.

## 2. Quais vendas entram num repasse

`Financeiro::PayoutEngine#receivables`:

- recebíveis da mesma conta de plataforma,
- com `status: scheduled`,
- com `expected_on <= data do saque`,
- **exceto** os marcados como não-venda (`ReceivableUnit.vendas_reais`).

Essa associação é **construção nossa**, não um fato informado pelo marketplace.

## 3. Como o valor de um recebível é formado

`Financeiro::ReceivableEngine`. Um recebível **por PAGAMENTO** — `external_id` é
`MLREL-<pagamento>-SALE` —, e o valor dele soma as linhas **daquele pagamento**
(`source_id`), não as do pedido.

O pedido só é a chave quando não há `source_id` (lançamento manual, plataforma que não
informa pagamento).

- `gross_amount` = soma dos lançamentos `sale` do pagamento
- `fee_amount` = soma dos `fee`
- `net_amount` = bruto − taxas − deduções (`refund`, `chargeback`)

Recebível com `status` `paid` ou `cancelled` é **congelado**: não é recalculado, porque
o repasse já foi liquidado sobre os valores antigos. Corrigir exige
`recalcular_pagos: true` (`FORCAR=1` na tarefa), deliberadamente.

## 4. Lado interno: o que o marketplace pagou

```
valor_interno = payout.gross_amount − parcelamento_somado
```

`payout.gross_amount` é a soma dos `gross_amount` dos recebíveis do lote.

`somado_ao_bruto` é **o que o relatório somou ao bruto além da mercadoria**, decidido
nota por nota testando hipóteses NOMEADAS contra a sobra medida:

```
sobra = bruto das vendas aqui − valor_produtos × fração

hipóteses, nesta ordem:  parcelamento + frete   →   frete   →   parcelamento
vale a primeira cujo valor caia dentro de ± R$ 0,10 da sobra
```

A soma vem primeiro de propósito: se ela bate, testar as parcelas isoladas antes faria o
motor casar com uma e deixar a outra de fora. **Sobra que não bate com nenhuma hipótese
não é subtraída** — fica como diferença real. Subtrair a sobra inteira fecharia tudo por
construção.

O parcelamento vem do relatório; o frete vem da nota. Cada hipótese tem valor de fonte
independente, e a identidade que decide não envolve o número comparado.

Por que a decisão é necessária: o relatório **não** distingue os dois casos — nas duas
formas o líquido é `bruto − comissão − frete − parcelamento`. Medido:

| nota | produtos | bruto | componente | conclusão |
|---|---|---|---|---|
| 40920 | 108,97 | 124,43 | parcelamento 15,46 | somado ao bruto |
| 40504 | 173,33 | 173,33 | parcelamento 5,51 | custo do vendedor |
| 854203 | 154,65 | 196,64 | frete 41,99 | somado ao bruto |
| 850806 | 179,11 | 179,11 | frete 37,99 | fora do bruto |

**O frete se comporta dos dois jeitos, como o parcelamento.** Descoberto medindo o
repasse #35: os deltas terminavam em `,99` — 41,99, 30,99, 24,99, 6,99 —, que é faixa de
frete e não arredondamento.

Usar o **total** da nota para decidir seria circular; `valor_produtos` é outro campo, e
a identidade que decide não envolve o número comparado.

## 5. Lado esperado: o que o OMIE tem

Os títulos vêm de `ListarContasReceber` (`Omie::Readers::ReceivableTotals`), paginado
de 500 em 500, filtrado por **data de emissão** com 90 dias de folga para trás
(`EMISSION_LOOKBACK_DAYS`), porque nota de julho pode ter título vencendo em setembro.

**Os títulos foram criados por nós.** `omie:enviar_notas` manda `IncluirContaReceber`
com `valor_documento = invoice.total_amount` e
`codigo_lancamento_integracao = WLL-NF-<id da nota>`. O esperado não é um cálculo do
OMIE: é o eco do que enviamos.

**Chave de casamento**, em ordem:

1. número da nota, normalizado **sem zeros à esquerda** (`numero_documento_fiscal`, com
   `numero_documento` como reserva);
2. `external_id` do recebível, quando o repasse não tem nota nenhuma;
3. `external_id` do repasse, em último caso.

**O valor esperado de cada nota:**

```
esperado = (título + abatimento − frete_da_nota) × fração
```

O título vale a nota inteira, e a nota é `valor_produtos + valor_frete −
valor_desconto` — verificado contra o OMIE em 8 de 8 notas com frete:

| nota | produtos | frete | desconto | total | título no OMIE |
|---|---|---|---|---|---|
| 854018 | 189,65 | 22,65 | 15,18 | 197,12 | 197,12 |
| 854176 | 109,65 | 1,30 | 33,00 | 77,95 | 77,95 |

O bruto do relatório é só a **mercadoria**: o frete que o comprador pagou não passa pelo
bruto do vendedor, e os dois valores nem coincidem (NF 850806 traz frete 37,99 na nota
e o relatório desconta 21,65). Então somar o desconto e subtrair o frete devolve o
título a `produtos`, que é o que o bruto mede.

**`abatimento` = apenas o `valor_desconto` da NOTA.** O `COUPON_AMOUNT` do relatório
**nunca** ajusta o esperado.

Medido em 846 vendas com cupom (`conciliacao:reflexo_do_cupom`): em **756** delas
`bruto == valor_produtos` — a nota NÃO abateu o cupom — e em **zero** delas
`bruto − cupom == produtos`. As 90 restantes são nota de pacote, em que comparar o bruto
de uma venda com os produtos da nota inteira não vale. O campo `valor_desconto` não
distingue os casos: aparece `"0.00"` em 484 e positivo em 272 **dentro do mesmo grupo**,
então não há regra condicional a escrever.

**`fração`** = (bruto das vendas daquela nota **neste** repasse) ÷ (bruto de **todas** as
vendas ligadas àquela nota). Para nota que não é de pacote dá 1. É rateio, não medição:
a nota não diz quanto vale cada item.

## 6. Quando o repasse é comparado

`calcular_cobertura`:

- **`completa`**: há vendas, nenhuma sem nota, nenhuma nota dividida entre repasses, e
  todas as notas têm título.
- **`completa_com_exclusoes`**: não é completa, mas **pelo menos um** título foi
  encontrado. Compara e decompõe o que ficou de fora.
- **nenhuma das duas**: não compara. Status `manual_review`, mensagem "Nenhuma das N
  nota(s) deste repasse tem título no OMIE".

A regra antiga recusava comparar quando faltava qualquer peça, e duas vendas sem NF entre
268 travavam um repasse inteiro.

## 7. Decomposição da diferença

```
diferença = valor_interno − valor_omie

sem_nota    = Σ bruto dos recebíveis sem nota
sem_titulo  = Σ (nota + abatimento − frete) × fração, das notas sem título
ajustes     = 0   (não existe mais; ver §8)
resíduo     = |diferença| − sem_nota − sem_titulo − ajustes
```

O **resíduo** é o único número que fala sobre dinheiro que ninguém sabe explicar.

## 8. Por que `ajustes` é zero

Desconto e frete estão na **base** (§5). O parcelamento somado ao bruto também (§4). O
parcelamento que é custo do vendedor não abre lacuna entre venda e nota.

Antes existia `ajustes_conhecidos`, que somava causas e as limitava pela distância medida
com um `min` para não explicar mais do que a diferença tinha. Era remendo: explicação que
aparece em todo repasse ensina a ignorar a coluna, e ainda produzia resíduo negativo
quando componente e base mediam coisas diferentes.

## 9. Status e confiança

| status | quando |
|---|---|
| `matched` | \|diferença\| ≤ **R$ 0,01** (`ResultadoConciliacao::TOLERANCIA`) |
| `explicado` | é divergente, mas o resíduo ≤ R$ 0,10 — a diferença é inteiramente venda sem nota ou nota sem título |
| `saque` | nenhuma venda na janela, linha de origem é saída de dinheiro, e o saldo do marketplace **depois** da saída não é negativo |
| `divergent` | o resto |
| `manual_review` | nenhum título encontrado |

**`saque`** (2026-09-28). Dois dos 36 repasses não têm recebível nenhum — #33 e #44 —
e os dois caem no **mesmo dia** de outro saque que consumiu a janela antes deles. O
motor procurava título no OMIE, não achava, e lançava o valor cheio como diferença:
**R$ 3.602,00**, metade da diferença de toda a empresa, mandando alguém caçar uma nota
fiscal que não deveria existir. Saque se confere contra o **saldo**, não contra nota.

A terceira condição é o que impede a tautologia. Sem exigir `BALANCE_AMOUNT >= 0`, a
regra seria "não achei venda, logo está certo" — e fecharia por construção todo repasse
cuja ingestão falhou. `BALANCE_AMOUNT` é o saldo que o **próprio marketplace** calcula,
fonte independente da nossa; não-negativo depois da saída significa que o dinheiro que
saiu estava lá. Saldo negativo, saldo ausente, ou linha que não é `payout`/`withdrawal`
continuam em `manual_review`.

```
confiança = (1 − |diferença| ÷ valor_interno) × 100
```

**A confiança é relativa e o veredito é absoluto, e os dois não concordam.** Um repasse
com R$ 4,62 de diferença em R$ 20 mil tem 99,98% de confiança e aparece como divergente,
porque a tolerância é de um centavo sobre a soma de ~100 notas.

## 10. Erros conhecidos, medidos e não consertados

**~~Cupom sem reflexo na nota~~ — RESOLVIDO** em 2026-09-27 por medição, e vale como
lição de método. Eu mantive o cupom na regra porque tirá-lo fazia a soma dos 35 repasses
**subir** de R$ 14.029,73 para R$ 22.390,80, e li a soma menor como regra melhor. Era o
contrário: o cupom estava fechando lacunas que não tem direito de fechar, e **a diferença
verdadeira é a maior**. Soma menor não é evidência de nada.

**Nota sem `valor_produtos`.** A decisão do parcelamento (§4) não pode ser tomada, e ele
fica na base por omissão.

**Dezesseis de 35 diferenças são negativas** — o OMIE esperando mais que o marketplace
pagou. Candidatos: fração com denominador incompleto (se parte das vendas do pacote
nunca foi ingerida, a fração sai grande demais) e o cupom acima.

**Título duplicado infla o esperado.** O envio não é idempotente contra resposta perdida
por si; a proteção é o índice de códigos lido antes de enviar, e em envio de histórico a
falha dessa leitura **aborta** o envio.

## 11. O que esta conciliação NÃO verifica

**Que o dinheiro chegou.** O valor sacado não é comparado com nada. Esta conciliação
confere **cobertura fiscal** — toda venda tem nota, toda nota tem título — e não que o
Mercado Livre transferiu o valor correto.

Medido em 2026-09-28 e vale repetir aqui porque a tela não avisa: dos R$ 482.683,78 que
a coluna de líquido soma, **R$ 194.551,00 foram o que realmente saiu para o banco**. Quem
lê a tela como "o quanto o cliente recebeu" lê o número errado — é o quanto as vendas da
janela valeriam líquidas, e boa parte delas segue como saldo no marketplace.

Essa segunda conferência é a **Conta Virtual** (`Financeiro::ConciliacaoDeSaldo`): saldo
informado pela plataforma contra o nosso razão. Medido em 2026-09-27: total do relatório
R$ 8.294,05 contra R$ 6.491,71 nosso, R$ 1.802,34 de distância. O par comparado
(`total` do relatório × nosso `disponível + a liberar`) **não está verificado como
semanticamente idêntico**, e o nosso saldo disponível está em −R$ 24.946,11, que é
impossível numa conta real — os saques estão liquidados enquanto boa parte dos créditos
segue `scheduled`. É problema de estado do lançamento, não de dinheiro.

A conta que fecharia a pergunta — **saldo inicial + créditos − saques** — ainda não
existe.

## 12. Ferramentas de medição

| tarefa | responde |
|---|---|
| `conciliacao:rodar` | roda a conciliação (avisa quando FALHA e os números são da rodada anterior) |
| `conciliacao:confronto_do_repasse` | o número de agora ao lado do gravado, com quando cada registro foi escrito |
| `conciliacao:centavos_do_repasse` | nota por nota, com a mesma conta do motor: de onde vêm os centavos |
| `conciliacao:rateio_do_pacote` | fração de cada nota e o que ela produz |
| `conciliacao:reflexo_do_cupom` | o cupom está refletido na nota? |
| `conciliacao:chaves_que_faltam` | vendas sem nota, separadas por de quem é a providência |
| `conciliacao:recebiveis_repetidos` | o mesmo pagamento entrou duas vezes? |
| `conciliacao:recalcular_recebiveis` | refaz o valor dos recebíveis (reimportar NÃO faz isso) |
| `conciliacao:recalcular_repasses` | refaz o bruto dos repasses a partir das alocações |
| `omie:auditar_esperado` | título duplicado, título sem nota, valor que não bate |
| `fiscal:apuracao` | receita bruta por mês e canal, RBT12 |

**Ordem para corrigir valores em massa:** marcar → `recalcular_recebiveis` →
`recalcular_repasses` → conciliar. `marketplace:reimportar` **não** recalcula recebível
existente (pula por `external_id`, que é o que impede duplicata).

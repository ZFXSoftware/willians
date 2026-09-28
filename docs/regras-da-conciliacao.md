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

hipóteses, nesta ordem:  parcelamento + frete  →  frete  →  parcelamento
vale a primeira cujo valor caia dentro de ± R$ 0,10 da sobra

último recurso, quando NENHUMA fecha:  bruto − total_amount do pedido
```

**O último recurso: o valor do pedido** (2026-09-28). `GROSS_AMOUNT` é o que o
**comprador** pagou — mercadoria mais o juro do parcelamento que ele escolheu. Esse juro
nunca foi receita do vendedor, a nota não o documenta, e a diferença aparecia como
divergência: 169 notas, R$ 2.804,31.

Medido nas notas desse balde, 38 de 40 consultas ao Mercado Livre: a sobra é exatamente
`bruto − transaction_amount`, e naqueles 38 a transação é igual ao `valor_produtos` da
nota **e** ao `total_amount` do pedido. O campo do pedido é o usado porque é **por
pedido** — a transação é por pagamento e no pacote traz o pacote inteiro (medido: 346,66
e 633,65 contra mercadorias de 173,33 e 126,73).

**Não é circular**: `Order#total_amount` é escrito só pela ingestão do Mercado Livre, e o
Tiny cria pedido sem valor. Confrontá-lo com a nota confronta duas fontes independentes.

**É último recurso por medição, não por gosto.** Os três regimes, sobre as 3.718 notas:

| regime | fecham | soma \|deltas\| |
|---|---|---|
| (a) como era | 3514 | R$ 3.118,32 |
| **(b) pedido no último recurso** | **3674** | **R$ 983,69** |
| (c) pedido primeiro, sempre | 3615 | R$ 11.211,94 |

Trocar a base por inteiro **piora**: frete e parcelamento explicam de verdade boa parte
das vendas. E o pedido discorda da nota em **64 das 3.718** — ali a diferença é real, o
marketplace e a nota dizendo valores diferentes para a mesma venda, e continua aparecendo.

Sem valor no pedido não há último recurso: subtrair `bruto − 0` zeraria o lado interno e
inventaria diferença do tamanho do repasse.

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
esperado = (título + (valor_produtos − total_da_nota)) × fração
```

O título vale a nota inteira, e desce-se dele até a **mercadoria**, porque é a mercadoria
que o bruto do relatório mede.

**A ponte sai do total da nota, e não de `desconto − frete`** (2026-09-28). As duas são a
mesma conta sempre que a nota fecha com ela mesma — `total = produtos + frete − desconto`
—, e aí `produtos − total` *é* `desconto − frete`. A prova de que é a mesma: a troca
passou nos 607 testes sem uma linha de mudança.

A diferença aparece só quando a nota **não** fecha, e aí a conta antiga errava exatamente
pelo que faltava. Medido nas 39 notas do balde "delta sem causa nomeada", R$ 230,32: em
**39 de 39** o total difere de `produtos + frete − desconto`, e em **39 de 39** o título
do OMIE está igual ao total da nota. Duas formas:

| forma | notas | exemplo |
|---|---|---|
| abatimento dado e não declarado no campo de desconto | 34 | NF 849622 · total 145,65 · produtos 149,65 |
| juro do parcelamento embutido no total, ausente de produtos | 5 | NF 850015 · total 219,64 · produtos 199,65 |

**Não é circular**: o esperado sai do **título**, que vem do OMIE, e só o ajuste vem da
nota. Quando o título discorda do total da nota — título duplicado é o caso medido — a
diferença continua aparecendo, porque o ajuste não a cancela.

Sem `valor_produtos` não há mercadoria a que descer, e a conta antiga vale: usar `−total`
zeraria o esperado e inventaria uma diferença do tamanho da nota.

A nota é `valor_produtos + valor_frete − valor_desconto` na maioria — verificado contra o
OMIE em 8 de 8 notas com frete:

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

## 10. O que o ciclo faz sozinho

A pergunta que gerou esta seção: *"os próximos já vão pegar a regra nova? não vamos ter
que fazer sempre esse processo, certo?"* As regras sempre foram código — toda execução,
inclusive a automática de cinco em cinco minutos, lê `ComposicaoDaVenda`. Mas **três
coisas dependiam de eu rodar uma tarefa à mão**, e as três foram consertadas em
2026-09-28.

| o que era | o que é |
|---|---|
| janela de 30 dias; repasse mais antigo congelava com o status que tinha | a janela **mais** os repasses em aberto de qualquer data (`ids_da_janela_ou_em_aberto`) |
| `marcar_canceladas` à mão, perguntando ao ML pedido por pedido | `Marketplace::VendasCanceladas` no ciclo, com o estado que a ingestão já relê |
| `recalcular_repasses APLICAR=1` à mão depois de cada marcação | `Financeiro::TotaisDoRepasse`, chamado pela própria marcação |

**A janela.** O repasse #44, pago em 25/07, seguiu pedindo revisão manual por uma regra
que já existia — ele estava fora da janela de 30 dias. Agora repasse não resolvido volta
a ser conferido para sempre; resolvido (`matched`/`saque`) fica de fora, porque reler o
OMIE para reconfirmar o que já fecha custa e não muda nada.

**O cancelamento.** Nenhum arquivo em `app/` escrevia a marca de não-venda. Os 38
cancelamentos de 2026-09-28 estavam marcados à mão; o próximo entraria como receita de
novo. O estado do **pagamento** passou a ser capturado na ingestão
(`situacoes_de_pagamento`) porque é ele que separa cancelado-com-estorno de
cancelado-com-pagamento-aprovado — e foi essa distinção que separou 38 cancelamentos de 4
vendas reais sem nota.

**O relatório de liberações não serve para isso.** Das 38, só **uma** tem linha `refund`,
e essas linhas devolvem a **comissão** (`GROSS_AMOUNT` zero, `MP_FEE_AMOUNT` 25,55), não a
venda. Quem sabe é a API de pedidos.

**Ainda é manual**: apagar título duplicado no OMIE (é decisão do cliente) e marcar
não-vendas de origem histórica (`conciliacao:marcar_nao_vendas`), que é conserto do
passado e não acontece mais no código atual.

## 11. Erros conhecidos, medidos e não consertados

**~~Cupom sem reflexo na nota~~ — RESOLVIDO** em 2026-09-27 por medição, e vale como
lição de método. Eu mantive o cupom na regra porque tirá-lo fazia a soma dos 35 repasses
**subir** de R$ 14.029,73 para R$ 22.390,80, e li a soma menor como regra melhor. Era o
contrário: o cupom estava fechando lacunas que não tem direito de fechar, e **a diferença
verdadeira é a maior**. Soma menor não é evidência de nada.

**Nota sem `valor_produtos`.** A decisão do parcelamento (§4) não pode ser tomada, e ele
fica na base por omissão.

**Título duplicado infla o esperado.** O envio não é idempotente contra resposta perdida
por si; a proteção é o índice de códigos lido antes de enviar, e em envio de histórico a
falha dessa leitura **aborta** o envio.

### O que restava em 2026-09-28, medido nota por nota

De R$ 43.298,17 no começo do dia para **R$ 338,78**, com **27 dos 36 repasses conciliados**
e dois em `explicado` (diferença inteiramente atribuída às 4 vendas sem nota, R$ 658,60).

| causa | notas | valor | providência |
|---|---|---|---|
| título DUPLICADO no OMIE | 1 | R$ 169,65 | apagar no OMIE — decisão do cliente |
| nota de pacote: rateio | 1 | R$ 113,27 | fração com denominador incompleto: parte das vendas do pacote nunca foi ingerida |
| sobra sem hipótese | 3 | R$ 55,88 | o bruto traz algo que nem o relatório nem o pedido explicam |

O balde **"delta sem causa nomeada" zerou** — eram 39 notas e R$ 230,32, e a causa era a
nota não fechar com ela mesma (§5).

**Diferença negativa não abate diferença positiva.** A soma dos 36 com sinal dá menos que
a soma dos módulos, e é a dos **módulos** que mede o problema: um erro de +R$ 200 num
repasse e outro de −R$ 200 em outro são dois erros, não zero. Em 2026-09-28 eu reportei
R$ 6.987,65 quando o número honesto era R$ 7.205,13.

## 12. O que esta conciliação NÃO verifica

**Que o dinheiro chegou.** O valor sacado não é comparado com nada. Esta conciliação
confere **cobertura fiscal** — toda venda tem nota, toda nota tem título — e não que o
Mercado Livre transferiu o valor correto.

Medido em 2026-09-28 e vale repetir aqui porque a tela não avisa: dos R$ 482.683,78 que
a coluna de líquido soma, **R$ 194.551,00 foram o que realmente saiu para o banco**. Quem
lê a tela como "o quanto o cliente recebeu" lê o número errado — é o quanto as vendas da
janela valeriam líquidas, e boa parte delas segue como saldo no marketplace.

Essa segunda conferência é a **Conta Virtual** (`Financeiro::ConciliacaoDeSaldo`): saldo
informado pela plataforma contra o nosso razão. O par comparado (`total` do relatório ×
nosso `disponível + a liberar`) **não está verificado como semanticamente idêntico**.

### O extrato da conta virtual

A conta que faltava — **saldo inicial + entradas − saídas** — existe desde 2026-09-28, em
`Financeiro::ExtratoDaConta` e na tela de Saldos. O saldo disponível, que estava em
−R$ 24.946,11 (impossível numa conta real), está em **+R$ 14.992,27** depois das marcações
do dia, contra R$ 13.087,20 que o marketplace informa: **R$ 3.050,44 de distância**.

O que torna o extrato útil é a coluna do marketplace. `BALANCE_AMOUNT` é o saldo corrente
que ele mantém linha a linha, fonte independente da nossa, e onde os dois se separam está o
movimento — não um total.

**Três armadilhas, todas encontradas rodando no dado real e todas defeitos meus:**

1. **Saldo inicial não é divergência.** Começar o corrente em zero acusava a primeira linha
   do razão com um salto de −R$ 1.145,37, que era o saldo de 30/06 vindo de vendas
   anteriores à janela. O inicial é deduzido do primeiro instante: `saldo informado − soma
   dos movimentos dele`.
2. **A comparação é por INSTANTE, não por linha.** Várias linhas no mesmo instante são
   aplicadas por nós numa ordem e pelo marketplace na ordem dele; linha a linha, cada
   instante gera dois saltos opostos que quase se cancelam (`payment +9.829,95` e
   `reserve_for_dispute −9.821,95` no mesmo dia). Dentro do instante a ordem não importa.
3. **O que identifica um problema é o SALTO, não a distância.** Depois da primeira
   divergência todas as 4.900 linhas seguintes ficam distantes.

**O fio que sobra: execução de dívida.** Os saltos se concentram em linhas cuja
`EXTERNAL_REFERENCE` é `debt-execution-*` ou `MELIPAYMENTS-COLLECTIONATTEMPT-*` — o Mercado
Livre cobrando dívidas da conta. São **176 lançamentos, todos débito, R$ 190.359,46, e
nenhum crédito**. Um deles é explícito: débito de R$ 1.325,02 num saldo de R$ 965,72 — o
saldo DELES foi a zero, o nosso a negativo, e os R$ 359,30 são dívida que não foi cobrada.

**A distância líquida é pequena (R$ 3.050,44) diante do vaivém dos saltos**, o que quer
dizer que eles em boa parte se cancelam. Isso aponta para **como** essas linhas são
registradas, e não para dinheiro perdido — e é por isso que os R$ 190 mil de execução de
dívida são um fio a puxar com o cliente, não uma conclusão.

## 13. Ferramentas de medição

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

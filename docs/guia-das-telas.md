# Guia das telas: Conciliação e Conta virtual

O que significa cada status, cada coluna e cada valor. Escrito para quem usa o sistema, não
para quem o programa.

As duas telas respondem perguntas diferentes e é comum confundi-las:

| tela | pergunta |
|---|---|
| **Conciliação** | O que o marketplace pagou tem nota fiscal e título no OMIE? |
| **Conta virtual** | O dinheiro que entrou e saiu da conta do marketplace está todo registrado? |

A Conciliação confere **cobertura fiscal**. A Conta virtual confere **saldo**. Uma pode
fechar com a outra em aberto.

---

## 1. Conciliação

### 1.1 O que a tela compara

Cada linha é **um repasse** — uma transferência de dinheiro da conta do marketplace para o
banco do cliente — confrontado com os **títulos a receber no OMIE** das notas fiscais das
vendas que aquele repasse liquidou.

Os títulos no OMIE foram criados por nós, a partir das notas do ERP. Então o "esperado" não
é um cálculo do OMIE: é o eco das notas que enviamos.

### 1.2 Os quatro cartões do topo

| cartão | o que é |
|---|---|
| **Total Conciliado** | Soma dos valores dos repasses com status `Conciliado`. Não é receita nem saldo: é quanto do que foi comparado fechou. |
| **Divergências abertas** | Casos registrados para acompanhamento e ainda não resolvidos. Fecham sozinhos quando o repasse passa a bater. |
| **Execuções hoje** | Quantas vezes a conciliação rodou hoje. Ela roda sozinha a cada poucos minutos. |
| **Última execução** | Quando a última terminou. |

### 1.3 Os status

| status | o que significa | providência |
|---|---|---|
| **Conciliado** | A diferença é de no máximo R$ 0,01. O repasse fecha com os títulos. | nenhuma |
| **Diferença explicada** | Existe diferença, e ela está **inteiramente atribuída** a causas conhecidas — venda sem nota fiscal, nota sem título no OMIE. Os valores diferem, mas nada está sem resposta. | conferir a causa, não o valor |
| **Saque de saldo** | Saiu dinheiro para o banco e **nenhuma venda foi liberada** na janela daquele saque: é retirada de saldo acumulado. Não há título a comparar — a conferência é contra o saldo, na Conta virtual. | nenhuma |
| **Divergente** | Sobra diferença sem explicação. | é o único que pede alguém olhar |
| **Sem comparação** | Nenhum título do OMIE foi encontrado para o repasse. Não houve comparação — não é "deu diferença zero". | ver se as notas chegaram ao OMIE |
| **Pendente** | Ainda não conferido. | aguardar a execução |

> **Cor não é gravidade.** Verde é fechado, azul é explicado, cinza é saque, vermelho é
> divergente, amarelo pede revisão.

### 1.4 As colunas da tabela

| coluna | o que é |
|---|---|
| **Status** | Ver 1.3. |
| **Repasse** | A referência do repasse no marketplace. |
| **Plataforma** | Mercado Livre, Shopee, Amazon, Magalu. |
| **Esperado (OMIE)** | Soma dos títulos das notas daquele repasse, trazidos ao valor da mercadoria. Traço significa que **não houve comparação**, não que seja zero. |
| **Recebido** | O valor bruto das vendas que o repasse liquidou, descontado o que o marketplace somou além da mercadoria (juro do parcelamento escolhido pelo comprador, frete). |
| **Diferença** | `Recebido − Esperado`. **O sinal importa** — ver 1.5. |
| **Falta de nota** | Quanto da diferença é venda sem nota fiscal ou nota sem título no OMIE. É documento faltando, não dinheiro. |
| **Sem explicação** | O que sobra depois de descontar tudo o que tem causa conhecida. **É o único número da tela que fala de dinheiro que ninguém sabe explicar.** |
| **Confiança** | A diferença como percentual do valor. Um repasse com R$ 4,62 de diferença em R$ 20 mil mostra 99,98% e ainda aparece como divergente: a tolerância é de um centavo sobre a soma de ~100 notas. |
| **Data** | Quando o repasse foi conferido. A lista é ordenada pela data de **pagamento** do repasse. |

### 1.5 O sinal da diferença

Positivo e negativo pedem providências **opostas**:

- **Positivo** — o repasse pagou **mais** do que os títulos somam. Falta nota, falta título,
  ou o relatório somou algo à venda.
- **Negativo** — o OMIE espera **mais** do que o repasse pagou. **Título duplicado é a causa
  mais comum**: a mesma nota virou dois títulos.

Diferença negativa num repasse **não abate** a positiva de outro. Ao somar vários repasses,
use o valor absoluto: um erro de +R$ 200 e outro de −R$ 200 são dois erros, não zero.

### 1.6 Abrindo um repasse

Ao clicar num repasse, a tela lista as vendas que ele liquidou:

| coluna | o que é |
|---|---|
| **Pedido** | O número do pedido no marketplace. |
| **Liberado** | Quando o dinheiro daquela venda ficou disponível. |
| **Venda** | O valor bruto da venda no relatório do marketplace. |
| **NF** | O número da nota fiscal ligada à venda. Vazio = venda sem nota. |
| **Valor NF** | O total da nota. |
| **Diferença** | Venda menos nota. |
| **Canal** | O canal de venda, lido do intermediador declarado na NF-e. |

Os totais mostrados acima da lista são do **repasse inteiro**, mesmo quando a lista está
paginada.

### 1.7 Avisos que aparecem

- **"Números provisórios"** — há notas na fila para virar título no OMIE. Enquanto isso,
  todo repasse é comparado contra uma parte dos títulos, e a diferença apontada é maior do
  que a real.
- **"Notas emitidas sem valor"** — essas notas não viram título nunca. O repasse que contiver
  uma delas é comparado sem ela, e a correção é no ERP.
- **"Conciliação em andamento"** — os números só mudam quando a execução terminar.

### 1.8 O resumo da última execução

`Repasses`, `Títulos no OMIE`, `Com nota fiscal`, `Conferidos`, `Sem título`. Se
`Com nota fiscal` for zero, nenhum repasse tem como casar: é o número da NF que liga os dois
lados.

---

## 2. Conta virtual

### 2.1 O que a tela compara

A conta do marketplace (no Mercado Livre, a conta do Mercado Pago) recebe o dinheiro de cada
venda e o cliente **saca** para o banco quando quer. Esta tela compara o **saldo que a
plataforma informa** com o **saldo que o nosso razão calcula**.

### 2.2 Os três cartões do topo

`Conferem`, `Com diferença`, `Nunca conferidas` — a contagem de contas de marketplace em
cada situação.

### 2.3 As situações

| situação | o que significa |
|---|---|
| **Confere** | Os dois saldos batem. |
| **Diferença** | Não batem. O caso também fica registrado em Divergências. |
| **Nunca conferido** | Não houve conferência para essa conta ainda. Use "Conferir agora". |

### 2.4 Os dois lados do saldo

**Na plataforma** — o que o marketplace informa:

| valor | o que é |
|---|---|
| **Disponível** | Saldo livre para saque, segundo a plataforma. |
| **Total** | Disponível mais o que ainda vai liberar. |

**No nosso razão** — o que os lançamentos somam:

| valor | o que é |
|---|---|
| **Disponível** | Créditos liquidados menos débitos liquidados. |
| **A liberar** | Vendas já registradas cujo dinheiro ainda não ficou disponível. |
| **Total** | Disponível mais a liberar. |
| **Bloqueado** | Valor preso em disputa. |

### 2.5 A diferença e a base da comparação

A tela diz **entre quais valores** a diferença foi medida, porque existem três pares
possíveis:

| base | comparação |
|---|---|
| `disponível na plataforma x disponível aqui` | os dois disponíveis |
| `a liberar na plataforma x a liberar aqui` | os dois futuros |
| `total do relatório x disponível + a liberar` | usado no Mercado Livre, que **não informa** o disponível no relatório de liberações |

O sinal, aqui também, significa coisas opostas:

- **Positivo** — a plataforma informa **mais** do que o nosso razão registra: há crédito que
  não entrou aqui.
- **Negativo** — o nosso razão registra **mais** do que ela reconhece: há saída que não foi
  baixada.

> A base `total` é o melhor par disponível e **não está verificado como semanticamente
> idêntico** dos dois lados. A diferença nela é ponto de partida para investigar, não
> veredito.

### 2.6 O extrato

Abaixo dos cartões, movimento a movimento. É aqui que se responde **como o saldo chegou ao
valor que está**.

**Os quatro valores do topo:**

| valor | o que é |
|---|---|
| **Saldo antes do primeiro movimento** | O que a conta já tinha antes do primeiro movimento que importamos, deduzido do saldo que a plataforma informa. Sem ele, a primeira linha do razão apareceria como divergência. |
| **Entrou** | Soma de tudo que creditou a conta no período. |
| **Saiu** | Soma de tudo que debitou. |
| **Disponível hoje** | O saldo atual do nosso razão. |

**Por tipo de movimento** — é aqui que se vê qual movimento drena a conta:

| coluna | o que é |
|---|---|
| **Movimento** | O tipo, como o marketplace o nomeia. Ver 2.7. |
| **Linhas** | Quantas linhas do relatório daquele tipo. |
| **Entrou / Saiu** | Crédito e débito do tipo. |
| **Resultado** | Entrou menos saiu. Negativo em vermelho. |
| **Pendentes** | Lançamentos ainda não liquidados. Um tipo com saída liquidada e entrada pendente deixa o saldo negativo **sem nada estar errado no dinheiro** — é estado de lançamento. |

**Movimentos em que os saldos discordam** — a lista do que investigar:

| coluna | o que é |
|---|---|
| **Quando / Movimento / Origem** | o instante, o tipo e o pedido ou a referência do marketplace |
| **Salto** | Quanto o nosso saldo se afastou do dele **naquele movimento** |

O que identifica um problema é o **salto**, não a distância acumulada: depois da primeira
divergência, todos os saldos seguintes ficam distantes porque a diferença se carrega para
frente. Corrigir o movimento do salto corrige os seguintes.

**Movimentos, do mais recente:**

| coluna | o que é |
|---|---|
| **Quando** | Data e hora do movimento. |
| **Movimento** | O tipo, com quantos lançamentos nossos e quantos estão pendentes. |
| **Pedido** | O pedido no marketplace, quando existe. |
| **Valor** | Quanto o movimento somou ou subtraiu. |
| **Saldo aqui** | O saldo corrente do nosso razão depois dele. |
| **Saldo na plataforma** | O saldo que o marketplace informa naquela linha. |
| **Distância** | Diferença entre os dois. `confere` quando estão a menos de dez centavos. |

### 2.7 Os tipos de movimento do Mercado Livre

| tipo | o que é | conta como venda? |
|---|---|---|
| `payment` | Venda, e as taxas dela: comissão, frete e juro do parcelamento vêm como linhas do mesmo movimento | **sim**, o bruto |
| `payout` | Saque para o banco | não: é saída de dinheiro |
| `reserve_for_dispute` | Valor reservado enquanto uma disputa corre | não |
| `mediation` | Mediação de reclamação | não |
| `refund` | Devolução — normalmente o marketplace devolvendo a **comissão**, não a venda | não |
| `shipping` | Ajuste de frete | não |
| `cashback` | Bonificação | não |
| `mediation_cancel` | Cancelamento de mediação | não |

Movimento de **saída sem pedido** cuja referência é `debt-execution-*` ou
`MELIPAYMENTS-COLLECTIONATTEMPT-*` é o marketplace **cobrando uma dívida** da conta. Não é
venda nem estorno de venda.

---

## 3. Perguntas que as telas já receberam

**"O Disponível está negativo. Como assim?"** Saldo negativo numa conta real é impossível, e
o número vem do nosso razão, não da plataforma. As causas são de lançamento: saída liquidada
com a entrada correspondente ainda pendente, ou débito registrado sem o crédito do par. O
extrato (2.6) aponta o movimento.

**"Um repasse conciliou. Posso confiar nos outros?"** O tratamento é idêntico — mesmo código,
mesmas regras. Os **dados** não são. Um repasse fecha quando todas as notas dele cabem nas
explicações conhecidas.

**"O líquido do repasse é o que caiu na conta do cliente?"** **Não.** O valor mostrado é o
que as vendas daquela janela valeriam líquidas. O que saiu para o banco é a linha `payout`,
visível no extrato da Conta virtual. Os dois números costumam ser bem diferentes, porque o
saque é escolhido pelo cliente e não tem relação com as vendas da janela.

**"A diferença some sozinha?"** Parte sim: divergência que volta a bater é fechada
automaticamente, e repasse que ainda não fechou continua sendo reconferido a cada execução,
mesmo que seja antigo.

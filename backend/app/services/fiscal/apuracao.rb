module Fiscal
  # A conciliação FISCAL: receita bruta por mês e canal, segregada por
  # tributação.
  #
  # A pergunta que originou isto foi "quais impostos foram pagos nas notas e
  # quais foram pagos antecipadamente pelos marketplaces". Medindo as notas do
  # cliente, a resposta literal é "nenhum": ele é Simples Nacional (CRT 1 em
  # 12 de 12 notas conferidas), então vICMS, vPIS, vCOFINS e vIPI saem ZERO na
  # NF-e, e `TAXES_AMOUNT` veio zero em 1.718 pagamentos do Mercado Livre. Não
  # existe imposto por nota para conciliar, e uma tela que somasse esses campos
  # mostraria zero para sempre — parecendo defeito.
  #
  # O que existe, e é o que o contador precisa, é OUTRA conta: no Simples o
  # imposto é apurado sobre a RECEITA BRUTA do mês, e a receita de produto com
  # substituição tributária entra no PGDAS segregada, porque o ICMS dela já foi
  # recolhido antes. Então a conciliação fiscal aqui é:
  #
  #   receita bruta do mês, por canal, separando o que tem ST do que não tem
  #
  # `vTotTrib` NÃO entra: é estimativa do IBPT exigida pela Lei da
  # Transparência, não imposto pago. Somá-lo produziria um número grande e
  # falso, que é exatamente o tipo de erro que esta tela precisa não cometer.
  #
  # Duas fontes, sinais diferentes para a mesma coisa: as notas do Tiny trazem
  # `valor_icms_st`; as do Mercado Livre trazem o CSOSN por item, onde 500 e 60
  # significam "ICMS cobrado anteriormente por substituição". Quem não tem bloco
  # fiscal nenhum fica em `indefinido` — contado e visível, nunca somado a um
  # dos dois lados. Ver [[Fiscal::Tiny::Canal]] para o canal.
  class Apuracao
    # CSOSN de mercadoria cuja substituição já ocorreu.
    CSOSN_COM_ST = %w[500 60 201 202 203].freeze

    # Os que dizem explicitamente que NÃO há ST. Mantidos à parte de
    # `CSOSN_COM_ST` porque a ausência de sinal não é sinal de ausência: nota
    # sem CSOSN reconhecido vai para `indefinido`, e não para `sem_st`. O 900
    # ("outros") fica fora das duas de propósito — ele não decide nada, e eu o
    # tinha posto nas DUAS listas, onde a primeira a ser testada venceria.
    CSOSN_SEM_ST = %w[101 102 103 300 400].freeze

    def initialize(tenant:, de: nil, ate: nil)
      @tenant = tenant

      @ate = (ate || Date.current).to_date

      @de = (de || @ate.beginning_of_month - 11.months).to_date
    end

    def call
      linhas = carregar

      {
        periodo: { de: de, ate: ate },
        meses: por_mes(linhas),
        total: totalizar(linhas.reject { |l| l[:devolucao] }),
        cobertura: cobertura(linhas),
        # A resposta à pergunta literal, medida e não suposta.
        retido_pelo_marketplace: retido_pelo_marketplace,
        regimes: linhas.filter_map { |l| l[:regime].presence }.tally
      }
    end

    private

    attr_reader :tenant, :de, :ate

    CAMPOS = [
      :id,
      :issued_at,
      :total_amount,
      :operation_type,
      Arel.sql("jsonb_typeof(invoices.metadata->'fiscal') = 'object' AS tem_fiscal"),
      Arel.sql("invoices.metadata->'fiscal'->>'valor_icms_st' AS valor_icms_st"),
      Arel.sql("invoices.metadata->'fiscal'->>'valor_icms' AS valor_icms"),
      Arel.sql("invoices.metadata->'fiscal'->>'valor_ipi' AS valor_ipi"),
      Arel.sql("invoices.metadata->'fiscal'->>'valor_issqn' AS valor_issqn"),
      Arel.sql("invoices.metadata->'fiscal'->>'regime_tributario' AS regime"),
      Arel.sql("invoices.metadata->'fiscal'->'csosns' AS csosns"),
      Arel.sql("invoices.metadata->'intermediador'->>'nome' AS intermediador")
    ].freeze

    # Uma consulta, campos escolhidos: `metadata` inteiro são milhares de linhas
    # com alguns KB cada, e nada aqui precisa do resto dele.
    def carregar
      Invoice
        .where(tenant_id: tenant.id)
        .where.not(status: :cancelled)
        .where(operation_type: [ :sale, :refund ])
        .where(issued_at: de.beginning_of_day..ate.end_of_day)
        .pluck(*CAMPOS)
        .map { |valores| montar(valores) }
    end

    def montar(valores)
      id, emitida_em, valor, operacao, tem_fiscal,
        icms_st, icms, ipi, issqn, regime, csosns, intermediador = valores

      {
        id: id,
        mes: emitida_em&.to_date&.strftime("%Y-%m"),
        valor: valor.to_d,
        devolucao: operacao.to_s == "refund",
        tem_fiscal: tem_fiscal == true,
        icms_st: icms_st.to_d,
        icms_st_informado: icms_st.present?,
        icms: icms.to_d,
        ipi: ipi.to_d,
        issqn: issqn.to_d,
        regime: regime,
        csosns: lista_de(csosns),
        canal: Fiscal::Tiny::Canal.para(intermediador, tenant: tenant),
        intermediador: intermediador
      }
    end

    # O jsonb pode voltar como Array já decodificado ou como String, conforme o
    # adaptador. Texto que não for JSON não pode derrubar a apuração inteira.
    def lista_de(csosns)
      return Array(csosns) unless csosns.is_a?(String)

      valor = JSON.parse(csosns)

      valor.is_a?(Array) ? valor : []
    rescue JSON::ParserError
      []
    end

    # Com ST, sem ST, ou indefinido — e indefinido não é chute para nenhum lado.
    def tributacao(linha)
      return :indefinido unless linha[:tem_fiscal]

      return :com_st if linha[:icms_st].positive?

      csosns = linha[:csosns].map(&:to_s)

      return :com_st if csosns.intersect?(CSOSN_COM_ST)

      return :sem_st if csosns.intersect?(CSOSN_SEM_ST)

      # CSOSN existe e não é nenhum dos conhecidos — 900 ("outros") é o caso.
      # Cair no atalho do valor zerado mandaria essa nota para `sem_st`, que é
      # afirmar o que o documento não afirma.
      return :indefinido if csosns.any?

      # Sem CSOSN, sobra o valor de ST — e só se ele foi INFORMADO. Nota do
      # Mercado Livre não traz esse campo, e `nil.to_d` é zero: sem distinguir
      # ausente de zero, toda nota do ML sem CSOSN reconhecido viraria "sem ST".
      linha[:icms_st_informado] ? :sem_st : :indefinido
    end

    def por_mes(linhas)
      linhas.group_by { |linha| linha[:mes] }.sort.map do |mes, doo|
        vendas = doo.reject { |l| l[:devolucao] }

        devolucoes = doo.select { |l| l[:devolucao] }

        totalizar(vendas).merge(
          mes: mes,
          devolucoes: { notas: devolucoes.size, valor: soma(devolucoes).to_s },
          receita_liquida: (soma(vendas) - soma(devolucoes)).to_s,
          por_canal: por_canal(vendas)
        )
      end
    end

    def totalizar(vendas)
      grupos = vendas.group_by { |linha| tributacao(linha) }

      {
        notas: vendas.size,
        receita_bruta: soma(vendas).to_s,
        segregacao: [ :com_st, :sem_st, :indefinido ].to_h do |tipo|
          lista = grupos[tipo].to_a

          [ tipo, { notas: lista.size, receita: soma(lista).to_s } ]
        end,
        # Fica aqui para ser LIDO como zero, não para somar: é a prova de que no
        # Simples não há imposto na nota, e quem abrir a tela vai perguntar.
        impostos_na_nota: {
          icms: vendas.sum(BigDecimal("0")) { |l| l[:icms] }.to_s,
          icms_st: vendas.sum(BigDecimal("0")) { |l| l[:icms_st] }.to_s,
          ipi: vendas.sum(BigDecimal("0")) { |l| l[:ipi] }.to_s,
          issqn: vendas.sum(BigDecimal("0")) { |l| l[:issqn] }.to_s
        }
      }
    end

    def por_canal(vendas)
      vendas.group_by { |linha| linha[:canal] }.map do |canal, lista|
        {
          canal: canal,
          rotulo: rotulo_de(canal),
          notas: lista.size,
          receita: soma(lista).to_s,
          # Canal em branco é nome de intermediador que ninguém mapeou. Mostrar
          # QUAL nome é o que torna a tela acionável: sem isso, "sem canal: 23
          # notas" não diz o que fazer.
          intermediadores: canal.nil? ? lista.filter_map { |l| l[:intermediador] }.uniq.sort : []
        }
      end.sort_by { |item| -item[:receita].to_d }
    end

    def rotulo_de(canal)
      return "Sem canal mapeado" if canal.blank?

      Fiscal::Tiny::Canal::OPCOES.find { |o| o[:canal] == canal }&.fetch(:rotulo) || canal
    end

    def cobertura(linhas)
      vendas = linhas.reject { |l| l[:devolucao] }

      com = vendas.count { |l| l[:tem_fiscal] }

      {
        notas: vendas.size,
        com_bloco_fiscal: com,
        sem_bloco_fiscal: vendas.size - com,
        # Quanto da RECEITA está sem detalhe fiscal. A contagem de notas engana:
        # cem notas pequenas sem detalhe pesam menos que uma grande.
        receita_sem_detalhe: soma(vendas.reject { |l| l[:tem_fiscal] }).to_s
      }
    end

    # O que o marketplace retém de imposto, pelo extrato dele.
    #
    # Medido zero em 1.718 pagamentos do Mercado Livre, e é assim que deve
    # aparecer: a pergunta "o marketplace já pagou imposto por mim?" tem uma
    # resposta, e ela é não. Somar do extrato e não da nota porque é ali que a
    # retenção apareceria se existisse.
    def retido_pelo_marketplace
      FinancialEntry
        .where(tenant_id: tenant.id)
        .where(occurred_at: de.beginning_of_day..ate.end_of_day)
        .where("jsonb_typeof(raw_payload) = 'object'")
        .where("(raw_payload->>'TAXES_AMOUNT') IS NOT NULL")
        .sum(Arel.sql("COALESCE(NULLIF(raw_payload->>'TAXES_AMOUNT','')::numeric, 0)"))
        .to_d
        .abs
        .to_s
    end

    def soma(lista) = lista.sum(BigDecimal("0")) { |linha| linha[:valor] }
  end
end

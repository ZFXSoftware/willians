module Fiscal
  module Tiny
    # De qual canal veio a venda, pelo intermediador declarado na NF-e.
    #
    # Antes disso o InvoiceSync atribuía toda nota à única conta de marketplace
    # ativa da empresa. Numa amostra de 40 notas do cliente, 17 eram do Mercado
    # Livre e 23 não — Shopee, Amazon, Magalu e TikTok, todas viradas em pedido
    # do Mercado Livre e jogadas na conciliação de uma conta que nunca vai
    # repassar por elas.
    #
    # O nome do intermediador é o que o cliente escolheu usar, e nem sempre é o
    # do marketplace: nas vendas da Amazon está a marca dele, "Alma teen". Por
    # isso a tabela é EDITÁVEL por empresa — os padrões cobrem os canais de
    # nome óbvio, e o resto alguém mapeia uma vez.
    #
    # Nome que não está na tabela devolve nil, e nil não vira palpite: a nota
    # fica sem canal, contada e visível. Chutar aqui é o defeito que este
    # arquivo existe para consertar.
    module Canal
      PADROES = {
        "mercado livre" => "mercado_livre",
        "mercadolivre" => "mercado_livre",
        "mercado pago" => "mercado_livre",
        "meli" => "mercado_livre",
        "shopee" => "shopee",
        "amazon" => "amazon",
        "amazon servicos de varejo do brasil" => "amazon",
        "magalu" => "magalu",
        "magazine luiza" => "magalu",
        "tiktok" => "tiktok",
        "tiktok shop" => "tiktok"
      }.freeze

      # Nem todo intermediador é marketplace.
      #
      # O cliente emite venda de balcão como venda digital por exigência
      # fiscal, e o intermediador dela é a marca da loja. Essa venda não tem
      # repasse de ninguém: precisa virar título no OMIE como qualquer outra, e
      # ficar FORA de toda conciliação de marketplace. Sem um canal para ela, a
      # única saída seria deixá-la sem canal — indistinguível de um nome que
      # ninguém mapeou ainda.
      PROPRIA = "loja_propria".freeze

      # O que a tela oferece. Marketplace primeiro, venda própria por último:
      # ela é a exceção, não a opção comum.
      OPCOES = [
        { canal: "mercado_livre", rotulo: "Mercado Livre" },
        { canal: "shopee", rotulo: "Shopee" },
        { canal: "amazon", rotulo: "Amazon" },
        { canal: "magalu", rotulo: "Magalu" },
        { canal: "tiktok", rotulo: "TikTok Shop" },
        { canal: PROPRIA, rotulo: "Venda própria — não é marketplace" }
      ].freeze

      # Onde a empresa guarda os nomes que só ela usa.
      CHAVE = "canais_por_intermediador".freeze

      def self.para(nome, tenant: nil)
        chave = normalizar(nome)

        return if chave.blank?

        do_tenant(tenant)[chave] || PADROES[chave]
      end

      # Minúsculas, sem acento e sem pontuação: "Mercado Livre", "MERCADO
      # LIVRE" e "Mercado-Livre" são o mesmo canal, e obrigar o cliente a
      # acertar a grafia seria transformar configuração em armadilha.
      def self.normalizar(nome)
        return if nome.blank?

        nome.to_s
            .unicode_normalize(:nfd)
            .gsub(/\p{Mn}/, "")
            .downcase
            .gsub(/[^a-z0-9]+/, " ")
            .strip
      end

      def self.do_tenant(tenant)
        return {} if tenant.blank?

        (tenant.metadata || {})[CHAVE].to_h.transform_keys { |k| normalizar(k) }
      end

      def self.marketplace?(canal)
        canal.present? && canal != PROPRIA
      end

      # Todo intermediador que apareceu nas notas, com quantas notas tem e para
      # onde está mapeado hoje.
      #
      # É a lista de trabalho da tela: enquanto um nome estiver sem canal, as
      # notas dele não viram pedido — e ninguém tem como adivinhar que "Alma
      # teen" é venda de balcão olhando para o código.
      def self.encontrados(tenant)
        Invoice
          .where(tenant_id: tenant.id)
          .where("invoices.metadata->'intermediador'->>'nome' IS NOT NULL")
          .group(Arel.sql("invoices.metadata->'intermediador'->>'nome'"))
          .group(Arel.sql("invoices.metadata->'intermediador'->>'cnpj'"))
          .count
          .map { |(nome, cnpj), notas| { nome: nome, cnpj: cnpj, notas: notas, canal: para(nome, tenant: tenant) } }
          .sort_by { |item| [ item[:canal] ? 1 : 0, -item[:notas] ] }
      end

      def self.nao_mapeados(tenant)
        encontrados(tenant).reject { |item| item[:canal] }.map { |item| item[:nome] }.sort
      end

      # Grava o mapa da empresa. Canal em branco APAGA o mapeamento daquele
      # nome — é como a tela desfaz uma escolha errada.
      def self.mapear!(tenant, nome, canal)
        validos = OPCOES.map { |o| o[:canal] }

        raise ArgumentError, "Canal desconhecido: #{canal}" if canal.present? && !validos.include?(canal)

        mapa = (tenant.metadata || {})[CHAVE].to_h

        canal.present? ? mapa[nome.to_s] = canal : mapa.delete(nome.to_s)

        tenant.update!(metadata: (tenant.metadata || {}).merge(CHAVE => mapa))

        mapa
      end
    end
  end
end

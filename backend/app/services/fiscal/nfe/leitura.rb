require "nokogiri"

module Fiscal
  module Nfe
    # Lê o XML da NF-e e devolve os campos fiscais como o resto do sistema os nomeia.
    #
    # Existe porque o JSON do ERP é a visão DELE do documento, e o documento é o XML. Três
    # coisas medidas em 2026-09-28 sobre as 7.395 notas do cliente justificam a leitura:
    #
    #   natureza da operação   4.269 de 6.371 do Tiny · ZERO das 1.024 do Mercado Livre
    #   CSOSN                    830 de 7.395
    #   PIS, COFINS, vTotTrib    campo nem existe
    #
    # E uma que ela CONFIRMA em vez de descobrir: ICMS, ST, IPI e ISSQN zerados nas notas
    # do cliente são a verdade, não falta de dado — emitente do Simples com CSOSN 102 não
    # destaca imposto. Antes do XML isso era hipótese.
    #
    # A ARMADILHA que esta classe existe para não cair: o XML de uma nota do Simples tem
    # `<CST>53</CST>` e `<CST>08</CST>`, e NENHUM dos dois é CST do ICMS — são do IPI e do
    # PIS/COFINS. Varrer o documento por `<CST>` e gravar como CST do ICMS faria a apuração
    # de um cliente do Regime Normal classificar errado, em silêncio. Cada CST é lido de
    # DENTRO do bloco do seu imposto.
    class Leitura
      # Não é NF-e: `infNFe` é a raiz do que interessa, e o Tiny e o Mercado Livre os dois
      # devolvem envelope de erro que também começa com "<".
      class NaoEhNfe < StandardError; end

      # Os totais ficam em `ICMSTot`, um por nota.
      TOTAIS = {
        "base_icms" => "vBC",
        "valor_icms" => "vICMS",
        "base_icms_st" => "vBCST",
        "valor_icms_st" => "vST",
        "valor_produtos" => "vProd",
        "valor_frete" => "vFrete",
        "valor_seguro" => "vSeg",
        "valor_desconto" => "vDesc",
        "valor_ipi" => "vIPI",
        "valor_pis" => "vPIS",
        "valor_cofins" => "vCOFINS",
        "valor_outras" => "vOutro",
        "valor_nota" => "vNF",
        # NÃO é imposto pago: é o total aproximado de tributos da Lei da Transparência.
        # O nome carrega isso porque chamá-lo de `valor_tributos` convidaria a somá-lo
        # como carga tributária — e alguém somaria.
        "total_aproximado_de_tributos" => "vTotTrib"
      }.freeze

      def self.para(xml) = new(xml).call

      def initialize(xml)
        @xml = xml.to_s
      end

      def call
        raise NaoEhNfe, "o conteúdo não tem infNFe" if raiz.nil?

        {
          "natureza_operacao" => texto("//ide/natOp"),
          "regime_tributario" => texto("//emit/CRT"),
          "chave" => raiz.attribute("Id")&.value.to_s.delete_prefix("NFe").presence,
          "cfops" => por_item("prod/CFOP"),
          "ncms" => por_item("prod/NCM"),
          "csosns" => de_dentro_do_icms("CSOSN"),
          # Do bloco do ICMS, e só dele. Ver a armadilha no topo da classe.
          "csts" => de_dentro_do_icms("CST"),
          "csts_ipi" => de_dentro_de("IPI", "CST"),
          "csts_pis" => de_dentro_de("PIS", "CST"),
          **totais,
          "fonte" => "xml"
        }.compact
      end

      private

      attr_reader :xml

      # Sem namespace: a NF-e declara `http://www.portalfiscal.inf.br/nfe`, e o XML que
      # vem do Tiny às vezes chega dentro de um envelope com outro. Tirar o namespace faz
      # um caminho só valer para as duas formas, em vez de duas listas de xpath para manter
      # em sincronia.
      def doc = @doc ||= Nokogiri::XML(xml).remove_namespaces!

      def raiz = @raiz ||= doc.at_xpath("//infNFe")

      def texto(caminho) = doc.at_xpath(caminho)&.text&.strip.presence

      def itens = @itens ||= doc.xpath("//det")

      def por_item(caminho)
        itens.filter_map { |item| item.at_xpath(caminho)&.text&.strip.presence }.uniq.presence
      end

      # O CSOSN e o CST do ICMS vivem dentro de `<imposto><ICMS><ICMSxx>`. Buscar a tag
      # solta pegaria a do IPI e a do PIS junto.
      def de_dentro_do_icms(tag) = de_dentro_de("ICMS", tag)

      def de_dentro_de(imposto, tag)
        itens.filter_map do |item|
          bloco = item.at_xpath("imposto/#{imposto}")

          bloco&.xpath(".//#{tag}")&.first&.text&.strip.presence
        end.uniq.presence
      end

      # `vST` é o nome do ICMS-ST no total da nota, e `vICMSST` é o nome dele no item. Os
      # dois são aceitos: a sonda mediu `vICMSST` AUSENTE nas notas do cliente, e concluir
      # dali que o campo não existe seria errado — ele existe com outro nome no total.
      def totais
        bloco = doc.at_xpath("//ICMSTot")

        return {} if bloco.nil?

        TOTAIS.filter_map do |nome, tag|
          valor = bloco.at_xpath(tag)&.text&.strip

          valor = bloco.at_xpath("vICMSST")&.text&.strip if valor.blank? && tag == "vST"

          next if valor.blank?

          [ nome, valor ]
        end.to_h
      end
    end
  end
end

module Fiscal
  module Tiny
    # Lê as notas fiscais emitidas e devolve, normalizado, o elo que a
    # conciliação precisa:
    #
    #   numero_ecommerce (pedido do marketplace) -> numero / chave (a NF)
    #
    # O número da NF é o que casa com `numero_documento` do título no Omie.
    class Reader
      MAX_PAGINAS = 200

      CLIENTES = {
        "v2" => "Fiscal::Tiny::V2Client",
        "v3" => "Fiscal::Tiny::V3Client"
      }.freeze

      def initialize(client: nil)
        @client = client || CLIENTES.fetch(Settings.version).constantize.new
      end

      SAIDA = "S".freeze

      # A devolução volta como nota de ENTRADA: é a mercadoria retornando.
      ENTRADA = "E".freeze

      # => Array de hashes normalizados
      def notas_fiscais(start_date:, end_date:, tipo: SAIDA)
        coletar do |pagina|
          client.pesquisar_notas(
            pagina: pagina,
            data_inicial: start_date,
            data_final: end_date,
            tipo: tipo
          )
        end
      end

      def notas_de_devolucao(start_date:, end_date:)
        notas_fiscais(start_date: start_date, end_date: end_date, tipo: ENTRADA)
      end

      def por_pedido(numero_ecommerce)
        coletar do |pagina|
          client.pesquisar_notas(pagina: pagina, numero_ecommerce: numero_ecommerce)
        end
      end

      private

      attr_reader :client

      def coletar
        notas = []

        pagina = 1

        loop do
          resultado = yield(pagina)

          notas.concat(Array(resultado[:itens]).map { |nota| normalizar(nota) })

          total = resultado[:total_paginas].to_i

          break if pagina >= total || total.zero?

          if pagina >= MAX_PAGINAS
            Rails.logger.warn "[Tiny] busca truncada em #{MAX_PAGINAS} páginas"

            break
          end

          pagina += 1
        end

        notas
      end

      def normalizar(nota)
        {
          id_tiny: nota["id"].to_s.presence,

          # É este campo que amarra a NF ao pedido do marketplace.
          numero_ecommerce: nota["numero_ecommerce"].to_s.presence,

          numero: nota["numero"].to_s.presence,

          serie: nota["serie"].to_s.presence,

          chave_acesso: nota["chave_acesso"].to_s.presence,

          data_emissao: parse_data(nota["data_emissao"]),

          valor: nota["valor"].to_d,

          tipo: nota["tipo"],

          situacao: nota["situacao"].to_s.presence,

          descricao_situacao: nota["descricao_situacao"].to_s.presence,

          bruto: nota
        }
      end

      def parse_data(valor)
        return if valor.blank?

        Date.strptime(valor.to_s, "%d/%m/%Y")
      rescue Date::Error
        nil
      end
    end
  end
end

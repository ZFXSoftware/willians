module Omie
  module Readers
    # Os cadastros do OMIE que a configuração precisa escolher: clientes,
    # contas correntes e o plano de contas.
    #
    # Existe para tirar o terminal do caminho. A ajuda dos campos mandava
    # "obtenha em ListarClientes", e a alternativa era uma tarefa de linha de
    # comando imprimindo códigos para copiar — o que funciona para quem tem
    # acesso ao servidor, e não para quem opera o sistema.
    #
    # SOMENTE LEITURA.
    class Opcoes
      PAGE_SIZE = 100

      # A conta do cliente tem milhares de clientes cadastrados. Sem busca, uma
      # lista dessas na tela é tão inútil quanto não ter lista.
      MAX_PAGINAS = 20

      FONTES = {
        "clientes" => {
          endpoint: "geral/clientes/", call: "ListarClientes",
          colecao: "clientes_cadastro", codigo: "codigo_cliente_omie",
          nomes: %w[razao_social nome_fantasia]
        },
        "contas_correntes" => {
          endpoint: "geral/contacorrente/", call: "ListarContasCorrentes",
          colecao: "ListarContasCorrentes", codigo: "nCodCC",
          nomes: %w[descricao cDesc nome]
        },
        "categorias" => {
          endpoint: "geral/categorias/", call: "ListarCategorias",
          colecao: "categoria_cadastro", codigo: "codigo",
          nomes: %w[descricao descricao_padrao]
        }
      }.freeze

      class TipoDesconhecido < StandardError; end

      def initialize(client: nil, tenant: Current.tenant)
        @client = client || Omie::Client.new(tenant: tenant)
      end

      # => [{ codigo:, nome: }]
      def call(tipo:, busca: nil, limite: 50)
        fonte = FONTES[tipo.to_s]

        raise TipoDesconhecido, "Tipo inválido: #{tipo}. Use #{FONTES.keys.join(', ')}." if fonte.nil?

        termo = busca.to_s.strip.downcase

        coletar(fonte, termo, limite)
      end

      private

      attr_reader :client

      def coletar(fonte, termo, limite)
        encontrados = []

        (1..MAX_PAGINAS).each do |pagina|
          resposta = client.request(
            fonte[:endpoint], fonte[:call],
            pagina: pagina, registros_por_pagina: PAGE_SIZE
          )

          registros = resposta[fonte[:colecao]] || resposta.values.find { |v| v.is_a?(Array) } || []

          break if registros.empty?

          encontrados.concat(filtrar(registros, fonte, termo))

          break if encontrados.size >= limite

          break if pagina >= (resposta["total_de_paginas"] || 1).to_i
        end

        encontrados.first(limite)
      end

      def filtrar(registros, fonte, termo)
        registros.filter_map do |registro|
          nome = fonte[:nomes].filter_map { |campo| registro[campo].presence }.first.to_s

          codigo = registro[fonte[:codigo]].to_s

          next if codigo.blank?

          next if termo.present? && !nome.downcase.include?(termo) && !codigo.include?(termo)

          { codigo: codigo, nome: nome }
        end
      end
    end
  end
end

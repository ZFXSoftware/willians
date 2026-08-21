module Marketplace
  module Shopee
    # Vários endpoints da Shopee recusam consulta de mais de 15 dias
    # (carteira e devoluções, ao menos). Quebrar o período é obrigação de quem
    # chama, e errar isso devolve `error_param` — ou, pior, meia resposta.
    module Janelas
      MAXIMO = 15.days

      # => [[inicio, fim], ...] sem buraco nem sobreposição
      def self.quebrar(start_date, end_date, maximo: MAXIMO)
        inicio = start_date.to_date

        fim = end_date.to_date

        pedacos = []

        while inicio <= fim
          ultimo = [inicio + maximo - 1.day, fim].min

          pedacos << [inicio, ultimo]

          inicio = ultimo + 1.day
        end

        pedacos
      end
    end
  end
end

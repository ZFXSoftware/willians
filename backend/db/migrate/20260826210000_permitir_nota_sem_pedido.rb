class PermitirNotaSemPedido < ActiveRecord::Migration[8.1]
  # A nota fiscal é documento do FISCO; o pedido é registro nosso.
  #
  # Com `order_id` obrigatório, apagar uma conta de marketplace conectada por
  # engano apagava os pedidos dela — e os pedidos levavam as notas fiscais
  # junto. Milhares de documentos sumindo por causa de um OAuth errado.
  #
  # Sem a coluna aceitar nulo, o `dependent: :nullify` do modelo também não
  # funciona: ele tenta gravar nulo e o banco recusa.
  def change
    change_column_null :invoices, :order_id, true
  end
end

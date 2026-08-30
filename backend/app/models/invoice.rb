# app/models/invoice.rb

class Invoice < ApplicationRecord
  belongs_to :tenant

  # Opcional porque a nota existe sem o nosso pedido: ela é documento do fisco,
  # e o pedido é registro nosso. Quem cria a nota (o InvoiceSync) sempre a
  # amarra a um pedido; isto aqui é para ela SOBREVIVER quando o pedido some.
  belongs_to :order, optional: true

  has_many :financial_entries,
           dependent: :nullify

  has_many :financial_entry_allocations,
           dependent: :nullify

  has_many :receivable_units,
           dependent: :nullify

  # A NF pode ser a da venda devolvida ou a própria nota de devolução.
  has_many :devolucoes,
           dependent: :nullify

  has_many :devolucoes_como_nota_de_devolucao,
           class_name: "Devolucao",
           foreign_key: :return_invoice_id,
           dependent: :nullify,
           inverse_of: :return_invoice

  # As que ainda não viraram título no OMIE.
  #
  # Num escopo só porque a pergunta aparece em dois lugares com significados
  # diferentes: o serviço de envio usa para saber o que mandar, e a tela de
  # conciliação para avisar que os números dela ainda vão mudar. Escrito duas
  # vezes, um dos dois divergiria — e aí a tela mentiria sobre o outro.
  scope :nao_enviadas_ao_omie, ->(marco = nil) {
    escopo = where(operation_type: :sale)
             .where.not(status: :cancelled)
             .where("invoices.metadata->>'omie_codigo_lancamento' IS NULL")
             .where("invoices.metadata->'omie_recusa' IS NULL")

    marco.present? ? escopo.where(issued_at: marco..) : escopo
  }

  # As que nós recusamos: nota sem valor ou sem CPF do comprador não tem como
  # virar título, e o OMIE recusaria. Ficam fora da fila de envio — senão o
  # ciclo automático as escolheria de novo a cada volta, para sempre, gastando
  # execução num caso que nunca vai passar — mas precisam continuar visíveis:
  # cada uma é uma venda que a conciliação não vai conseguir comparar.
  scope :recusadas_no_envio, -> {
    where(operation_type: :sale).where("invoices.metadata->'omie_recusa' IS NOT NULL")
  }

  # O que precisaria mudar para valer a pena tentar de novo. Guardado junto com
  # a recusa: quando o cliente corrigir a nota no Tiny, a reimportação vê que a
  # assinatura mudou e devolve a nota à fila sozinha.
  def assinatura_de_envio
    [ total_amount.to_d.to_s, (metadata || {})["comprador_documento"].to_s ].join("|")
  end

  def recusada_no_envio? = (metadata || {})["omie_recusa"].present?

  def recusar_envio!(motivo:, mensagem:)
    update!(metadata: (metadata || {}).merge(
      "omie_recusa" => {
        "motivo" => motivo.to_s,
        "mensagem" => mensagem,
        "em" => Time.current,
        "assinatura" => assinatura_de_envio
      }
    ))
  end

  # Devolve a nota à fila quando o dado que causou a recusa mudou.
  def liberar_recusa_se_mudou!
    recusa = (metadata || {})["omie_recusa"]

    return false if recusa.blank? || recusa["assinatura"] == assinatura_de_envio

    self.metadata = metadata.except("omie_recusa")

    true
  end

  enum :status, {
    issued: "issued",
    cancelled: "cancelled",
    denied: "denied",
    refunded: "refunded"
  }

  enum :operation_type, {
    sale: "sale",
    refund: "refund",
    adjustment: "adjustment"
  }

  validates :number,
            presence: true
end

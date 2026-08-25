module Financeiro
  # Liquida os recebíveis agendados de uma conta em um repasse do marketplace.
  #
  # Idempotente pela referência externa do repasse: reprocessar o mesmo
  # `payout_reference` devolve o lote já existente em vez de duplicar a baixa.
  class PayoutEngine
    def initialize(
      tenant:,
      platform_account:,
      payout_reference:,
      paid_at:,
      settlement_entry: nil
    )
      @tenant = tenant

      @platform_account = platform_account

      @payout_reference = payout_reference

      @paid_at = paid_at

      # Quando o repasse veio do EXTRATO do marketplace, o lançamento de
      # liquidação já existe — é a linha `payout` do relatório de liberações.
      # Criar outro duplicaria a saída de dinheiro no razão e esbarraria no
      # índice único de external_id.
      #
      # O engine nasceu para o caminho oposto, em que o repasse chega só como
      # referência e ele mesmo cria o lançamento. Os dois convivem.
      @settlement_entry = settlement_entry
    end

    def call
      existing = find_payout

      return existing if existing

      ActiveRecord::Base.transaction do
        payout = create_payout!(settlement_entry || create_settlement_entry!)

        allocate_receivables!(payout)

        settle_receivables!

        payout
      end
    rescue ActiveRecord::RecordNotUnique
      find_payout || raise
    end

    private

    attr_reader :tenant,
                :platform_account,
                :payout_reference,
                :paid_at,
                :settlement_entry

    def find_payout
      PayoutBatch.find_by(
        tenant: tenant,
        external_id: payout_reference
      )
    end

    def create_settlement_entry!
      FinancialEntry.create!(
        tenant: tenant,

        platform_account: platform_account,

        external_id: payout_reference,

        source: settlement_source,

        entry_type: :settlement,

        direction: :credit,

        amount: totals[:net],

        occurred_at: paid_at,

        available_on: paid_at.to_date,

        status: :settled,

        raw_payload: {
          platform: platform_account.platform,
          receivable_ids: receivables.map(&:id)
        }
      )
    end

    # `source` é um enum mais restrito que a lista de plataformas suportadas.
    def settlement_source
      return platform_account.platform if FinancialEntry.sources.key?(platform_account.platform)

      "manual"
    end

    def create_payout!(settlement_entry)
      PayoutBatch.create!(
        tenant: tenant,

        platform_account: platform_account,

        financial_entry: settlement_entry,

        external_id: payout_reference,

        status: :paid,

        # Quando nenhum recebível foi encontrado para este repasse, os totais
        # saem zerados — e o lote de uma transferência de R$ 50 aparecia como
        # R$ 0,00 na tela. O dinheiro saiu de verdade: o valor do extrato é a
        # única coisa que não é estimativa aqui, então ele é o piso.
        gross_amount: totals[:gross].positive? ? totals[:gross] : valor_do_extrato,

        fee_amount: totals[:fee],

        net_amount: totals[:net].positive? ? totals[:net] : valor_do_extrato,

        paid_at: paid_at
      )
    end

    def allocate_receivables!(payout)
      now = Time.current

      rows =
        receivables.flat_map do |receivable|
          receivable_allocations(receivable).map do |allocation|
            {
              tenant_id: tenant.id,

              financial_entry_id: allocation.financial_entry_id,

              receivable_unit_id: receivable.id,

              payout_batch_id: payout.id,

              order_id: allocation.order_id,

              invoice_id: allocation.invoice_id,

              allocation_type: "payout",

              allocated_amount: allocation.allocated_amount,

              amount: allocation.allocated_amount,

              metadata: { payout_reference: payout_reference },

              created_at: now,

              updated_at: now
            }
          end
        end

      return if rows.empty?

      FinancialEntryAllocation.insert_all(
        rows,
        unique_by: :idx_allocations_unique
      )
    end

    def receivable_allocations(receivable)
      receivable
        .financial_entry_allocations
        .select { |allocation| allocation.allocation_type == "receivable" }
    end

    def settle_receivables!
      return if receivables.empty?

      ReceivableUnit
        .where(id: receivables.map(&:id))
        .update_all(
          status: "paid",
          released_on: paid_at.to_date,
          updated_at: Time.current
        )
    end

    # Só existe quando o repasse veio do extrato do marketplace. No caminho em
    # que o engine cria o lançamento, o valor É a soma dos recebíveis.
    def valor_do_extrato
      settlement_entry&.amount.to_d
    end

    def totals
      @totals ||= {
        gross: sum_of(:gross_amount),
        fee: sum_of(:fee_amount),
        net: sum_of(:net_amount)
      }
    end

    def sum_of(field)
      receivables.sum(BigDecimal("0")) { |receivable| receivable.public_send(field).to_d }
    end

    def receivables
      @receivables ||=
        ReceivableUnit
          .where(
            tenant: tenant,
            platform_account: platform_account,
            status: :scheduled
          )
          .where(expected_on: ..paid_at.to_date)
          .includes(:financial_entry_allocations)
          .to_a
    end
  end
end

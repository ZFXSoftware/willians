# app/models/omie_financial_mapping.rb

class OmieFinancialMapping < ApplicationRecord
  belongs_to :tenant

  belongs_to :financial_entry

  validates :financial_entry_id,
            uniqueness: true
end
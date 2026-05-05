class ConciliacaoRegistro < ApplicationRecord
  enum :status, {
    ok: "ok",
    divergente: "divergente",
    nao_encontrado: "nao_encontrado"
  }
end

# Onde a nossa leitura da fila de DF-e parou, e até quando estamos de castigo.
#
# A distribuição da SEFAZ é uma fila incremental: cada consumidor guarda o
# próprio marcador (`ultNSU`) e pede o que vem depois. Quem recomeça do zero
# leva "consumo indevido" e uma hora de bloqueio — aconteceu na primeira
# chamada real, porque não havia onde guardar o marcador.
#
# O antiabuso da SEFAZ parece contar por CNPJ e não por consumidor: ela nos
# respondeu com o NSU de OUTRO sistema que já lê essa fila. Por isso o
# bloqueio é respeitado aqui, e não só registrado.
class LeituraSefaz < ApplicationRecord
  self.table_name = "leituras_sefaz"

  # A SEFAZ manda esperar uma hora. Uma folga em cima evita voltar no minuto
  # exato e levar outra.
  ESPERA_PADRAO = 65.minutes

  belongs_to :tenant

  def bloqueada? = bloqueado_ate.present? && bloqueado_ate > Time.current

  def minutos_de_espera
    return 0 unless bloqueada?

    ((bloqueado_ate - Time.current) / 60).ceil
  end

  def faltam
    return if max_nsu.blank?

    [ max_nsu - ultimo_nsu, 0 ].max
  end

  # Avança o marcador com o que a SEFAZ devolveu.
  #
  # Só para frente: NSU menor que o atual seria andar para trás na fila, que é
  # exatamente o que dispara o consumo indevido.
  def avancar!(resposta)
    novo = resposta.ultimo_nsu.to_i

    update!(
      ultimo_nsu: [ novo, ultimo_nsu ].max,
      max_nsu: resposta.max_nsu.to_i.positive? ? resposta.max_nsu.to_i : max_nsu,
      consultado_em: Time.current,
      ultimo_status: resposta.codigo,
      ultimo_motivo: resposta.motivo,
      bloqueado_ate: nil
    )
  end

  # "Consumo indevido": a SEFAZ diz de onde continuar e manda esperar.
  #
  # O NSU que ela devolve na rejeição é aproveitado — é a informação mais
  # confiável que temos sobre onde a fila está.
  def bloquear!(resposta)
    update!(
      ultimo_nsu: [ resposta.ultimo_nsu.to_i, ultimo_nsu ].max,
      consultado_em: Time.current,
      bloqueado_ate: ESPERA_PADRAO.from_now,
      ultimo_status: resposta.codigo,
      ultimo_motivo: resposta.motivo
    )
  end
end

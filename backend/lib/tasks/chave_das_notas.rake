# A chave de acesso da NF-e carrega, dentro dela, quem emitiu e qual nota é.
#
# Layout dos 44 dígitos (Manual de Orientação do Contribuinte):
#   cUF 2 · AAMM 4 · CNPJ 14 · mod 2 · série 3 · nNF 9 · tpEmis 1 · cNF 8 · cDV 1
#
# É a única fonte que não depende de ninguém interpretar nada: o número está lá,
# a série está lá, e o CNPJ de quem emitiu está lá.
module ChaveDaNota
  module_function

  CAMPOS = {
    uf: 0..1,
    aamm: 2..5,
    cnpj: 6..19,
    modelo: 20..21,
    serie: 22..24,
    numero: 25..33
  }.freeze

  def decompor(chave)
    limpa = chave.to_s.gsub(/\D/, "")

    return if limpa.length != 44

    CAMPOS.transform_values { |faixa| limpa[faixa] }
  end

  # "000002" -> "2"; "000041629" -> "41629"
  def sem_zeros(valor) = valor.to_s.sub(/\A0+/, "").presence || "0"
end

namespace :conciliacao do
  desc "O número que o marketplace informa é o número da NF-e? (SOMENTE LEITURA)"
  task chave_das_notas: :environment do
    # A pergunta que sustenta todo o caminho das "232 notas que faltam": o
    # `invoice_number` que o Mercado Livre devolve é o número da nota fiscal, ou
    # é numeração dele?
    #
    # Três vezes nesta investigação eu li um vazio meu como ausência do outro
    # lado. A chave de acesso não deixa margem: o número e a série estão DENTRO
    # dela, e o CNPJ de quem emitiu também.
    #
    # Nada de API: a chave veio do marketplace e está guardada no pedido.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    pedidos = Order
                .where(tenant_id: tenant.id)
                .where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")

    puts "Pedidos com a resposta do marketplace guardada: #{pedidos.count}"
    puts

    confere = 0
    divergem = []
    sem_chave = 0
    cnpjs = Hash.new(0)
    meses = Hash.new(0)

    pedidos.find_each do |pedido|
      dados = pedido.metadata["nota_do_envio"]

      partes = ChaveDaNota.decompor(dados["chave"])

      next sem_chave += 1 if partes.blank?

      cnpjs[partes[:cnpj]] += 1

      meses[partes[:aamm]] += 1

      numero_na_chave = ChaveDaNota.sem_zeros(partes[:numero])

      serie_na_chave = ChaveDaNota.sem_zeros(partes[:serie])

      numero_informado = ChaveDaNota.sem_zeros(dados["numero"])

      serie_informada = ChaveDaNota.sem_zeros(dados["serie"])

      if numero_na_chave == numero_informado && serie_na_chave == serie_informada
        confere += 1
      elsif divergem.size < 10
        divergem << format("    informado NF %-8s série %-3s · na chave NF %-8s série %-3s · %s",
                           numero_informado, serie_informada, numero_na_chave, serie_na_chave,
                           pedido.external_id)
      end
    end

    puts "O número e a série que o marketplace informa batem com a CHAVE?"
    puts format("  batem:            %d", confere)
    puts format("  divergem:         %d", pedidos.count - confere - sem_chave)
    puts format("  sem chave válida: %d", sem_chave)
    puts

    if divergem.any?
      puts "  Os primeiros que divergem:"
      puts divergem
      puts
      puts "  Divergindo, o `invoice_number` do marketplace NÃO é o número da NF-e,"
      puts "  e tudo o que foi construído em cima dele precisa ser revisto."
      puts
    end

    puts "CNPJ emissor, lido da chave:"

    cnpjs.sort_by { |_, quantas| -quantas }.first(5).each do |cnpj, quantas|
      formatado = cnpj.to_s.gsub(/\A(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})\z/, '\1.\2.\3/\4-\5')

      puts format("  %-20s %d nota(s)", formatado, quantas)
    end

    puts
    puts "  Mais de um CNPJ aqui explica o resto sem ninguém ter trocado de ERP:"
    puts "  o token do Tiny é de UMA empresa, e nota de outra não aparece na busca."
    puts

    puts "Mês de emissão, lido da chave (AAMM):"

    meses.sort.each { |aamm, quantas| puts format("  20%s-%s  %d nota(s)", aamm[0, 2], aamm[2, 2], quantas) }

    puts

    # E o outro lado: as notas que JÁ temos, com chave, conferem com o próprio
    # número que gravamos? Se não conferirem, o defeito é na nossa importação.
    nossas = Invoice
               .where(tenant_id: tenant.id)
               .where.not(access_key: nil)
               .where.not(number: nil)
               .limit(2000)

    bate = 0
    nao_bate = []

    nossas.each do |nota|
      partes = ChaveDaNota.decompor(nota.access_key)

      next if partes.blank?

      if ChaveDaNota.sem_zeros(partes[:numero]) == ChaveDaNota.sem_zeros(nota.number)
        bate += 1
      elsif nao_bate.size < 5
        nao_bate << format("    nossa NF %-10s · na chave dela: %s",
                           nota.number, ChaveDaNota.sem_zeros(partes[:numero]))
      end
    end

    puts "Controle — as notas que JÁ temos batem com a própria chave?"
    puts format("  batem: %d · não batem: %d", bate, nao_bate.size)

    puts nao_bate if nao_bate.any?

    puts
    puts "Nada foi gravado."
  end
end

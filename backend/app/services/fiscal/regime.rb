module Fiscal
  # O regime tributário do EMITENTE, normalizado — e qual conta fiscal ele pede.
  #
  # Existe porque a apuração não é a mesma para todos. No Simples o imposto é
  # apurado sobre a RECEITA BRUTA do mês e a nota sai com ICMS, PIS, COFINS e
  # IPI zerados; no Regime Normal a nota carrega imposto de verdade e a apuração
  # é a soma do que foi debitado, com crédito, base e ST. São duas telas
  # diferentes, e a primeira versão disto assumia Simples porque o primeiro
  # cliente é Simples.
  #
  # Cada fonte informa o regime com uma palavra própria: o Tiny manda o CRT
  # numérico da NF-e ("1", "2", "3"), o Mercado Livre manda texto ("simples").
  # Quem consome não pode precisar saber de qual API a nota veio.
  #
  # Valor que não reconhecemos devolve nil, e nil NÃO é tratado como Simples: uma
  # nota de Regime Normal apurada como Simples esconderia o imposto devido, que
  # é o pior erro que esta parte do sistema pode cometer. Ver
  # [[willians-conciliacao-fiscal]].
  module Regime
    SIMPLES = :simples

    SIMPLES_EXCESSO = :simples_excesso

    NORMAL = :normal

    # O CRT da NF-e, mais os nomes que cada integração usa.
    POR_VALOR = {
      "1" => SIMPLES,
      "2" => SIMPLES_EXCESSO,
      "3" => NORMAL,
      "4" => SIMPLES,
      "simples" => SIMPLES,
      "simples nacional" => SIMPLES,
      "simples_nacional" => SIMPLES,
      "mei" => SIMPLES,
      "simples excesso" => SIMPLES_EXCESSO,
      "normal" => NORMAL,
      "regime normal" => NORMAL,
      "lucro presumido" => NORMAL,
      "lucro real" => NORMAL
    }.freeze

    ROTULOS = {
      SIMPLES => "Simples Nacional",
      SIMPLES_EXCESSO => "Simples — excesso de sublimite",
      NORMAL => "Regime Normal"
    }.freeze

    # Sobre o que a apuração do regime se faz. É isto que a tela lê para decidir
    # qual coluna vem primeiro.
    BASES = {
      SIMPLES => :receita,
      SIMPLES_EXCESSO => :receita,
      NORMAL => :imposto
    }.freeze

    def self.normalizar(valor)
      return if valor.blank?

      chave = valor.to_s
                   .unicode_normalize(:nfd)
                   .gsub(/\p{Mn}/, "")
                   .downcase
                   .gsub(/[^a-z0-9]+/, " ")
                   .strip

      POR_VALOR[chave]
    end

    def self.rotulo(regime) = ROTULOS[regime] || "Regime não identificado"

    def self.base(regime) = BASES[regime]

    # Qual conta o conjunto pede. `:mista` é caso real, não defensivo: empresa
    # muda de regime na virada do ano, e aí o mesmo período tem notas dos dois —
    # cada mês apura pela sua, e somar os dois num número só seria inventar.
    def self.base_do_conjunto(regimes)
      bases = regimes.compact.map { |regime| base(regime) }.uniq

      return :indefinida if bases.empty?

      bases.size == 1 ? bases.first : :mista
    end
  end
end

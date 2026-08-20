# Plurais do português usados nos nomes de tabela e associação. Sem isto, o
# Rails singulariza "devolucoes" como "Devoluco" e não acha o modelo.
ActiveSupport::Inflector.inflections(:pt) do |inflect|
  inflect.irregular "devolucao", "devolucoes"
end

ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.irregular "devolucao", "devolucoes"
end

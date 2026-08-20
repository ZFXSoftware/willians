ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }

module ActiveSupport
  class TestCase
    # Sem paralelismo: vários testes manipulam ENV (credenciais, flags de
    # simulação), e isso não é isolável entre processos.
    #
    # Sem fixtures: o schema mudou muito desde que as geradas foram criadas, e
    # cada teste monta o cenário de que precisa — fica explícito o que está
    # sendo exercitado.
    include Cenario
  end
end

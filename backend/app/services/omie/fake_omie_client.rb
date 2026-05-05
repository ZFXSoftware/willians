module Omie  
  class FakeOmieClient
    def request(endpoint, call, params = {})
      {
        "conta_receber_cadastro" => [
          {
            "numero_documento" => "NF-001",
            "valor_documento" => 100.0,
            "codigo_lancamento_integracao" => "abc123"
          },
          {
            "numero_documento" => "NF-002",
            "valor_documento" => 200.0,
            "codigo_lancamento_integracao" => "def456"
          }
        ]
      }
    end
  end
end
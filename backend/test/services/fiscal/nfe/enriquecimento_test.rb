require "test_helper"

module Fiscal
  module Nfe
    # O XML completa a nota sem apagar o que o ERP já disse, e a recusa é gravada para o
    # ciclo de cinco minutos não bater para sempre na mesma nota sem documento.
    class EnriquecimentoTest < ActiveSupport::TestCase
      def setup
        @tenant = criar_tenant
        @conta = criar_conta(tenant: @tenant)
        @pedido = criar_pedido(tenant: @tenant, conta: @conta)
      end

      XML = <<~NFE
        <?xml version="1.0" encoding="UTF-8"?>
        <nfeProc xmlns="http://www.portalfiscal.inf.br/nfe">
          <NFe><infNFe Id="NFe35260912345678901234550010000123451234567890" versao="4.00">
            <ide><natOp>Venda de mercadorias Ecommerce</natOp></ide>
            <emit><CRT>1</CRT></emit>
            <det nItem="1">
              <prod><CFOP>6108</CFOP><NCM>64029990</NCM></prod>
              <imposto>
                <ICMS><ICMSSN102><CSOSN>102</CSOSN></ICMSSN102></ICMS>
                <IPI><IPINT><CST>53</CST></IPINT></IPI>
              </imposto>
            </det>
            <total><ICMSTot>
              <vProd>159.65</vProd><vDesc>1.00</vDesc><vNF>158.65</vNF>
              <vICMS>0.00</vICMS><vPIS>0.00</vPIS><vCOFINS>0.00</vCOFINS>
              <vST>0.00</vST><vTotTrib>50.21</vTotTrib>
            </ICMSTot></total>
          </infNFe></NFe>
        </nfeProc>
      NFE

      # Um dublê do cliente do Tiny: devolve o XML, ou levanta a recusa que o Tiny levanta.
      class TinyFalso
        def initialize(resposta) = @resposta = resposta

        def obter_xml(_id)
          raise @resposta if @resposta.is_a?(StandardError)

          @resposta
        end
      end

      def nota(fiscal: {}, numero: "500")
        registro = criar_nota(tenant: @tenant, pedido: @pedido, numero: numero, valor: 158.65)

        registro.update!(metadata: { "origem" => "tiny_invoice_sync", "fiscal" => fiscal })

        registro
      end

      def recusa
        Fiscal::Tiny::V2Client::ApiError.new("O Tiny não devolveu a NF-e: Nota Fiscal não autorizada")
      end

      def enriquecer(resposta = XML, limite: 50)
        Enriquecimento.new(tenant: @tenant, limite: limite, cliente_tiny: TinyFalso.new(resposta)).call
      end

      test "completa o que o ERP não trouxe" do
        registro = nota(fiscal: { "valor_produtos" => "159.65" })

        resumo = enriquecer

        assert_equal 1, resumo[:completadas]

        fiscal = registro.reload.metadata["fiscal"]

        assert_equal "Venda de mercadorias Ecommerce", fiscal["natureza_operacao"]
        assert_equal [ "102" ], fiscal["csosns"]
        assert_equal "0.00", fiscal["valor_pis"]
        assert_equal "50.21", fiscal["total_aproximado_de_tributos"]
      end

      # O que veio do ERP FICA. Trocar tudo pelo XML seria a mudança de base que já me
      # mordeu duas vezes: a medição decide qual fonte ganha, campo por campo.
      test "não sobrescreve o que o ERP já disse" do
        registro = nota(fiscal: { "valor_produtos" => "999.99", "natureza_operacao" => "Venda do ERP" })

        enriquecer

        fiscal = registro.reload.metadata["fiscal"]

        assert_equal "999.99", fiscal["valor_produtos"]
        assert_equal "Venda do ERP", fiscal["natureza_operacao"]
      end

      # As exceções nomeadas: o CST do ICMS porque o ERP entrega zero de 7.395, e o ST
      # porque é ele que decide a conta da apuração.
      test "o XML manda no CST do ICMS e no ST" do
        registro = nota(fiscal: { "csts" => [ "99" ], "valor_icms_st" => "123.45" })

        enriquecer

        fiscal = registro.reload.metadata["fiscal"]

        # A nota do Simples não tem CST de ICMS, então o campo não é tocado por valor vazio…
        assert_equal [ "99" ], fiscal["csts"], "valor vazio no XML não apaga o do ERP"
        # …e o ST, que o XML informa, substitui.
        assert_equal "0.00", fiscal["valor_icms_st"]
      end

      # "Nota Fiscal não autorizada" (código 34) é o caso medido: a nota existe no ERP e o
      # documento ainda não saiu. A recusa é gravada com o motivo.
      test "recusa do ERP é gravada com o motivo" do
        registro = nota

        assert_equal 1, enriquecer(recusa)[:recusadas]

        assert_equal "recusado", registro.reload.metadata.dig("xml", "situacao")
        assert_includes registro.metadata.dig("xml", "motivo"), "não autorizada"
        assert_equal 1, registro.metadata.dig("xml", "tentativas")
      end

      # O defeito que o dado real pegou: eu tratei recusa como definitiva. As 44 primeiras
      # recusas do cliente eram TODAS notas emitidas nos três dias anteriores, que a SEFAZ
      # ainda não havia autorizado — seriam autorizadas em horas e ficariam marcadas como
      # recusadas para sempre, sem nunca serem lidas.
      test "nota recente recusada é tentada de novo" do
        registro = nota

        enriquecer(recusa)

        assert_equal 1, enriquecer[:lidas], "tinha que voltar nela"
        assert_equal "lido", registro.reload.metadata.dig("xml", "situacao")
        assert_equal "Venda de mercadorias Ecommerce", registro.metadata["fiscal"]["natureza_operacao"]
      end

      # Mas não para sempre: passado o limite, a nota não vai ter documento e insistir é
      # ruído a cada cinco minutos.
      test "para de tentar depois do limite" do
        registro = nota

        Enriquecimento::MAX_TENTATIVAS.times { enriquecer(recusa) }

        assert_equal Enriquecimento::MAX_TENTATIVAS, registro.reload.metadata.dig("xml", "tentativas")
        assert_equal 0, enriquecer(recusa)[:lidas]
      end

      # Nota velha também sai da fila: ali a falta de autorização é o estado final dela.
      test "nota antiga recusada não é tentada de novo" do
        registro = nota

        registro.update!(issued_at: 60.days.ago)

        enriquecer(recusa)

        assert_equal 0, enriquecer(recusa)[:lidas]
      end

      # A ORDEM: quem nunca foi lida vem primeiro. As recusadas são justamente as mais
      # novas, e sem isso elas consumiriam o lote inteiro a cada volta — o histórico nunca
      # seria varrido.
      test "nota nunca lida tem prioridade sobre a recusada" do
        antiga_recusada = nota(numero: "800")

        enriquecer(recusa)

        assert_equal "recusado", antiga_recusada.reload.metadata.dig("xml", "situacao")

        nunca_lida = nota(numero: "801")

        enriquecer(XML, limite: 1)

        assert_equal "lido", nunca_lida.reload.metadata.dig("xml", "situacao")
        assert_equal 1, antiga_recusada.reload.metadata.dig("xml", "tentativas"),
                     "a recusada não deveria ter consumido o lote"
      end

      # Nota já lida também sai da fila, senão o lote de 50 leria sempre as mesmas 50.
      test "nota já lida não é lida de novo" do
        nota

        assert_equal 1, enriquecer[:completadas]
        assert_equal 0, enriquecer[:lidas]
      end

      # Corpo que não é NF-e é recusa. Tratar 208 bytes de erro como documento já rendeu um
      # diagnóstico errado nesta base.
      test "resposta que não é NF-e não vira dado fiscal" do
        registro = nota(fiscal: { "valor_produtos" => "159.65" })

        assert_equal 1, enriquecer("<retorno><status>Erro</status></retorno>")[:recusadas]

        assert_nil registro.reload.metadata["fiscal"]["natureza_operacao"]
        assert_equal "159.65", registro.metadata["fiscal"]["valor_produtos"]
      end

      # Nota do Tiny sem identificador não tem de onde buscar — e isso é situação, não erro.
      test "nota sem caminho para o XML é registrada como tal" do
        registro = criar_nota(tenant: @tenant, pedido: @pedido, numero: "777", valor: 10)

        registro.update!(external_id: nil, metadata: { "origem" => "tiny_invoice_sync" })

        assert_equal 1, enriquecer[:sem_caminho]
        assert_equal "sem_caminho", registro.reload.metadata.dig("xml", "situacao")
      end

      test "o limite corta o lote" do
        3.times { |i| nota(numero: "60#{i}") }

        assert_equal 2, enriquecer(XML, limite: 2)[:lidas]
      end
    end
  end
end

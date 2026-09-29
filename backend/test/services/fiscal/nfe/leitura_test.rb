require "test_helper"

module Fiscal
  module Nfe
    # O XML é o documento; o JSON do ERP é a visão dele. Este teste guarda o que a leitura
    # tem que extrair — e principalmente a armadilha do CST.
    class LeituraTest < ActiveSupport::TestCase
      # Uma NF-e de emitente do Simples, com a estrutura real medida em 2026-09-28: CSOSN
      # dentro do ICMS, e CST dentro do IPI e do PIS/COFINS — nenhum deles do ICMS.
      def nfe(natureza: "Venda de mercadorias Ecommerce", cfop: "6108", st: nil)
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <nfeProc xmlns="http://www.portalfiscal.inf.br/nfe">
            <NFe>
              <infNFe Id="NFe35260912345678901234550010000123451234567890" versao="4.00">
                <ide><natOp>#{natureza}</natOp></ide>
                <emit><CRT>1</CRT></emit>
                <det nItem="1">
                  <prod><CFOP>#{cfop}</CFOP><NCM>64029990</NCM></prod>
                  <imposto>
                    <ICMS><ICMSSN102><CSOSN>102</CSOSN></ICMSSN102></ICMS>
                    <IPI><IPINT><CST>53</CST></IPINT></IPI>
                    <PIS><PISNT><CST>08</CST></PISNT></PIS>
                    <COFINS><COFINSNT><CST>08</CST></COFINSNT></COFINS>
                  </imposto>
                </det>
                <total>
                  <ICMSTot>
                    <vBC>0.00</vBC><vICMS>0.00</vICMS>
                    <vBCST>0.00</vBCST>#{st ? "<vST>#{st}</vST>" : "<vST>0.00</vST>"}
                    <vProd>159.65</vProd><vFrete>0.00</vFrete><vSeg>0.00</vSeg>
                    <vDesc>1.00</vDesc><vIPI>0.00</vIPI><vPIS>0.00</vPIS>
                    <vCOFINS>0.00</vCOFINS><vOutro>0.00</vOutro>
                    <vNF>158.65</vNF><vTotTrib>50.21</vTotTrib>
                  </ICMSTot>
                </total>
              </infNFe>
            </NFe>
          </nfeProc>
        XML
      end

      # A resposta direta à pergunta do cliente.
      test "traz natureza da operação, CFOP e os impostos" do
        lido = Leitura.para(nfe)

        assert_equal "Venda de mercadorias Ecommerce", lido["natureza_operacao"]
        assert_equal [ "6108" ], lido["cfops"]
        assert_equal [ "64029990" ], lido["ncms"]
        assert_equal "1", lido["regime_tributario"]
        assert_equal "159.65", lido["valor_produtos"]
        assert_equal "158.65", lido["valor_nota"]
        assert_equal "1.00", lido["valor_desconto"]
        assert_equal "xml", lido["fonte"]
      end

      # A ARMADILHA. O XML tem `<CST>53</CST>` e `<CST>08</CST>`, e nenhum é do ICMS.
      # Varrer o documento por `<CST>` e gravar como CST do ICMS faria a apuração de um
      # cliente do Regime Normal classificar errado, em silêncio.
      test "o CST do ICMS não é o CST do IPI nem do PIS" do
        lido = Leitura.para(nfe)

        assert_nil lido["csts"], "nota do Simples não tem CST de ICMS"
        assert_equal [ "102" ], lido["csosns"]
        assert_equal [ "53" ], lido["csts_ipi"]
        assert_equal [ "08" ], lido["csts_pis"]
      end

      # E o Regime Normal, que é o cliente que vem: aí o CST do ICMS existe e tem que ser
      # lido — de dentro do bloco do ICMS.
      test "no Regime Normal o CST do ICMS é lido do bloco do ICMS" do
        xml = nfe.sub(
          "<ICMS><ICMSSN102><CSOSN>102</CSOSN></ICMSSN102></ICMS>",
          "<ICMS><ICMS00><CST>00</CST><vBC>100.00</vBC><vICMS>18.00</vICMS></ICMS00></ICMS>"
        )

        lido = Leitura.para(xml)

        assert_equal [ "00" ], lido["csts"]
        assert_nil lido["csosns"]
        # O do IPI continua separado, e não contamina.
        assert_equal [ "53" ], lido["csts_ipi"]
      end

      # `vTotTrib` NÃO é imposto pago. O nome carrega isso porque `valor_tributos`
      # convidaria alguém a somá-lo como carga tributária.
      test "o total aproximado de tributos tem nome que não engana" do
        lido = Leitura.para(nfe)

        assert_equal "50.21", lido["total_aproximado_de_tributos"]
        assert_nil lido["valor_tributos"]
      end

      # O ICMS-ST tem nome diferente no total (`vST`) e no item (`vICMSST`). A sonda mediu
      # `vICMSST` ausente e concluir dali que não há ST seria errado.
      test "o ICMS-ST é lido pelo nome que o total usa" do
        assert_equal "12.34", Leitura.para(nfe(st: "12.34"))["valor_icms_st"]
      end

      # Zero é resposta, e diferente de ausente: para emitente do Simples com CSOSN 102 o
      # ICMS zerado é a verdade, e apagá-lo faria a apuração perder a prova disso.
      test "imposto zerado é gravado como zero, não como ausente" do
        lido = Leitura.para(nfe)

        assert_equal "0.00", lido["valor_icms"]
        assert_equal "0.00", lido["valor_pis"]
        assert_equal "0.00", lido["valor_cofins"]
      end

      # DIFAL: a partilha do ICMS na venda interestadual a não contribuinte. Está no
      # `ICMSTot` do layout 4.00, e vem ausente nas notas do Simples — que é o certo, o
      # emitente não recolhe DIFAL como remetente.
      test "lê o DIFAL quando a nota o traz" do
        xml = nfe.sub("<vNF>158.65</vNF>",
                      "<vICMSUFDest>7.50</vICMSUFDest><vICMSUFRemet>1.20</vICMSUFRemet>" \
                      "<vFCPUFDest>0.80</vFCPUFDest><vNF>158.65</vNF>")

        lido = Leitura.para(xml)

        assert_equal "7.50", lido["valor_difal_destino"]
        assert_equal "1.20", lido["valor_difal_remetente"]
        assert_equal "0.80", lido["valor_fcp_destino"]
      end

      test "nota sem DIFAL não inventa o campo" do
        assert_nil Leitura.para(nfe)["valor_difal_destino"]
      end

      # CBS e IBS, os tributos da reforma. As notas do cliente estão no layout 4.00 e não
      # os trazem; o teste monta o grupo para que a leitura já esteja pronta — e para que
      # a falta, quando o emitente migrar, apareça como teste vermelho e não como zero
      # silencioso na tela.
      test "lê CBS e IBS do total da reforma" do
        xml = nfe.sub("</total>",
                      "<IBSCBSTot><vBCIBSCBS>159.65</vBCIBSCBS>" \
                      "<gIBS><gIBSTot><vIBS>14.37</vIBS></gIBSTot></gIBS>" \
                      "<gCBS><vCBS>1.44</vCBS></gCBS></IBSCBSTot></total>")

        lido = Leitura.para(xml)

        assert_equal "14.37", lido["valor_ibs"]
        assert_equal "1.44", lido["valor_cbs"]
      end

      # Lido de DENTRO do total: `vIBS` também aparece por item, e somar os dois contaria o
      # mesmo tributo duas vezes.
      test "o IBS do item não é confundido com o do total" do
        xml = nfe
          .sub("<IPI><IPINT><CST>53</CST></IPINT></IPI>",
               "<IPI><IPINT><CST>53</CST></IPINT></IPI><IBSCBS><gIBSCBS><vIBS>99.99</vIBS></gIBSCBS></IBSCBS>")
          .sub("</total>", "<IBSCBSTot><gIBS><vIBS>14.37</vIBS></gIBS></IBSCBSTot></total>")

        assert_equal "14.37", Leitura.para(xml)["valor_ibs"]
      end

      test "nota sem o grupo da reforma não inventa CBS nem IBS" do
        lido = Leitura.para(nfe)

        assert_nil lido["valor_ibs"]
        assert_nil lido["valor_cbs"]
      end

      test "guarda a chave da NF-e sem o prefixo" do
        assert_equal "35260912345678901234550010000123451234567890", Leitura.para(nfe)["chave"]
      end

      # Envelope de erro também começa com "<". Tratar qualquer coisa entre colchetes
      # angulares como documento fez um diagnóstico meu concluir que cinco canais não
      # traziam o número do pedido, quando o que voltou eram 208 bytes de recusa.
      test "o que não é NF-e é recusado" do
        recusa = <<~XML
          <?xml version="1.0"?><retorno><status>Erro</status>
          <erros><erro>Nota Fiscal não autorizada</erro></erros></retorno>
        XML

        assert_raises(Leitura::NaoEhNfe) { Leitura.para(recusa) }
        assert_raises(Leitura::NaoEhNfe) { Leitura.para("") }
        assert_raises(Leitura::NaoEhNfe) { Leitura.para("{\"erro\":\"nao encontrada\"}") }
      end

      # NF-e sem namespace, que é como parte dos XMLs chega. Um caminho só tem que valer
      # para as duas formas.
      test "lê NF-e sem namespace declarado" do
        assert_equal "6108", Leitura.para(nfe.sub(' xmlns="http://www.portalfiscal.inf.br/nfe"', ""))["cfops"].first
      end
    end
  end
end

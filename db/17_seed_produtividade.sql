-- ════════════════════════════════════════════════════════════════════════
-- 17_seed_produtividade.sql — Migra os campos da aba CAMPOS_PRODUTIVIDADE
-- (planilha) para o catálogo do painel, com escopo 'produtividade'.
--
-- Depois disso, o card "Produtividade" do Relatório lê do PAINEL (o código já
-- prefere o catálogo quando há itens de produtividade; a planilha vira fallback).
-- IDEMPOTENTE: remove os itens 'produtividade' atuais e regrava este seed —
-- pode rodar de novo sem duplicar. (Não mexe nos quesitos de operação.)
--
-- Depende de: 15_operacao_quesitos.sql. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

insert into public.operacao_quesitos (id, quesitos) values ('default','[]'::jsonb)
  on conflict (id) do nothing;

update public.operacao_quesitos
   set quesitos = (
         select coalesce(jsonb_agg(e), '[]'::jsonb)
           from jsonb_array_elements(quesitos) e
          where e->>'escopo' is distinct from 'produtividade'
       ) || $seed$[
  {
    "id": "prod-total-bo",
    "label": "Total BO",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-total-rat",
    "label": "Total RAT",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-total-bos",
    "label": "Total BOS",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-total-tco",
    "label": "Total TCO",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-cumprimento-de-mandado-de-prisao",
    "label": "Cumprimento de Mandado de Prisão",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-prisoes-pessoas-maiores",
    "label": "Prisões (Pessoas maiores)",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-apreensao-de-adolescentes",
    "label": "Apreensão de Adolescentes",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-drogas-apreendidas",
    "label": "Drogas Apreendidas",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-veiculos-fiscalizados",
    "label": "Veículos Fiscalizados",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-veiculos-apreendidos",
    "label": "Veiculos Apreendidos",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-pessoas-abordadas",
    "label": "Pessoas Abordadas",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-locais-fiscalizados",
    "label": "Locais Fiscalizados",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-locais-de-desmate-fiscalizados",
    "label": "Locais de Desmate Fiscalizados",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-animais-apreendidos",
    "label": "Animais Apreendidos",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-animais-recolhidos",
    "label": "Animais Recolhidos",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-visitas-tranquilizadores-realizadas",
    "label": "Visitas Tranquilizadores realizadas",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-operacoes-poe",
    "label": "Operações POE",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-rede-metros",
    "label": "Rede (metros)",
    "tipo": "decimal",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-tarrafa",
    "label": "Tarrafa",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-autuacao",
    "label": "Autuação",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-valores-de-autuacao",
    "label": "Valores de Autuação",
    "tipo": "moeda",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-prisao-em-virtude-de-cumprimento-de-mandado-de-p",
    "label": "Prisão em virtude de cumprimento de mandado de prisão MP",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-trafico-de-drogas-com-prisao-do-autor-td",
    "label": "Tráfico de drogas com prisão do autor TD",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-veiculos-recuperados-e-adulterados-com-prisao-do",
    "label": "Veículos recuperados e adulterados com prisão do autor VRAP",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-indicador-de-policiamento-rural-ipr-operacoes-gd",
    "label": "Indicador de policiamento rural IPR (Operações GDO Rural)",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-prisao-de-autor-de-crimes-ambientais-pac",
    "label": "Prisão de autor de crimes ambientais PAC",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-veiculos-apreendidos-em-crimes-e-infracoes-ambie",
    "label": "Veículos apreendidos em crimes e infrações ambientais VCA",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-ocorrencias-com-apreensao-de-animais-oaa",
    "label": "Ocorrências com Apreensão de Animais OAA",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-apreensao-de-materiais-em-crimes-e-infracoes-amb",
    "label": "Apreensão de materiais em crimes e infrações ambientais CAM",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  },
  {
    "id": "prod-armas-de-fogo-apreendidas-com-prisao-do-autor-af",
    "label": "Armas de Fogo Apreendidas com prisão do autor AFA",
    "tipo": "numero",
    "obrigatorio": false,
    "escopo": "produtividade",
    "operacoes": []
  }
]$seed$::jsonb,
       atualizado_em = now()
 where id = 'default';

-- ════════════════════════════════════════════════════════════════════════
-- FIM. 30 campos de produtividade (os "Ativo" da planilha). O "Veiculos
-- Recolhidos" (Inativo) ficou de fora — recadastre no Admin se precisar.
-- ════════════════════════════════════════════════════════════════════════

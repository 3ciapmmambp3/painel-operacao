-- db/123_lotacao_luciane_srai.sql
-- Ajusta a lotação da Funcionária Civil LUCIANE (Nº 167.424-1):
--   • grupamento_id = MESMO da Gilvana (para aparecer agrupada da mesma forma)
--   • funcao        = 'SRAI'
-- Rodar no Supabase SQL Editor. Idempotente (pode rodar mais de uma vez).

-- 1) Referência — confira a Gilvana antes:
select matricula, nome_completo, funcao, grupamento_id, cod_unidade, nome_unidade, cod_municipio
  from public.militares
 where nome_completo ilike 'GILVAN%';

-- 2) Aplica na Luciane (copia o grupamento_id da Gilvana; função = SRAI):
update public.militares l
   set grupamento_id = g.grupamento_id,
       funcao        = 'SRAI',
       updated_at    = now()
  from (
        select grupamento_id
          from public.militares
         where nome_completo ilike 'GILVAN%'
         order by nome_completo
         limit 1
       ) g
 where l.matricula_clean = '1674241';   -- 167.424-1

-- 3) Confira o resultado:
select matricula, nome_completo, funcao, grupamento_id, cod_unidade, nome_unidade
  from public.militares
 where matricula_clean = '1674241';

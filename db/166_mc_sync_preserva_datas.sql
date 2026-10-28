-- ══════════════════════════════════════════════════════════════════════
--  166 · MC — recarregar lote NÃO regrava a data das demandas que já existem
--
--  PROBLEMA: a mc_sync (db/157) resolvia, no ON CONFLICT:
--      data_gerada     = coalesce(excluded.data_gerada,     <existente>)
--      data_vencimento = coalesce(excluded.data_vencimento, <existente>)
--  Como o Apps Script (mcLote) manda SEMPRE data_gerada = HOJE e
--  data_vencimento = HOJE+45, o excluded nunca é nulo → ao recarregar uma
--  pasta antiga só para pegar algumas demandas NOVAS, TODAS as que já
--  estavam no painel tinham o prazo de 45 dias ZERADO para hoje.
--
--  SOLUÇÃO: inverter o coalesce dessas DUAS colunas (e só delas) — a data da
--  demanda que JÁ EXISTE é preservada; a demanda NOVA (insert) continua
--  recebendo a data que chega (hoje). Assim recarregar qualquer pasta passa
--  a ser seguro: entram só as novas, as antigas ficam intactas.
--
--  Nada mais muda: baixa/atendimento continua protegida, grupamento,
--  hectares, coords, KML, anexos etc. seguem iguais ao db/157.
--  MC-only (mc_sync só é usada pelo Monitoramento Contínuo). Idempotente.
--  Rodar uma vez no Supabase (SQL editor). Depende de db/157.
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.mc_sync(linhas jsonb)
returns table (inseridas int, atualizadas int, total int)
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  v_codigo text;
  v_muni   text;
  v_gp     text;
  v_gpc    text;
  v_exists boolean;
  v_ins int := 0;
  v_upd int := 0;
begin
  if linhas is null or jsonb_typeof(linhas) <> 'array' then
    raise exception 'mc_sync: esperado um array JSON';
  end if;

  for r in select * from jsonb_array_elements(linhas)
  loop
    v_codigo := nullif(trim(r->>'codigo'), '');
    if v_codigo is null then continue; end if;

    v_muni := upper(trim(coalesce(r->>'municipio','')));
    v_gp := null; v_gpc := null;
    if v_muni <> '' then
      select gp_responsavel, grupamento_completo into v_gp, v_gpc
        from public.vw_municipio_grupamento
        where translate(municipio_upper,'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','AAAAAEEEEIIIIOOOOOUUUUC')
            = translate(v_muni,       'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','AAAAAEEEEIIIIOOOOOUUUUC')
        limit 1;
    end if;

    select true into v_exists from public.mc_demandas where codigo = v_codigo;

    insert into public.mc_demandas (
      codigo, tipo_demanda, data_gerada, natureza, municipio, endereco,
      fracao_responsavel, gp_responsavel, grupamento_completo,
      data_envio, data_vencimento, status_prazo,
      data_atendimento, numero_gaia, numero_reds, resultado, status_atendimento,
      info_complementares, numero_auto_infracao, equipe, viatura,
      hectares, data_inic, data_final, mes_ref, ano_ref, coord_x, coord_y,
      regional, bioma, id_semad, id_evolucao, lote, kml_link, kml_content,
      anexos, fonte_aba, raw, synced_at, situacao
    ) values (
      v_codigo,
      coalesce(nullif(r->>'tipo_demanda',''),'MC'),
      nullif(r->>'data_gerada','')::date,
      nullif(r->>'natureza',''),
      nullif(r->>'municipio',''),
      nullif(r->>'endereco',''),
      nullif(r->>'fracao_responsavel',''),
      v_gp, coalesce(v_gpc, nullif(r->>'fracao_responsavel','')),
      nullif(r->>'data_envio','')::date,
      nullif(r->>'data_vencimento','')::date,
      nullif(r->>'status_prazo',''),
      nullif(r->>'data_atendimento','')::date,
      nullif(r->>'numero_gaia',''),
      nullif(r->>'numero_reds',''),
      nullif(r->>'resultado',''),
      nullif(r->>'status_atendimento',''),
      nullif(r->>'info_complementares',''),
      nullif(r->>'numero_auto_infracao',''),
      nullif(r->>'equipe',''),
      nullif(r->>'viatura',''),
      nullif(r->>'hectares','')::numeric,
      nullif(r->>'data_inic','')::date,
      nullif(r->>'data_final','')::date,
      nullif(r->>'mes_ref',''),
      nullif(r->>'ano_ref',''),
      nullif(r->>'coord_x',''),
      nullif(r->>'coord_y',''),
      nullif(r->>'regional',''),
      nullif(r->>'bioma',''),
      nullif(r->>'id_semad',''),
      nullif(r->>'id_evolucao',''),
      nullif(r->>'lote',''),
      nullif(r->>'kml_link',''),
      nullif(r->>'kml_content',''),
      coalesce(r->'anexos','[]'::jsonb),
      nullif(r->>'fonte_aba',''),
      coalesce(r->'raw','{}'::jsonb),
      now(),
      case when nullif(r->>'data_atendimento','') is not null then 'RESPONDIDA' else 'PENDENTE' end
    )
    on conflict (codigo) do update set
      tipo_demanda = coalesce(excluded.tipo_demanda, public.mc_demandas.tipo_demanda),
      -- ★ db/166: preserva a data da demanda que JÁ EXISTE (antes era excluded primeiro)
      data_gerada  = coalesce(public.mc_demandas.data_gerada,  excluded.data_gerada),
      natureza     = coalesce(excluded.natureza,     public.mc_demandas.natureza),
      municipio    = coalesce(excluded.municipio,    public.mc_demandas.municipio),
      endereco     = coalesce(excluded.endereco,     public.mc_demandas.endereco),
      fracao_responsavel  = coalesce(excluded.fracao_responsavel,  public.mc_demandas.fracao_responsavel),
      gp_responsavel      = coalesce(excluded.gp_responsavel,      public.mc_demandas.gp_responsavel),
      grupamento_completo = coalesce(excluded.grupamento_completo, public.mc_demandas.grupamento_completo),
      data_envio      = coalesce(excluded.data_envio,      public.mc_demandas.data_envio),
      -- ★ db/166: preserva o vencimento da demanda que JÁ EXISTE (não zera o prazo de 45d)
      data_vencimento = coalesce(public.mc_demandas.data_vencimento, excluded.data_vencimento),
      status_prazo    = coalesce(excluded.status_prazo,    public.mc_demandas.status_prazo),
      data_atendimento   = coalesce(public.mc_demandas.data_atendimento,   excluded.data_atendimento),
      numero_gaia        = coalesce(public.mc_demandas.numero_gaia,        excluded.numero_gaia),
      numero_reds        = coalesce(public.mc_demandas.numero_reds,        excluded.numero_reds),
      resultado          = coalesce(public.mc_demandas.resultado,          excluded.resultado),
      status_atendimento = coalesce(public.mc_demandas.status_atendimento, excluded.status_atendimento),
      info_complementares = coalesce(excluded.info_complementares, public.mc_demandas.info_complementares),
      numero_auto_infracao = coalesce(public.mc_demandas.numero_auto_infracao, excluded.numero_auto_infracao),
      equipe  = coalesce(public.mc_demandas.equipe,  excluded.equipe),
      viatura = coalesce(public.mc_demandas.viatura, excluded.viatura),
      hectares    = coalesce(excluded.hectares,    public.mc_demandas.hectares),
      data_inic   = coalesce(excluded.data_inic,   public.mc_demandas.data_inic),
      data_final  = coalesce(excluded.data_final,  public.mc_demandas.data_final),
      mes_ref     = coalesce(excluded.mes_ref,     public.mc_demandas.mes_ref),
      ano_ref     = coalesce(excluded.ano_ref,     public.mc_demandas.ano_ref),
      coord_x     = coalesce(excluded.coord_x,     public.mc_demandas.coord_x),
      coord_y     = coalesce(excluded.coord_y,     public.mc_demandas.coord_y),
      regional    = coalesce(excluded.regional,    public.mc_demandas.regional),
      bioma       = coalesce(excluded.bioma,       public.mc_demandas.bioma),
      id_semad    = coalesce(excluded.id_semad,    public.mc_demandas.id_semad),
      id_evolucao = coalesce(excluded.id_evolucao, public.mc_demandas.id_evolucao),
      lote        = coalesce(excluded.lote,        public.mc_demandas.lote),
      kml_link    = coalesce(excluded.kml_link,    public.mc_demandas.kml_link),
      kml_content = coalesce(excluded.kml_content, public.mc_demandas.kml_content),
      anexos = case when jsonb_array_length(coalesce(excluded.anexos,'[]'::jsonb)) > 0
                    then excluded.anexos else public.mc_demandas.anexos end,
      fonte_aba = coalesce(excluded.fonte_aba, public.mc_demandas.fonte_aba),
      raw       = excluded.raw,
      synced_at = now(),
      situacao = case
        when coalesce(public.mc_demandas.data_atendimento, excluded.data_atendimento) is not null
             and public.mc_demandas.situacao in ('PENDENTE','EM ANDAMENTO')
          then 'RESPONDIDA'
        else public.mc_demandas.situacao
      end;

    if coalesce(v_exists,false) then v_upd := v_upd + 1; else v_ins := v_ins + 1; end if;
    v_exists := null;
  end loop;

  return query select v_ins, v_upd, (v_ins + v_upd);
end;
$$;

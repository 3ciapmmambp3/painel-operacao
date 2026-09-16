-- ══════════════════════════════════════════════════════════════════════
--  81_mov_ficha_completa_escopo.sql — abrir a Ficha de Movimentação segue a
--  mesma visibilidade da lista / do Relatório de Serviço.
--
--  BUG: no painel (Minhas Movimentações) a lista é montada no navegador e já
--  mostrava as fichas da equipe/grupamento, mas ao clicar em "👁 Ver/Imprimir"
--  o RPC mov_ficha_completa (db/28) só liberava para GESTOR (Aux P4/Admin Geral)
--  ou o CRIADOR — então Admin GP / Admin Pelotão / comandante viam mas não
--  conseguiam abrir ("Sem permissão para ver esta ficha").
--
--  FIX: mov_ficha_completa passa a permitir VER quando:
--    • gestor de viaturas (Aux P4 / Admin Geral)            → qualquer
--    • Admin Geral / Admin / função "CMT CIA"               → qualquer
--    • Admin de Pelotão (admin_pelotao)                     → do seu PELOTÃO
--    • Admin de GP (admin_gp)                               → do seu GRUPAMENTO (GP+PEL)
--    • criador ou motorista da ficha                        → a própria
--    • comandante da equipe                                 → a ficha da equipe
--        que ele comandou: existe TTA do MESMO DIA em que ele é o responsável
--        e cuja viatura/motorista batem com a ficha.
--  (O GP/PEL da ficha vem do grupamento_completo, via regex, como no db/49.)
--  Idempotente. Rodar depois do 28.
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.mov_ficha_completa(p_token uuid, p_id uuid)
returns public.mov_viaturas
language plpgsql stable security definer set search_path = public as $$
declare
  v_me    record;
  v_row   public.mov_viaturas%rowtype;
  v_mat   text;
  v_nivel text;
  v_func  text;
  v_all   boolean;
  v_meu_pel text;
  v_meu_gp  text;
  v_f_gp    text;
  v_f_pel   text;
  v_fdata   date;
  v_fmot    text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  select * into v_row from public.mov_viaturas where id = p_id and ativo = true;
  if v_row.id is null then raise exception 'Ficha não encontrada.'; end if;

  v_mat   := regexp_replace(coalesce(v_me.matricula,''),'\D','','g');
  v_nivel := coalesce(v_me.nivel_acesso, '');
  v_func  := upper(btrim(coalesce(v_me.funcao, '')));
  -- "vê tudo": Admin Geral/Admin, CMT Cia, ou lotado na ADM (staff) — casa com o
  -- VE_TUDO da lista em minhas-movimentacoes.html.
  v_all   := v_nivel in ('admin_geral', 'admin')
          or v_func = 'CMT CIA'
          or upper(btrim(coalesce(v_me.grupamento_id,''))) like 'ADM%';
  v_meu_pel := (regexp_match(coalesce(v_me.grupamento_id, ''), '(\d+)\s*PEL', 'i'))[1];
  v_meu_gp  := (regexp_match(coalesce(v_me.grupamento_id, ''), '(\d+)\s*GP',  'i'))[1];
  v_f_gp    := (regexp_match(coalesce(v_row.grupamento_completo,''), '(\d+)\s*GP',  'i'))[1];
  v_f_pel   := (regexp_match(coalesce(v_row.grupamento_completo,''), '(\d+)\s*PEL', 'i'))[1];
  v_fdata   := (coalesce(v_row.inicio, v_row.criado_em) at time zone 'America/Sao_Paulo')::date;
  v_fmot    := regexp_replace(coalesce(v_row.motorista_matricula,''),'\D','','g');

  if not (
       public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao)
    or v_all
    or (v_nivel = 'admin_pelotao' and v_meu_pel is not null and v_f_pel = v_meu_pel)
    or (v_nivel = 'admin_gp' and v_meu_gp is not null and v_meu_pel is not null
        and v_f_gp = v_meu_gp and v_f_pel = v_meu_pel)
    or regexp_replace(coalesce(v_row.criado_por_matricula,''),'\D','','g') = v_mat
    or v_fmot = v_mat
    or exists (
         select 1 from public.tta_chamadas tc
          where (tc.data_hora_chamada at time zone 'America/Sao_Paulo')::date = v_fdata
            and regexp_replace(coalesce(tc.militar_resp_matricula,''),'\D','','g') = v_mat
            and (
                  ( v_fmot <> '' and v_fmot in (
                      select regexp_replace(coalesce(e->>'matricula',''),'\D','','g')
                        from jsonb_array_elements(coalesce(tc.militares_presentes,'[]'::jsonb)) e ) )
               or ( trim(coalesce(v_row.prefixo,'')) <> '' and trim(coalesce(v_row.prefixo,'')) in (
                      select trim(coalesce(cv->>'prefixo',''))
                        from jsonb_array_elements(coalesce(tc.viaturas,'[]'::jsonb)) cv ) )
               or ( trim(coalesce(v_row.prefixo,'')) <> '' and trim(coalesce(v_row.prefixo,'')) = trim(coalesce(tc.prefixo_viatura,'')) )
            )
       )
  ) then
    raise exception 'Sem permissão para ver esta ficha.';
  end if;

  return v_row;
end;
$$;

grant execute on function public.mov_ficha_completa(uuid, uuid) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 28.
-- ══════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════
--  79_relatorio_meus_sou_eu.sql — flag "sou_eu" na lista de relatórios
--
--  A tela Meus Relatórios vai ganhar as abas (chips) "Minhas + equipe / Só as
--  minhas / Da equipe / Todas (gestão)", igual às Minhas Movimentações. Para
--  isso o cliente precisa saber, de cada relatório, se o MILITAR LOGADO aparece
--  nele (comandante / motorista / patrulheiros).
--
--  Aqui recriamos relatorio_meus (db/49) acrescentando o campo booleano
--  'sou_eu'. O escopo de visibilidade é EXATAMENTE o mesmo do db/49 — nada
--  muda em quem vê o quê. Idempotente. Rodar depois do 49.
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.relatorio_meus(p_token uuid, p_todos boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_me      record;
  v_nivel   text;
  v_func    text;
  v_all     boolean;
  v_meu_pel text;
  v_meu_gp  text;
  v_hoje    date := current_date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;

  v_nivel := coalesce(v_me.nivel_acesso, '');
  v_func  := upper(btrim(coalesce(v_me.funcao, '')));

  v_all := v_nivel in ('admin_geral', 'admin') or v_func = 'CMT CIA';

  v_meu_pel := (regexp_match(coalesce(v_me.grupamento_id, ''), '(\d+)\s*PEL', 'i'))[1];
  v_meu_gp  := (regexp_match(coalesce(v_me.grupamento_id, ''), '(\d+)\s*GP',  'i'))[1];

  return coalesce((
    select jsonb_agg(x order by x->>'Data' desc) from (
      select jsonb_build_object(
        'ID Relatório', r.id,
        'sheet_id', r.sheet_id,
        'Fração de Atuação', r.fracao_atuacao,
        'Data', to_char(r.data, 'YYYY-MM-DD'),
        'Início do Turno', r.inicio_turno,
        'Fim do Turno', r.fim_turno,
        'Equipe', r.equipe,
        'Tipo de Serviço', r.tipo_servico,
        -- Sou eu? apareço na equipe deste relatório (comandante/motorista/patrulheiros).
        'sou_eu', (
              position(v_me.matricula in coalesce(r.comandante, ''))    > 0
           or position(v_me.matricula in coalesce(r.motorista, ''))     > 0
           or position(v_me.matricula in coalesce(r.patrulheiros, ''))  > 0
        ),
        'podeEditar', (
          v_nivel = 'admin_geral'
          or (
            r.data is not null and (v_hoje - r.data) <= 2
            and (
              position(v_me.matricula in coalesce(r.comandante, ''))   > 0
              or position(v_me.matricula in coalesce(r.motorista, ''))  > 0
              or position(v_me.matricula in coalesce(r.patrulheiros, '')) > 0
            )
          )
        )
      ) as x
      from public.relatorios r
      where r.ativo = true
        and (
          v_all
          or (v_nivel = 'admin_pelotao' and v_meu_pel is not null
              and (regexp_match(coalesce(r.fracao_atuacao, ''), '(\d+)\s*PEL', 'i'))[1] = v_meu_pel)
          or (v_nivel = 'admin_gp' and v_meu_gp is not null and v_meu_pel is not null
              and (regexp_match(coalesce(r.fracao_atuacao, ''), '(\d+)\s*GP',  'i'))[1] = v_meu_gp
              and (regexp_match(coalesce(r.fracao_atuacao, ''), '(\d+)\s*PEL', 'i'))[1] = v_meu_pel)
          or position(v_me.matricula in coalesce(r.comandante, ''))   > 0
          or position(v_me.matricula in coalesce(r.motorista, ''))    > 0
          or position(v_me.matricula in coalesce(r.patrulheiros, '')) > 0
        )
    ) t
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.relatorio_meus(uuid, boolean) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 49.
-- ══════════════════════════════════════════════════════════════════════

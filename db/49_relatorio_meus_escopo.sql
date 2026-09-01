-- ══════════════════════════════════════════════════════════════════════
--  LISTA DE RELATÓRIOS — visibilidade por perfil/função
--  Rodar no Supabase (SQL Editor). Idempotente (create or replace).
--
--  Substitui o escopo antigo de relatorio_meus (só Admin Geral via p_todos
--  via todos; o resto só os próprios) pelo escopo pedido:
--    • Admin Geral / Admin / função "CMT CIA"  → TODA a Companhia
--    • Admin de Pelotão (admin_pelotao)         → todos do seu PELOTÃO
--    • Admin de GP (admin_gp)                   → todos do seu GRUPAMENTO (GP+PEL)
--    • Qualquer perfil                          → sempre os relatórios em que aparece
--
--  Mesmo modelo de escopo já usado no relatorio-servico.html (pel/gp
--  extraídos da fração). A ampliação é só para Ver/Imprimir — o direito de
--  EDITAR continua restrito ao Admin Geral ou ao próprio militar (≤2 dias).
--
--  O escopo é resolvido DENTRO do banco a partir do token (nível, função e
--  grupamento do militar), nunca do que o navegador informar. p_todos é
--  mantido na assinatura só para compatibilidade com o cliente atual.
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

  -- Vê TODA a Companhia: Admin Geral, Admin, ou função CMT CIA.
  v_all := v_nivel in ('admin_geral', 'admin') or v_func = 'CMT CIA';

  -- Pelotão e GP (grupo) do próprio militar, extraídos do grupamento_id.
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
        -- Editar continua restrito: Admin Geral, ou o próprio militar dentro
        -- de 2 dias. A visibilidade ampliada abaixo é só Ver/Imprimir.
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
          -- Admin de Pelotão: todos os relatórios do seu Pelotão.
          or (v_nivel = 'admin_pelotao' and v_meu_pel is not null
              and (regexp_match(coalesce(r.fracao_atuacao, ''), '(\d+)\s*PEL', 'i'))[1] = v_meu_pel)
          -- Admin de GP: todos os relatórios do seu grupamento (GP + Pelotão).
          or (v_nivel = 'admin_gp' and v_meu_gp is not null and v_meu_pel is not null
              and (regexp_match(coalesce(r.fracao_atuacao, ''), '(\d+)\s*GP',  'i'))[1] = v_meu_gp
              and (regexp_match(coalesce(r.fracao_atuacao, ''), '(\d+)\s*PEL', 'i'))[1] = v_meu_pel)
          -- Qualquer perfil: sempre vê os relatórios em que aparece.
          or position(v_me.matricula in coalesce(r.comandante, ''))   > 0
          or position(v_me.matricula in coalesce(r.motorista, ''))    > 0
          or position(v_me.matricula in coalesce(r.patrulheiros, '')) > 0
        )
    ) t
  ), '[]'::jsonb);
end;
$$;

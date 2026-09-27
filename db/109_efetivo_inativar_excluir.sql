-- ══════════════════════════════════════════════════════════════════════
--  EFETIVO — inativar (transferido/reserva, mantém login) x excluir (apaga)
--  Distinção:
--   • INATIVAR (Transferido de unidade / Transferido para a Reserva / Outro):
--       ativo = FALSE e situacao_efetivo <> 'ATIVO' → MANTÉM os dados, mas o
--       militar PERDE o acesso ao painel (login) e sai do efetivo. É
--       REATIVÁVEL (usado inclusive na reconvocação da reserva).
--   • EXCLUIR definitivo: apaga o registro (cadastro errado/duplicado).
--
--  "Integrante ativo da Cia" = ativo = true E situacao_efetivo='ATIVO'.
--  Reativar volta ativo=true e situacao_efetivo='ATIVO'.
--
--  Depende de: 102, 105, 107. Idempotente. Rodar depois do 108.
-- ══════════════════════════════════════════════════════════════════════

-- 1) INATIVAR (mantém ativo=true; só muda a situação no efetivo) ─────────
create or replace function public.efetivo_baixar(p_token uuid, p_id uuid, p_dados jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record; v_sit text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Ação restrita ao Aux P1 / Comando.';
  end if;
  v_sit := upper(coalesce(nullif(p_dados->>'situacao_efetivo',''),'TRANSFERIDO'));
  if v_sit = 'ATIVO' then v_sit := 'TRANSFERIDO'; end if;

  update public.militares set
    ativo                  = false,   -- perde o acesso ao painel (reativável na reconvocação)
    situacao_efetivo       = v_sit,
    transf_destino         = nullif(p_dados->>'transf_destino',''),
    transf_pasta_funcional = case when p_dados ? 'transf_pasta_funcional' then (p_dados->>'transf_pasta_funcional')::boolean else transf_pasta_funcional end,
    transf_data_envio      = nullif(p_dados->>'transf_data_envio','')::date,
    transf_oficio_numero   = nullif(p_dados->>'transf_oficio_numero',''),
    transf_obs             = nullif(p_dados->>'transf_obs',''),
    transf_anexo           = coalesce(p_dados->'transf_anexo', transf_anexo, '[]'::jsonb)
  where id = p_id;
  if not found then raise exception 'Militar não encontrado.'; end if;
end;
$$;

-- 2) REATIVAR (volta a integrar a Cia) ──────────────────────────────────
create or replace function public.efetivo_reativar(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Restrito ao Aux P1 / Comando.';
  end if;
  update public.militares set ativo = true, situacao_efetivo = 'ATIVO' where id = p_id;
  if not found then raise exception 'Militar não encontrado.'; end if;
end;
$$;

-- 3) EXCLUIR DEFINITIVO (apaga o registro) ──────────────────────────────
create or replace function public.efetivo_excluir(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record; v_alvo public.militares;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Exclusão restrita ao Aux P1 / Comando.';
  end if;
  if v_me.id = p_id then raise exception 'Você não pode excluir a sua própria conta.'; end if;
  select * into v_alvo from public.militares where id = p_id;
  if v_alvo.id is null then raise exception 'Militar não encontrado.'; end if;
  if coalesce(v_alvo.nivel_acesso,'') = 'admin_geral' then
    raise exception 'Não é possível excluir um Admin Geral por aqui.';
  end if;
  delete from public.militares where id = p_id;   -- sessoes cascata (db/04)
end;
$$;

-- 4) LISTAR — "ativo na Cia" = ativo=true E situacao_efetivo='ATIVO' ─────
create or replace function public.efetivo_listar(p_token uuid, p_incluir_inativos boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_out jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Acesso ao efetivo restrito ao Aux P1 / Comando.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(t) order by t.ord_antig, t.rank_posto, t.ultima_promocao nulls last, t.matricula_clean), '[]'::jsonb)
    into v_out
  from (
    select m.id, m.matricula, m.matricula_clean, m.posto_graduacao, m.nome_completo,
           m.nome_guerra, m.funcao, m.email, m.ativo, m.nivel_acesso, m.grupamento_id,
           m.cod_rpm, m.nome_rpm, m.cod_unidade_principal, m.nome_unidade_principal,
           m.cod_unidade, m.nome_unidade, m.cod_siad, m.tipo_atividade, m.cod_municipio,
           m.ultima_promocao, m.classificacao_curso, m.antiguidade_ordem,
           m.rg, m.cpf, m.titulo_eleitor, m.cnh_numero, m.cnh_categoria, m.cnh_validade,
           m.data_nascimento, m.telefone_funcional, m.telefone_pessoal1, m.telefone_pessoal2,
           m.endereco_funcional, m.endereco_residencial1, m.endereco_residencial2,
           m.email_pessoal, m.email_funcional, m.sexo,
           coalesce(m.situacao_efetivo,'ATIVO') as situacao_efetivo,
           (m.ativo and coalesce(m.situacao_efetivo,'ATIVO')='ATIVO') as integrante_ativo,
           m.transf_destino, m.transf_pasta_funcional, m.transf_data_envio,
           m.transf_oficio_numero, m.transf_obs, m.transf_anexo,
           coalesce(m.antiguidade_ordem, 999999) as ord_antig,
           public._posto_rank(m.posto_graduacao) as rank_posto
      from public.militares m
     where m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and (p_incluir_inativos or (m.ativo and coalesce(m.situacao_efetivo,'ATIVO')='ATIVO'))
  ) t;

  return v_out;
end;
$$;

-- 5) PERCENTUAL — conta só integrante ativo (exclui transferido/reserva) ─
create or replace function public.ferias_percentuais(p_token uuid, p_ano int default null, p_data date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me record;
  v_ano int := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_dia date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
  v_out jsonb; v_crono public.ferias_cronograma;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Painel de percentuais restrito ao Aux P1 / Comando.';
  end if;
  select * into v_crono from public.ferias_cronograma where ano = v_ano;

  with efetivo as (
    select m.id, m.grupamento_id, public._ferias_pelotao(m.grupamento_id) as pelotao
      from public.militares m
     where m.ativo = true
       and coalesce(m.situacao_efetivo,'ATIVO') = 'ATIVO'
       and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and upper(coalesce(m.funcao,'')) not like '%ASPM%'
       and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
  ),
  em_ferias as (
    select distinct p.militar_id, p.pelotao, p.grupamento_id
      from public.ferias_pedidos p
      join efetivo e on e.id = p.militar_id
      cross join lateral jsonb_array_elements(p.parcelas) parc
     where p.ano = v_ano and p.situacao = 'VALIDADO'
       and nullif(parc->>'ini','')::date <= v_dia and nullif(parc->>'fim','')::date >= v_dia
  ),
  cia as ( select (select count(*) from efetivo) as total, (select count(*) from em_ferias) as ferias ),
  por_pel as (
    select e.pelotao, count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.pelotao is not distinct from e.pelotao) as ferias
      from efetivo e group by e.pelotao ),
  por_gp as (
    select e.grupamento_id, count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.grupamento_id is not distinct from e.grupamento_id) as ferias
      from efetivo e group by e.grupamento_id )
  select jsonb_build_object(
    'ano', v_ano, 'data', v_dia,
    'limites', jsonb_build_object('cia', v_crono.pct_max_cia, 'pelotao', v_crono.pct_max_pelotao, 'grupamento', v_crono.pct_max_grupamento),
    'cia', (select jsonb_build_object('total', total, 'ferias', ferias, 'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end) from cia),
    'pelotoes', coalesce((select jsonb_agg(jsonb_build_object('pelotao', coalesce(pelotao,'(sem pelotão)'), 'total', total, 'ferias', ferias, 'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end) order by pelotao) from por_pel), '[]'::jsonb),
    'grupamentos', coalesce((select jsonb_agg(jsonb_build_object('grupamento', coalesce(grupamento_id,'(sem GP)'), 'total', total, 'ferias', ferias, 'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end) order by grupamento_id) from por_gp), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;

grant execute on function public.efetivo_baixar(uuid, uuid, jsonb)   to anon;
grant execute on function public.efetivo_reativar(uuid, uuid)        to anon;
grant execute on function public.efetivo_excluir(uuid, uuid)         to anon;
grant execute on function public.efetivo_listar(uuid, boolean)       to anon;
grant execute on function public.ferias_percentuais(uuid, int, date) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do 108.
-- ══════════════════════════════════════════════════════════════════════

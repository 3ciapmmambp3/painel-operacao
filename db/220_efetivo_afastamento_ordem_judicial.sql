-- ══════════════════════════════════════════════════════════════════════
--  220 · Efetivo — modalidade "Afastado por ordem judicial (sem acesso)"
--
--  Igual ao HIPOTECADO (continua contando no RH, mas sem acesso ao painel),
--  só muda o MOTIVO. Guardamos o motivo em militares.afastamento_motivo
--  (null = hipoteca comum | 'ORDEM_JUDICIAL' = afastado por ordem judicial).
--  Assim toda a lógica de contagem/acesso (situacao_efetivo='HIPOTECADO')
--  segue idêntica — o front só muda o RÓTULO pelo motivo.
--
--  Idempotente. Rodar no Supabase (SQL editor). Depende de db/126, db/176.
-- ══════════════════════════════════════════════════════════════════════

alter table public.militares
  add column if not exists afastamento_motivo text;

-- ─── efetivo_hipotecar: aceita o motivo (ordem judicial sempre suspende) ──
drop function if exists public.efetivo_hipotecar(uuid, uuid, boolean);
create or replace function public.efetivo_hipotecar(
  p_token uuid, p_id uuid,
  p_suspender_acesso boolean default false,
  p_motivo text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Restrito ao Aux P1 / Comando.';
  end if;
  update public.militares set
    situacao_efetivo   = 'HIPOTECADO',
    ativo              = not coalesce(p_suspender_acesso, false),
    afastamento_motivo = nullif(btrim(coalesce(p_motivo,'')), '')
  where id = p_id;
  if not found then raise exception 'Militar não encontrado.'; end if;
end;
$$;
grant execute on function public.efetivo_hipotecar(uuid, uuid, boolean, text) to anon;

-- ─── efetivo_listar: passa a devolver afastamento_motivo (db/176 + coluna) ─
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
           m.nome_mae, m.nome_pai, m.data_ingresso, m.rg_orgao_expedidor, m.rg_orgao_uf, m.rg_emissao,
           m.end_res_logradouro, m.end_res_numero, m.end_res_complemento,
           m.end_res_bairro, m.end_res_cidade, m.end_res_cep,
           m.dados_confirmados_em, m.dados_confirmados_campanha, m.categoria,
           coalesce(m.situacao_efetivo,'ATIVO') as situacao_efetivo,
           nullif(btrim(coalesce(m.afastamento_motivo,'')),'') as afastamento_motivo,
           m.transf_destino, m.transf_pasta_funcional, m.transf_data_envio,
           m.transf_oficio_numero, m.transf_obs, m.transf_anexo,
           coalesce(m.antiguidade_ordem, 999999) as ord_antig,
           public._posto_rank(m.posto_graduacao) as rank_posto
      from public.militares m
     where m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and (p_incluir_inativos or m.ativo = true)
  ) t;

  return v_out;
end;
$$;

notify pgrst, 'reload schema';

-- ══════════════════════════════════════════════════════════════════════
--  222 · Efetivo — ACESSO separado de ATIVIDADE (ordem judicial)
--
--  CORREÇÃO do db/220: o afastado por ordem judicial NÃO é hipotecado e
--  NÃO sai do efetivo ativo. "Ativo" = está em ATIVIDADE (não = tem login).
--  Ele deve constar na aba Efetivo ATIVO (ativo=true, conta normal), porém
--  SEM acesso ao painel.
--
--  Novo campo militares.acesso_suspenso: bloqueia o LOGIN sem mexer no
--  ativo. auth_login e _sessao_militar passam a recusá-lo (qualquer sessão
--  aberta cai na hora). efetivo_afastar_judicial liga/desliga isso mantendo
--  situacao_efetivo='ATIVO' e ativo=true. (Hipotecado segue como estava.)
--  Idempotente. Rodar no Supabase. Depende de db/04, db/176, db/220.
-- ══════════════════════════════════════════════════════════════════════

alter table public.militares
  add column if not exists acesso_suspenso boolean not null default false;

-- ─── sessão: suspenso não tem sessão válida (cai na hora) ──────────────
create or replace function public._sessao_militar(p_token uuid)
returns table (id uuid, matricula text, matricula_clean text, nome_completo text,
               nome_guerra text, posto_graduacao text, nivel_acesso text,
               funcao text, grupamento_id text)
language sql security definer set search_path = public as $$
  select m.id, m.matricula, m.matricula_clean, m.nome_completo, m.nome_guerra,
         m.posto_graduacao, m.nivel_acesso, m.funcao, m.grupamento_id
  from public.sessoes s
  join public.militares m on m.id = s.militar_id
  where s.token = p_token and s.expira_em > now()
    and m.ativo = true
    and coalesce(m.acesso_suspenso, false) = false;
$$;

-- ─── login: recusa com mensagem clara quando suspenso ─────────────────
create or replace function public.auth_login(p_matricula text, p_senha text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_clean text := regexp_replace(coalesce(p_matricula,''), '\D', '', 'g');
  v_row   public.militares;
  v_ok    boolean := false;
  v_token uuid;
begin
  perform public._sessoes_limpar_expiradas();

  select * into v_row from public.militares
    where matricula_clean = lpad(v_clean, 7, '0') and ativo = true
    limit 1;
  if v_row.id is null then
    return jsonb_build_object('ok', false, 'erro', 'Usuário não encontrado ou inativo.');
  end if;

  if coalesce(v_row.acesso_suspenso, false) then
    return jsonb_build_object('ok', false, 'erro', 'Acesso suspenso por ordem judicial. Procure o Aux P1 / Comando.');
  end if;

  if left(v_row.senha_hash, 4) in ('$2a$', '$2b$', '$2y$') then
    v_ok := (crypt(p_senha, v_row.senha_hash) = v_row.senha_hash);
  else
    v_ok := (v_row.senha_hash = encode(digest(p_senha, 'sha256'), 'hex'));
    if v_ok then
      update public.militares set senha_hash = crypt(p_senha, gen_salt('bf')) where id = v_row.id;
    end if;
  end if;

  if not v_ok then
    return jsonb_build_object('ok', false, 'erro', 'Senha incorreta.');
  end if;

  insert into public.sessoes (militar_id) values (v_row.id) returning token into v_token;

  return jsonb_build_object('ok', true, 'primeiroAcesso', v_row.primeiro_acesso,
    'user', jsonb_build_object(
      'id', v_row.id, 'token', v_token, 'matricula', v_row.matricula,
      'matricula_clean', v_row.matricula_clean, 'nome', v_row.nome_completo,
      'guerra', v_row.nome_guerra, 'pg', v_row.posto_graduacao,
      'nivel_acesso', v_row.nivel_acesso, 'funcao', v_row.funcao,
      'grupamento_id', v_row.grupamento_id, 'primeiro_acesso', v_row.primeiro_acesso
    ));
end;
$$;

-- ─── afastar / reativar por ordem judicial (mantém ATIVO) ─────────────
create or replace function public.efetivo_afastar_judicial(p_token uuid, p_id uuid, p_afastar boolean default true)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Restrito ao Aux P1 / Comando.';
  end if;
  if coalesce(p_afastar, true) then
    update public.militares set
      situacao_efetivo   = 'ATIVO',       -- em atividade: fica na aba Efetivo ativo
      ativo              = true,           -- conta normalmente no efetivo
      acesso_suspenso    = true,           -- porém SEM login no painel
      afastamento_motivo = 'ORDEM_JUDICIAL'
    where id = p_id;
  else
    update public.militares set
      acesso_suspenso    = false,          -- reativa o acesso (ordem cessada)
      afastamento_motivo = null
    where id = p_id;
  end if;
  if not found then raise exception 'Militar não encontrado.'; end if;
end;
$$;
grant execute on function public.efetivo_afastar_judicial(uuid, uuid, boolean) to anon;

-- ─── efetivo_listar: passa a devolver acesso_suspenso (db/220 + coluna) ─
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
           coalesce(m.acesso_suspenso,false) as acesso_suspenso,
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

-- ══════════════════════════════════════════════════════════════════════
--  ESCRITA CONTROLADA EM DENUNCIAS — 3ª Cia PM MAmb
--  Rodar DEPOIS de 04_sessoes_e_militares_seguranca.sql (usa
--  public._sessao_militar e public._nivel_num de lá). Idempotente.
--
--  Problema que resolve: a policy denuncias_update_anon (01_denuncias.sql)
--  é "using(true) with check(true))" — qualquer PATCH autenticado só com a
--  chave anon (pública) altera QUALQUER campo de QUALQUER denúncia, sem
--  precisar estar logado no painel. As restrições de denuncias.html
--  (só Admin Geral inativa/reativa/dá baixa manual) são só da interface.
--
--  Como resolve: fecha a policy de UPDATE e substitui as 4 escritas que
--  o app realmente faz (assumir, inativar, reativar, registrar
--  atendimento — inclui a baixa automática do relatório de serviço) por
--  funções "security definer" que resolvem quem está chamando pelo
--  token de sessão, exatamente como já é feito em criar_denuncia.
--
--  Decisão deliberada: a função de "assumir" só exige estar logado (não
--  reproduz a regra fina de escopo por grupamento/pelotão) — evita
--  reimplementar aquele regex dentro do SQL e arriscar travar um militar
--  em campo por um caso de borda. O buraco real de hoje (dá pra fazer
--  isso SEM login nenhum) já fica fechado assim.
-- ══════════════════════════════════════════════════════════════════════

drop policy if exists denuncias_update_anon on public.denuncias;
-- (a policy de SELECT continua igual — leitura por escopo já é decidida
-- no app, como já documentado em 01_denuncias.sql; aqui fechamos a escrita)

/* ── Assumir (PENDENTE → EM ANDAMENTO) — qualquer militar logado ────── */
create or replace function public.denuncia_assumir(p_token uuid, p_id uuid)
returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.denuncias;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;

  update public.denuncias set
    situacao = 'EM ANDAMENTO',
    atendido_por_matricula = v_me.matricula,
    atendido_por_nome = trim(both ' ' from
      concat(v_me.matricula, ' — ', coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo)))
  where id = p_id and situacao = 'PENDENTE' and ativo = true
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Registro não encontrado ou não está mais pendente.';
  end if;
  return v_row;
end;
$$;

/* ── Inativar / Reativar — só Admin Geral (regra já era só de UI) ───── */
create or replace function public.denuncia_inativar(p_token uuid, p_id uuid, p_motivo text)
returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.denuncias;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if v_me.nivel_acesso <> 'admin_geral' then
    raise exception 'Inativação restrita ao Admin Geral.';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Informe o motivo da inativação.';
  end if;

  update public.denuncias set
    ativo = false,
    situacao_anterior = case when situacao <> 'INATIVADA' then situacao else situacao_anterior end,
    situacao = 'INATIVADA',
    motivo_inativacao = upper(trim(p_motivo)),
    inativado_por_matricula = v_me.matricula,
    inativado_por_nome = trim(both ' ' from
      concat(v_me.matricula, ' — ', coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo))),
    inativado_em = now()
  where id = p_id
  returning * into v_row;

  if v_row.id is null then raise exception 'Registro não encontrado.'; end if;
  return v_row;
end;
$$;

create or replace function public.denuncia_reativar(p_token uuid, p_id uuid)
returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.denuncias;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if v_me.nivel_acesso <> 'admin_geral' then
    raise exception 'Reativação restrita ao Admin Geral.';
  end if;

  update public.denuncias set
    ativo = true,
    situacao = coalesce(situacao_anterior, 'PENDENTE'),
    situacao_anterior = null,
    motivo_inativacao = null,
    inativado_por_matricula = null, inativado_por_nome = null, inativado_em = null
  where id = p_id
  returning * into v_row;

  if v_row.id is null then raise exception 'Registro não encontrado.'; end if;
  return v_row;
end;
$$;

/* ── Registrar atendimento (baixa manual) — só Admin Geral ──────────── */
create or replace function public.denuncia_registrar_atendimento(
  p_token uuid, p_id uuid, p_data date, p_reds text,
  p_auto_infracao text, p_ato_fiscalizacao text, p_obs text
) returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.denuncias;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if v_me.nivel_acesso <> 'admin_geral' then
    raise exception 'Baixa manual restrita ao Admin Geral. Use o relatório de serviço.';
  end if;
  if p_data is null then raise exception 'Informe a data do atendimento.'; end if;
  if coalesce(trim(p_reds), '') = '' then raise exception 'Informe o Nº REDS.'; end if;

  update public.denuncias set
    situacao = 'RESPONDIDA',
    data_resposta = p_data,
    numero_reds = p_reds,
    numero_auto_infracao = nullif(p_auto_infracao, ''),
    numero_ato_fiscalizacao = nullif(p_ato_fiscalizacao, ''),
    observacoes_resposta = nullif(p_obs, ''),
    atendido_por_matricula = v_me.matricula,
    atendido_por_nome = trim(both ' ' from
      concat(v_me.matricula, ' — ', coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo)))
  where id = p_id
  returning * into v_row;

  if v_row.id is null then raise exception 'Registro não encontrado.'; end if;
  return v_row;
end;
$$;

/* ── Baixa automática (relatório de serviço) — qualquer militar logado,
   casa por número+tipo em vez de id. Mantém o comportamento atual
   (não restrito por grupamento), só passa a exigir sessão válida. ───── */
create or replace function public.denuncia_baixa_automatica(
  p_token uuid, p_numero text, p_tipo text, p_data date, p_reds text,
  p_auto_infracao text, p_ato_fiscalizacao text, p_obs text
) returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.denuncias;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_tipo not in ('denuncia','requisicao') then raise exception 'Tipo inválido: %', p_tipo; end if;

  update public.denuncias set
    situacao = 'RESPONDIDA',
    data_resposta = coalesce(p_data, data_resposta),
    numero_reds = coalesce(nullif(p_reds,''), numero_reds),
    numero_auto_infracao = coalesce(nullif(p_auto_infracao,''), numero_auto_infracao),
    numero_ato_fiscalizacao = coalesce(nullif(p_ato_fiscalizacao,''), numero_ato_fiscalizacao),
    observacoes_resposta = coalesce(nullif(p_obs,''), observacoes_resposta),
    atendido_por_matricula = v_me.matricula,
    atendido_por_nome = trim(both ' ' from
      concat(v_me.matricula, ' — ', coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo)))
  where numero = p_numero and tipo = p_tipo
  returning * into v_row;

  return v_row; -- pode ser NULL se não encontrar (mesmo comportamento de hoje: falha silenciosa)
end;
$$;

grant execute on function public.denuncia_assumir(uuid, uuid) to anon;
grant execute on function public.denuncia_inativar(uuid, uuid, text) to anon;
grant execute on function public.denuncia_reativar(uuid, uuid) to anon;
grant execute on function public.denuncia_registrar_atendimento(uuid, uuid, date, text, text, text, text) to anon;
grant execute on function public.denuncia_baixa_automatica(uuid, text, text, date, text, text, text, text) to anon;

-- ─── DESFAZER (só se precisar reverter às pressas) ─────────────────────
-- drop function if exists public.denuncia_assumir(uuid,uuid);
-- drop function if exists public.denuncia_inativar(uuid,uuid,text);
-- drop function if exists public.denuncia_reativar(uuid,uuid);
-- drop function if exists public.denuncia_registrar_atendimento(uuid,uuid,date,text,text,text,text);
-- drop function if exists public.denuncia_baixa_automatica(uuid,text,text,date,text,text,text,text);
-- create policy denuncias_update_anon on public.denuncias for update to anon using (true) with check (true);

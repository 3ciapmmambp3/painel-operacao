-- ══════════════════════════════════════════════════════════════════════
--  CORREÇÕES DO ADMIN GERAL EM DENUNCIAS — 3ª Cia PM MAmb
--  Rodar DEPOIS de 04_sessoes_e_militares_seguranca.sql e
--  05_denuncias_seguranca.sql (usa public._sessao_militar de lá e a view
--  public.vw_municipio_grupamento de 00_grupamentos_view.sql). Idempotente.
--
--  Duas funções novas, ambas restritas a Admin Geral:
--  1. denuncia_voltar_pendente — desfaz um "Assumir" feito por engano
--     (EM ANDAMENTO → PENDENTE de novo).
--  2. denuncia_editar_municipio — corrige o município quando a denúncia
--     foi encaminhada ao grupamento errado; re-deriva gp_responsavel e
--     grupamento_completo a partir da view, igual ao criar_denuncia faz
--     na criação (01_denuncias.sql).
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.denuncia_voltar_pendente(p_token uuid, p_id uuid)
returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.denuncias;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if v_me.nivel_acesso <> 'admin_geral' then
    raise exception 'Reverter para pendente restrito ao Admin Geral.';
  end if;

  update public.denuncias set
    situacao = 'PENDENTE',
    atendido_por_matricula = null,
    atendido_por_nome = null
  where id = p_id and situacao = 'EM ANDAMENTO' and ativo = true
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Registro não encontrado ou não está mais em andamento.';
  end if;
  return v_row;
end;
$$;

create or replace function public.denuncia_editar_municipio(p_token uuid, p_id uuid, p_municipio text)
returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare
  v_me record;
  v_row public.denuncias;
  v_muni text := upper(trim(p_municipio));
  v_gp text;
  v_gp_completo text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if v_me.nivel_acesso <> 'admin_geral' then
    raise exception 'Edição restrita ao Admin Geral.';
  end if;
  if coalesce(v_muni, '') = '' then
    raise exception 'Informe o município.';
  end if;

  select gp_responsavel, grupamento_completo into v_gp, v_gp_completo
    from public.vw_municipio_grupamento
    where municipio_upper = v_muni
    limit 1;
  if v_gp is null then
    raise exception 'Município não encontrado na tabela de grupamentos: %', v_muni;
  end if;

  update public.denuncias set
    municipio = v_muni,
    gp_responsavel = v_gp,
    grupamento_completo = v_gp_completo
  where id = p_id and ativo = true
  returning * into v_row;

  if v_row.id is null then raise exception 'Registro não encontrado ou está inativado.'; end if;
  return v_row;
end;
$$;

grant execute on function public.denuncia_voltar_pendente(uuid, uuid) to anon;
grant execute on function public.denuncia_editar_municipio(uuid, uuid, text) to anon;

-- ─── DESFAZER ───────────────────────────────────────────────────────────
-- drop function if exists public.denuncia_voltar_pendente(uuid,uuid);
-- drop function if exists public.denuncia_editar_municipio(uuid,uuid,text);

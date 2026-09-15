-- ══════════════════════════════════════════════════════════════════════
--  REQUISIÇÃO JUDICIAL — EDIÇÃO DOS DADOS LANÇADOS (corrigir erro de digitação)
--
--  Pedido: permitir corrigir informação lançada errada. Decisão: a ALTERAÇÃO
--  dos dados originais da requisição é restrita ao AUX P1 (e ao Admin Geral,
--  superusuário do sistema). Sem regra de prazo — simples, para não dar
--  problema com várias pessoas editando.
--
--  (O controle pós-envio — situação/autoridade/intranet — segue no
--  requisicao_judicial_controle_salvar, aberto a Aux P1/Admin Geral/CMT Cia.
--  A EXCLUSÃO também passa a Aux P1 + Admin Geral — ver abaixo.)
--
--  Depende de: 62 (requisicoes_judiciais, _reqjud_autoridade), 04
--  (_sessao_militar). Idempotente. Rodar no SQL Editor (depois do 62).
-- ══════════════════════════════════════════════════════════════════════

-- auditoria da edição
alter table public.requisicoes_judiciais add column if not exists editado_por_matricula text;
alter table public.requisicoes_judiciais add column if not exists editado_por_nome      text;
alter table public.requisicoes_judiciais add column if not exists editado_em            timestamptz;

-- ─── quem pode EDITAR os dados lançados = Aux P1  OU  Admin Geral ──────
create or replace function public._reqjud_pode_editar(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1');
$$;

-- ─── GET (uma requisição, só p/ quem pode editar) — carrega o form ─────
create or replace function public.requisicao_judicial_get(p_token uuid, p_id uuid)
returns public.requisicoes_judiciais
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.requisicoes_judiciais;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._reqjud_pode_editar(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Edição restrita ao Aux P1 / Admin Geral.';
  end if;
  select * into v_row from public.requisicoes_judiciais where id = p_id;
  if v_row.id is null then raise exception 'Requisição não encontrada.'; end if;
  return v_row;
end;
$$;

-- ─── EDITAR os dados lançados (só Aux P1 / Admin Geral) ────────────────
create or replace function public.requisicao_judicial_editar(p_token uuid, p_id uuid, p_dados jsonb)
returns public.requisicoes_judiciais
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.requisicoes_judiciais;
  v_ids  uuid[] := coalesce(
            case when jsonb_typeof(p_dados->'militares_ids') = 'array'
              then array(select (jsonb_array_elements_text(p_dados->'militares_ids'))::uuid)
              else '{}'::uuid[] end, '{}'::uuid[]);
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._reqjud_pode_editar(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Edição restrita ao Aux P1 / Admin Geral.';
  end if;
  if coalesce(nullif(p_dados->>'data_audiencia',''),'') = '' then
    raise exception 'Informe a data da audiência.';
  end if;

  update public.requisicoes_judiciais set
    data_audiencia          = (p_dados->>'data_audiencia')::date,
    horario                 = nullif(p_dados->>'horario',''),
    processo                = nullif(p_dados->>'processo',''),
    documento_origem        = nullif(p_dados->>'documento_origem',''),
    tipo_envolvimento       = nullif(p_dados->>'tipo_envolvimento',''),
    tipo_envolvimento_outro = nullif(p_dados->>'tipo_envolvimento_outro',''),
    municipio_lotacao       = nullif(p_dados->>'municipio_lotacao',''),
    municipio_requisicao    = nullif(p_dados->>'municipio_requisicao',''),
    local_audiencia         = nullif(p_dados->>'local_audiencia',''),
    endereco                = nullif(p_dados->>'endereco',''),
    metodo                  = nullif(p_dados->>'metodo',''),
    observacoes             = nullif(p_dados->>'observacoes',''),
    -- autoridade: re-deriva do novo local quando ele é um dos padrões;
    -- local fora do padrão (Outro) mantém a autoridade atual (Aux P1 ajusta no controle)
    autoridade_solicitante  = coalesce(public._reqjud_autoridade(p_dados->>'local_audiencia'), autoridade_solicitante),
    militares               = coalesce(p_dados->'militares','[]'::jsonb),
    militares_ids           = v_ids,
    militares_extra         = nullif(p_dados->>'militares_extra',''),
    anexos                  = case when p_dados ? 'anexos' then coalesce(p_dados->'anexos','[]'::jsonb) else anexos end,
    editado_por_matricula   = v_me.matricula,
    editado_por_nome        = coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo),
    editado_em              = now()
  where id = p_id
  returning * into v_row;
  if v_row.id is null then raise exception 'Requisição não encontrada.'; end if;
  return v_row;
end;
$$;

-- ─── EXCLUIR: agora liberado a Aux P1 + Admin Geral (antes só Admin Geral) ─
create or replace function public.requisicao_judicial_excluir(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._reqjud_pode_editar(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Exclusão restrita ao Aux P1 / Admin Geral.';
  end if;
  delete from public.requisicoes_judiciais where id = p_id;
end;
$$;

grant execute on function public._reqjud_pode_editar(text, text)                        to anon;
grant execute on function public.requisicao_judicial_get(uuid, uuid)                    to anon;
grant execute on function public.requisicao_judicial_editar(uuid, uuid, jsonb)          to anon;
grant execute on function public.requisicao_judicial_excluir(uuid, uuid)                to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Não precisa re-rodar o 62. O número (numero/numero_seq) NÃO muda na
-- edição — só os dados do conteúdo.
-- ══════════════════════════════════════════════════════════════════════

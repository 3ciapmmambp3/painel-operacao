-- ══════════════════════════════════════════════════════════════════════
--  DENÚNCIAS / REQUISIÇÕES — EDIÇÃO ATÉ O ATENDIMENTO
--
--  Pedido: permitir que o PM QUE RECEBEU (registrado_por) e o ADMIN GERAL
--  COMPLEMENTEM/CORRIJAM uma denúncia de balcão ou requisição enquanto ela
--  ainda NÃO foi atendida (situação PENDENTE ou EM ANDAMENTO). Depois de
--  atendida (CONCLUIDA/RESPONDIDA) ou inativada, fica travada.
--
--  A função re-deriva o grupamento a partir do município (igual criar_denuncia)
--  e NÃO mexe em: numero, tipo, situação, quem registrou, dados do atendimento.
--
--  Depende de: 01_denuncias.sql, 96_denuncia_data_recebimento.sql e o
--  _sessao_militar de 04/05. Idempotente.
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.denuncia_editar(p_token uuid, p_id uuid, dados jsonb)
returns public.denuncias
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   record;
  v_row  public.denuncias;
  v_muni text := upper(trim(dados->>'municipio'));
  v_gp   text;
  v_gp_completo text;
  v_receb date;
  v_prazo date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_row from public.denuncias where id = p_id;
  if v_row.id is null then raise exception 'Registro não encontrado.'; end if;

  -- só até o atendimento
  if v_row.ativo = false then
    raise exception 'Registro inativado — não pode ser editado.';
  end if;
  if v_row.situacao not in ('PENDENTE','EM ANDAMENTO') then
    raise exception 'Esta demanda já foi atendida e não pode mais ser editada.';
  end if;

  -- quem pode: Admin Geral OU o próprio PM que recebeu (compara só os dígitos)
  if v_me.nivel_acesso <> 'admin_geral'
     and regexp_replace(coalesce(v_me.matricula,''), '\D', '', 'g')
       <> regexp_replace(coalesce(v_row.registrado_por_matricula,''), '\D', '', 'g') then
    raise exception 'Edição permitida apenas ao Admin Geral ou ao policial que registrou a demanda.';
  end if;

  -- grupamento derivado do município (igual criar_denuncia)
  if coalesce(v_muni,'') = '' then raise exception 'Informe o município.'; end if;
  select gp_responsavel, grupamento_completo into v_gp, v_gp_completo
    from public.vw_municipio_grupamento
    where municipio_upper = v_muni
    limit 1;
  if v_gp is null then
    raise exception 'Município não encontrado na tabela de grupamentos: %', v_muni;
  end if;

  v_receb := coalesce(nullif(dados->>'data_recebimento','')::date, v_row.data_recebimento,
                      (now() at time zone 'America/Sao_Paulo')::date);
  v_prazo := coalesce(nullif(dados->>'prazo','')::date, v_receb + 45);

  update public.denuncias set
    origem              = coalesce(nullif(dados->>'origem',''), origem),
    origem_esfera       = nullif(dados->>'origem_esfera',''),
    numero_oficio       = nullif(dados->>'numero_oficio',''),
    denunciante         = nullif(dados->>'denunciante',''),
    denunciado          = nullif(dados->>'denunciado',''),
    data_fato           = nullif(dados->>'data_fato','')::date,
    data_recebimento    = v_receb,
    municipio           = v_muni,
    gp_responsavel      = v_gp,
    grupamento_completo = v_gp_completo,
    tema                = coalesce(nullif(dados->>'tema',''), tema),
    objeto              = nullif(dados->>'objeto',''),
    descricao           = coalesce(nullif(dados->>'descricao',''), descricao),
    endereco            = nullif(dados->>'endereco',''),
    referencia          = nullif(dados->>'referencia',''),
    observacoes         = nullif(dados->>'observacoes',''),
    prazo               = v_prazo,
    anexos              = coalesce(dados->'anexos', anexos)
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.denuncia_editar(uuid, uuid, jsonb) to anon;

-- ─── DESFAZER ───────────────────────────────────────────────────────────
-- drop function if exists public.denuncia_editar(uuid, uuid, jsonb);

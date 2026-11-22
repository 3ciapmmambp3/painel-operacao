-- ══════════════════════════════════════════════════════════════════════
--  db/208 — OS: documento de ORIGEM (o que deu causa à OS) + ajuste do salvar
--  Data: 2026-11-22
--
--  A maioria das OS tem um documento que a origina (ofício/solicitação do MP,
--  SEMAD, etc.). Adiciona o anexo opcional do documento de origem e inclui-o
--  no os_salvar. Nada mais muda. Idempotente.
-- ══════════════════════════════════════════════════════════════════════

alter table public.ordens_servico add column if not exists doc_origem_url     text;
alter table public.ordens_servico add column if not exists doc_origem_arquivo text;

create or replace function public.os_salvar(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.ordens_servico%rowtype; v_novo boolean; v_num integer; v_ano integer;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: controle do Aux P3 / Admin Geral.'; end if;

  v_novo := p_id is null;
  v_ano  := coalesce((p_dados->>'ano')::integer, extract(year from now())::integer);
  v_num  := nullif(btrim(p_dados->>'numero'),'')::integer;
  if v_novo and v_num is null then
    select coalesce(max(numero),0)+1 into v_num from public.ordens_servico where ano = v_ano;
  end if;

  if v_novo then
    insert into public.ordens_servico (numero, ano, operacao, descricao, com_diarias, grupamento,
            os_url, os_arquivo, planilha_url, planilha_arquivo, doc_origem_url, doc_origem_arquivo,
            criado_por, atualizado_por)
    values (v_num, v_ano, nullif(btrim(p_dados->>'operacao'),''), nullif(btrim(p_dados->>'descricao'),''),
            coalesce((p_dados->>'com_diarias')::boolean,false), nullif(btrim(p_dados->>'grupamento'),''),
            nullif(btrim(p_dados->>'os_url'),''), nullif(btrim(p_dados->>'os_arquivo'),''),
            nullif(btrim(p_dados->>'planilha_url'),''), nullif(btrim(p_dados->>'planilha_arquivo'),''),
            nullif(btrim(p_dados->>'doc_origem_url'),''), nullif(btrim(p_dados->>'doc_origem_arquivo'),''),
            v_me.matricula, v_me.matricula)
    returning * into v_row;
    insert into public.os_tramitacao (os_id, etapa, data, responsavel, criado_por)
    values (v_row.id, coalesce(nullif(btrim(p_dados->>'etapa'),''),'elaboracao'), current_date, v_me.matricula, v_me.matricula);
  else
    update public.ordens_servico set
      operacao = coalesce(nullif(btrim(p_dados->>'operacao'),''), operacao),
      descricao = p_dados->>'descricao',
      com_diarias = coalesce((p_dados->>'com_diarias')::boolean, com_diarias),
      grupamento = p_dados->>'grupamento',
      os_url = coalesce(p_dados->>'os_url', os_url),
      os_arquivo = coalesce(p_dados->>'os_arquivo', os_arquivo),
      planilha_url = coalesce(p_dados->>'planilha_url', planilha_url),
      planilha_arquivo = coalesce(p_dados->>'planilha_arquivo', planilha_arquivo),
      doc_origem_url = coalesce(p_dados->>'doc_origem_url', doc_origem_url),
      doc_origem_arquivo = coalesce(p_dados->>'doc_origem_arquivo', doc_origem_arquivo),
      atualizado_por = v_me.matricula, atualizado_em = now()
    where id = p_id returning * into v_row;
    if v_row.id is null then raise exception 'OS não encontrada.'; end if;
  end if;
  return to_jsonb(v_row);
end $$;

grant execute on function public.os_salvar(uuid, uuid, jsonb) to anon, authenticated;

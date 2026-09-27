-- ══════════════════════════════════════════════════════════════════════
--  MÓDULO EFETIVO — 3ª Cia PM MAmb (P1 / Recursos Humanos)
--  Card "Efetivo" do hub P1. Controle do Aux P1 (também Admin Geral e CMT
--  da Cia) sobre o quadro de pessoal: lotação (formato SIGEF/CPE),
--  antiguidade e baixa/transferência — mantendo o histórico.
--
--  ACESSO: só Aux P1 / Admin Geral / CMT da Cia (mesmo gate do Férias).
--
--  Alimenta o módulo Férias: lotação canônica por COD_UNIDADE e a ordem de
--  antiguidade (posto → última promoção → classificação → ordem manual).
--
--  Fonte de importação: aba "FormatoSIGEF/CPE" da planilha Baliza do Aux P1
--  (importador casa por Nº PM / matrícula e ATUALIZA o militar existente).
--
--  Depende de: 04 (_sessao_militar, militares), 101 (_posto_rank).
--  Idempotente. Rodar no SQL Editor (depois do 101).
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) NOVAS COLUNAS EM militares ─────────────────────────────────────
-- Lotação (formato SIGEF/CPE) — por código, à prova de expansão a outras unidades.
alter table public.militares add column if not exists cod_rpm                text;
alter table public.militares add column if not exists nome_rpm               text;
alter table public.militares add column if not exists cod_unidade_principal  text;
alter table public.militares add column if not exists nome_unidade_principal text;
alter table public.militares add column if not exists cod_unidade            text;  -- ex.: 6611 (AUX P1)
alter table public.militares add column if not exists nome_unidade           text;
alter table public.militares add column if not exists cod_siad               text;
alter table public.militares add column if not exists tipo_atividade         text;
alter table public.militares add column if not exists cod_municipio          text;

-- Antiguidade
alter table public.militares add column if not exists ultima_promocao        date;
alter table public.militares add column if not exists classificacao_curso    text;
alter table public.militares add column if not exists antiguidade_ordem      int;   -- LINHA da Baliza (editável)

-- Situação / baixa / transferência (mantém o histórico; login usa `ativo`)
alter table public.militares add column if not exists situacao_efetivo       text default 'ATIVO';
alter table public.militares add column if not exists transf_destino         text;
alter table public.militares add column if not exists transf_pasta_funcional boolean;
alter table public.militares add column if not exists transf_data_envio      date;
alter table public.militares add column if not exists transf_oficio_numero   text;
alter table public.militares add column if not exists transf_obs             text;
alter table public.militares add column if not exists transf_anexo           jsonb default '[]'::jsonb;

create index if not exists idx_militares_cod_unidade on public.militares (cod_unidade);
create index if not exists idx_militares_antig        on public.militares (antiguidade_ordem);
create index if not exists idx_militares_sit_efet     on public.militares (situacao_efetivo);

-- ─── 2) HELPER: quem gere o efetivo (Aux P1 / Admin Geral / CMT Cia) ───
create or replace function public._efetivo_pode(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y');
$$;

-- ─── 3) LISTAR (ordenado por antiguidade) ──────────────────────────────
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
           coalesce(m.situacao_efetivo,'ATIVO') as situacao_efetivo,
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

-- ─── 4) SALVAR um militar (lotação / antiguidade / identificação) ──────
create or replace function public.efetivo_salvar(p_token uuid, p_id uuid, p_dados jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Edição do efetivo restrita ao Aux P1 / Comando.';
  end if;

  update public.militares set
    posto_graduacao        = case when p_dados ? 'posto_graduacao'        then nullif(p_dados->>'posto_graduacao','')        else posto_graduacao        end,
    nome_completo          = case when p_dados ? 'nome_completo'          then coalesce(nullif(p_dados->>'nome_completo',''),nome_completo) else nome_completo end,
    nome_guerra            = case when p_dados ? 'nome_guerra'            then nullif(p_dados->>'nome_guerra','')            else nome_guerra            end,
    funcao                 = case when p_dados ? 'funcao'                 then nullif(p_dados->>'funcao','')                 else funcao                 end,
    cod_rpm                = case when p_dados ? 'cod_rpm'                then nullif(p_dados->>'cod_rpm','')                else cod_rpm                end,
    nome_rpm               = case when p_dados ? 'nome_rpm'               then nullif(p_dados->>'nome_rpm','')               else nome_rpm               end,
    cod_unidade_principal  = case when p_dados ? 'cod_unidade_principal'  then nullif(p_dados->>'cod_unidade_principal','')  else cod_unidade_principal  end,
    nome_unidade_principal = case when p_dados ? 'nome_unidade_principal' then nullif(p_dados->>'nome_unidade_principal','') else nome_unidade_principal end,
    cod_unidade            = case when p_dados ? 'cod_unidade'            then nullif(p_dados->>'cod_unidade','')            else cod_unidade            end,
    nome_unidade           = case when p_dados ? 'nome_unidade'           then nullif(p_dados->>'nome_unidade','')           else nome_unidade           end,
    cod_siad               = case when p_dados ? 'cod_siad'               then nullif(p_dados->>'cod_siad','')               else cod_siad               end,
    tipo_atividade         = case when p_dados ? 'tipo_atividade'         then nullif(p_dados->>'tipo_atividade','')         else tipo_atividade         end,
    cod_municipio          = case when p_dados ? 'cod_municipio'          then nullif(p_dados->>'cod_municipio','')          else cod_municipio          end,
    ultima_promocao        = case when p_dados ? 'ultima_promocao'        then nullif(p_dados->>'ultima_promocao','')::date  else ultima_promocao        end,
    classificacao_curso    = case when p_dados ? 'classificacao_curso'    then nullif(p_dados->>'classificacao_curso','')    else classificacao_curso    end,
    antiguidade_ordem      = case when p_dados ? 'antiguidade_ordem'      then nullif(p_dados->>'antiguidade_ordem','')::int else antiguidade_ordem      end
  where id = p_id;
  if not found then raise exception 'Militar não encontrado.'; end if;
end;
$$;

-- ─── 5) BAIXAR (transferir/veterano) — mantém o registro ───────────────
create or replace function public.efetivo_baixar(p_token uuid, p_id uuid, p_dados jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record; v_sit text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Baixa de efetivo restrita ao Aux P1 / Comando.';
  end if;
  v_sit := upper(coalesce(nullif(p_dados->>'situacao_efetivo',''),'TRANSFERIDO'));

  update public.militares set
    ativo                  = false,             -- sai do login e do efetivo ativo
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

-- ─── 6) REATIVAR (volta ao efetivo ativo) ──────────────────────────────
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

-- ─── 7) IMPORTAR (CRIA ou ATUALIZA por matrícula) ──────────────────────
-- Recebe a planilha preenchida (modelo baixável na tela). p_linhas: array de
-- objetos já com as CHAVES normalizadas pelo front:
--   { matricula, posto_graduacao, nome_completo, nome_guerra, funcao,
--     cod_rpm, nome_rpm, cod_unidade_principal, nome_unidade_principal,
--     cod_unidade, nome_unidade, cod_siad, tipo_atividade, cod_municipio,
--     ultima_promocao, classificacao_curso, antiguidade_ordem, situacao_efetivo }
-- Casa por matrícula (7 dígitos). Existe → ATUALIZA. Não existe → CRIA militar
-- novo (senha padrão Mudar@123, primeiro acesso, nível operacional). Assim o
-- Aux P1 inclui vários de uma vez importando a planilha. Devolve o resumo.
-- (search_path inclui extensions por causa do crypt/gen_salt do pgcrypto.)
create or replace function public.efetivo_importar(p_token uuid, p_linhas jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record; v_lin jsonb; v_clean text; v_id uuid; v_nome text; v_mat text;
  v_criados int := 0; v_atualizados int := 0; v_ignorados text[] := '{}';
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Importação restrita ao Aux P1 / Comando.';
  end if;
  if jsonb_typeof(p_linhas) <> 'array' then raise exception 'Formato inválido.'; end if;

  for v_lin in select * from jsonb_array_elements(p_linhas) loop
    v_clean := lpad(regexp_replace(coalesce(v_lin->>'matricula',''), '\D', '', 'g'), 7, '0');
    if v_clean = '0000000' then continue; end if;
    v_nome := nullif(btrim(v_lin->>'nome_completo'),'');
    select id into v_id from public.militares where matricula_clean = v_clean;

    if v_id is null then
      -- CRIAR — precisa do nome; sem nome, ignora e reporta.
      if v_nome is null then v_ignorados := v_ignorados || (v_clean || ' (sem nome)'); continue; end if;
      v_mat := case when length(v_clean)=7
                    then substr(v_clean,1,3)||'.'||substr(v_clean,4,3)||'-'||substr(v_clean,7,1)
                    else v_clean end;
      insert into public.militares (
        matricula, matricula_clean, posto_graduacao, nome_completo, nome_guerra, funcao,
        nivel_acesso, senha_hash, primeiro_acesso, ativo,
        cod_rpm, nome_rpm, cod_unidade_principal, nome_unidade_principal, cod_unidade,
        nome_unidade, cod_siad, tipo_atividade, cod_municipio,
        ultima_promocao, classificacao_curso, antiguidade_ordem, situacao_efetivo
      ) values (
        v_mat, v_clean, nullif(v_lin->>'posto_graduacao',''), v_nome,
        nullif(v_lin->>'nome_guerra',''), nullif(v_lin->>'funcao',''),
        'operacional', crypt('Mudar@123', gen_salt('bf')), true, true,
        nullif(v_lin->>'cod_rpm',''), nullif(v_lin->>'nome_rpm',''),
        nullif(v_lin->>'cod_unidade_principal',''), nullif(v_lin->>'nome_unidade_principal',''),
        nullif(v_lin->>'cod_unidade',''), nullif(v_lin->>'nome_unidade',''),
        nullif(v_lin->>'cod_siad',''), nullif(v_lin->>'tipo_atividade',''), nullif(v_lin->>'cod_municipio',''),
        nullif(v_lin->>'ultima_promocao','')::date, nullif(v_lin->>'classificacao_curso',''),
        nullif(v_lin->>'antiguidade_ordem','')::int,
        coalesce(nullif(v_lin->>'situacao_efetivo',''),'ATIVO')
      );
      v_criados := v_criados + 1;
    else
      update public.militares set
        posto_graduacao        = coalesce(nullif(v_lin->>'posto_graduacao',''), posto_graduacao),
        nome_completo          = coalesce(v_nome, nome_completo),
        nome_guerra            = coalesce(nullif(v_lin->>'nome_guerra',''),     nome_guerra),
        funcao                 = coalesce(nullif(v_lin->>'funcao',''),          funcao),
        cod_rpm                = coalesce(nullif(v_lin->>'cod_rpm',''),                cod_rpm),
        nome_rpm               = coalesce(nullif(v_lin->>'nome_rpm',''),               nome_rpm),
        cod_unidade_principal  = coalesce(nullif(v_lin->>'cod_unidade_principal',''),  cod_unidade_principal),
        nome_unidade_principal = coalesce(nullif(v_lin->>'nome_unidade_principal',''), nome_unidade_principal),
        cod_unidade            = coalesce(nullif(v_lin->>'cod_unidade',''),            cod_unidade),
        nome_unidade           = coalesce(nullif(v_lin->>'nome_unidade',''),           nome_unidade),
        cod_siad               = coalesce(nullif(v_lin->>'cod_siad',''),               cod_siad),
        tipo_atividade         = coalesce(nullif(v_lin->>'tipo_atividade',''),         tipo_atividade),
        cod_municipio          = coalesce(nullif(v_lin->>'cod_municipio',''),          cod_municipio),
        ultima_promocao        = coalesce(nullif(v_lin->>'ultima_promocao','')::date,  ultima_promocao),
        classificacao_curso    = coalesce(nullif(v_lin->>'classificacao_curso',''),    classificacao_curso),
        antiguidade_ordem      = coalesce(nullif(v_lin->>'antiguidade_ordem','')::int, antiguidade_ordem),
        situacao_efetivo       = coalesce(nullif(v_lin->>'situacao_efetivo',''),       situacao_efetivo)
      where id = v_id;
      v_atualizados := v_atualizados + 1;
    end if;
  end loop;

  return jsonb_build_object('criados', v_criados, 'atualizados', v_atualizados,
    'ignorados', to_jsonb(v_ignorados), 'qtd_ignorados', coalesce(array_length(v_ignorados,1),0));
end;
$$;

-- ─── 8) GRANTS ─────────────────────────────────────────────────────────
grant execute on function public._efetivo_pode(text, text)              to anon;
grant execute on function public.efetivo_listar(uuid, boolean)          to anon;
grant execute on function public.efetivo_salvar(uuid, uuid, jsonb)      to anon;
grant execute on function public.efetivo_baixar(uuid, uuid, jsonb)      to anon;
grant execute on function public.efetivo_reativar(uuid, uuid)           to anon;
grant execute on function public.efetivo_importar(uuid, jsonb)          to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Reusa _sessao_militar (04), _posto_rank (101), militares (RLS já
-- ativo — tudo passa por estas funções security definer). Não precisa
-- re-rodar anteriores.
--
-- DESFAZER (só se precisar):
--   drop function if exists public.efetivo_importar(uuid,jsonb);
--   drop function if exists public.efetivo_reativar(uuid,uuid);
--   drop function if exists public.efetivo_baixar(uuid,uuid,jsonb);
--   drop function if exists public.efetivo_salvar(uuid,uuid,jsonb);
--   drop function if exists public.efetivo_listar(uuid,boolean);
--   drop function if exists public._efetivo_pode(text,text);
--   (as colunas novas em militares podem permanecer sem efeito colateral)
-- ══════════════════════════════════════════════════════════════════════

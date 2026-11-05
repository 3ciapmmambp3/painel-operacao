-- ══════════════════════════════════════════════════════════════════════
--  db/175 — Autoatualização cadastral (o militar confere/atualiza os
--           próprios dados pessoais) + campanha da Aux P1
--  Data: 2026-11-05
--
--  Fluxo:
--   • A Aux P1 / Comando ABRE uma campanha (com prazo e, opcionalmente, um
--     pelotão). Pode fechar quando quiser.
--   • Cada militar vê SÓ os PRÓPRIOS dados (a função lê/grava pela matrícula
--     da sessão — nunca por id vindo do cliente) e confirma/atualiza.
--   • O painel do efetivo mostra quem já confirmou × pendente (calculado no
--     front a partir de dados_confirmados_* que o efetivo_listar devolve).
--   • O Meu Dia mostra um aviso enquanto a campanha estiver aberta e o
--     militar não tiver confirmado.
--
--  Campos que o MILITAR pode alterar (whitelist no servidor):
--   filiação (mãe/pai), contato (telefones + e-mail pessoal), documentos
--   (RG/órgão/emissão, CPF, título, CNH, nascimento, sexo) e endereço
--   residencial estruturado. Dados de CARREIRA (matrícula, posto, função,
--   lotação, antiguidade, ingresso, situação) NUNCA são tocados aqui.
--
--  Idempotente. Rodar DEPOIS do db/173.
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) Colunas de controle da confirmação (na própria militares) ──────
alter table public.militares add column if not exists dados_confirmados_em       timestamptz;
alter table public.militares add column if not exists dados_confirmados_campanha uuid;

-- ─── 2) Tabela de campanha ─────────────────────────────────────────────
create table if not exists public.efetivo_att_campanha (
  id          uuid primary key default gen_random_uuid(),
  aberta      boolean     not null default true,
  prazo       date,
  escopo_pel  text,                 -- null = Companhia inteira; ex.: '5'
  mensagem    text,
  criada_por  uuid,
  criada_em   timestamptz not null default now(),
  fechada_em  timestamptz
);
alter table public.efetivo_att_campanha enable row level security;
-- sem policies: acesso só pelas funções SECURITY DEFINER abaixo (anon não lê direto)

-- ─── 3) LISTAR efetivo (db/173 + colunas de confirmação) ───────────────
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
           m.nome_mae, m.nome_pai, m.data_ingresso, m.rg_orgao_expedidor, m.rg_emissao,
           m.end_res_logradouro, m.end_res_numero, m.end_res_complemento,
           m.end_res_bairro, m.end_res_cidade, m.end_res_cep,
           m.dados_confirmados_em, m.dados_confirmados_campanha,
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

-- ─── 4) MEUS DADOS — ler (só os próprios; pela matrícula da sessão) ────
create or replace function public.meus_dados_ler(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; m record; c record; v_scope_ok boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into m from public.militares where id = v_me.id;        -- SEMPRE o próprio
  if m.id is null then raise exception 'Militar não encontrado.'; end if;

  -- campanha aberta mais recente
  select * into c from public.efetivo_att_campanha where aberta = true order by criada_em desc limit 1;
  -- a campanha alcança este militar? (null = Cia toda; senão compara o nº do pelotão)
  v_scope_ok := c.id is not null and (
       c.escopo_pel is null
    or c.escopo_pel = coalesce(substring(upper(coalesce(m.grupamento_id,'')||' '||coalesce(m.nome_unidade,'')) from '([0-9]+)\s*(?:º|O|ª)?\s*PEL'), '')
  );

  return jsonb_build_object(
    -- identificação (somente leitura na tela do militar)
    'matricula', m.matricula, 'posto_graduacao', m.posto_graduacao,
    'nome_completo', m.nome_completo, 'nome_guerra', m.nome_guerra, 'funcao', m.funcao,
    'grupamento_id', m.grupamento_id, 'nome_unidade', m.nome_unidade,
    'data_ingresso', m.data_ingresso, 'ultima_promocao', m.ultima_promocao,
    'email_funcional', m.email_funcional,
    -- editáveis pelo militar
    'nome_mae', m.nome_mae, 'nome_pai', m.nome_pai,
    'telefone_funcional', m.telefone_funcional, 'telefone_pessoal1', m.telefone_pessoal1,
    'telefone_pessoal2', m.telefone_pessoal2, 'email_pessoal', m.email_pessoal,
    'rg', m.rg, 'rg_orgao_expedidor', m.rg_orgao_expedidor, 'rg_emissao', m.rg_emissao,
    'cpf', m.cpf, 'titulo_eleitor', m.titulo_eleitor,
    'cnh_numero', m.cnh_numero, 'cnh_categoria', m.cnh_categoria, 'cnh_validade', m.cnh_validade,
    'data_nascimento', m.data_nascimento, 'sexo', m.sexo,
    'end_res_logradouro', m.end_res_logradouro, 'end_res_numero', m.end_res_numero,
    'end_res_complemento', m.end_res_complemento, 'end_res_bairro', m.end_res_bairro,
    'end_res_cidade', m.end_res_cidade, 'end_res_cep', m.end_res_cep,
    'dados_confirmados_em', m.dados_confirmados_em,
    'campanha', case when not v_scope_ok then null else jsonb_build_object(
        'id', c.id, 'prazo', c.prazo, 'mensagem', c.mensagem, 'criada_em', c.criada_em,
        'confirmado', (m.dados_confirmados_campanha = c.id)
      ) end
  );
end;
$$;

-- ─── 5) MEUS DADOS — salvar (só os próprios + whitelist de campos) ─────
create or replace function public.meus_dados_salvar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_camp uuid;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select id into v_camp from public.efetivo_att_campanha where aberta = true order by criada_em desc limit 1;

  update public.militares set
    nome_mae            = case when p_dados ? 'nome_mae'            then nullif(p_dados->>'nome_mae','')            else nome_mae            end,
    nome_pai            = case when p_dados ? 'nome_pai'            then nullif(p_dados->>'nome_pai','')            else nome_pai            end,
    telefone_funcional  = case when p_dados ? 'telefone_funcional'  then nullif(p_dados->>'telefone_funcional','')  else telefone_funcional  end,
    telefone_pessoal1   = case when p_dados ? 'telefone_pessoal1'   then nullif(p_dados->>'telefone_pessoal1','')   else telefone_pessoal1   end,
    telefone_pessoal2   = case when p_dados ? 'telefone_pessoal2'   then nullif(p_dados->>'telefone_pessoal2','')   else telefone_pessoal2   end,
    email_pessoal       = case when p_dados ? 'email_pessoal'       then nullif(p_dados->>'email_pessoal','')       else email_pessoal       end,
    rg                  = case when p_dados ? 'rg'                  then nullif(p_dados->>'rg','')                  else rg                  end,
    rg_orgao_expedidor  = case when p_dados ? 'rg_orgao_expedidor'  then nullif(p_dados->>'rg_orgao_expedidor','')  else rg_orgao_expedidor  end,
    rg_emissao          = case when p_dados ? 'rg_emissao'          then nullif(p_dados->>'rg_emissao','')::date    else rg_emissao          end,
    cpf                 = case when p_dados ? 'cpf'                 then nullif(p_dados->>'cpf','')                 else cpf                 end,
    titulo_eleitor      = case when p_dados ? 'titulo_eleitor'      then nullif(p_dados->>'titulo_eleitor','')      else titulo_eleitor      end,
    cnh_numero          = case when p_dados ? 'cnh_numero'          then nullif(p_dados->>'cnh_numero','')          else cnh_numero          end,
    cnh_categoria       = case when p_dados ? 'cnh_categoria'       then nullif(p_dados->>'cnh_categoria','')       else cnh_categoria       end,
    cnh_validade        = case when p_dados ? 'cnh_validade'        then nullif(p_dados->>'cnh_validade','')::date  else cnh_validade        end,
    data_nascimento     = case when p_dados ? 'data_nascimento'     then nullif(p_dados->>'data_nascimento','')::date else data_nascimento   end,
    sexo                = case when p_dados ? 'sexo'                then nullif(p_dados->>'sexo','')                else sexo                end,
    end_res_logradouro  = case when p_dados ? 'end_res_logradouro'  then nullif(p_dados->>'end_res_logradouro','')  else end_res_logradouro  end,
    end_res_numero      = case when p_dados ? 'end_res_numero'      then nullif(p_dados->>'end_res_numero','')      else end_res_numero      end,
    end_res_complemento = case when p_dados ? 'end_res_complemento' then nullif(p_dados->>'end_res_complemento','') else end_res_complemento end,
    end_res_bairro      = case when p_dados ? 'end_res_bairro'      then nullif(p_dados->>'end_res_bairro','')      else end_res_bairro      end,
    end_res_cidade      = case when p_dados ? 'end_res_cidade'      then nullif(p_dados->>'end_res_cidade','')      else end_res_cidade      end,
    end_res_cep         = case when p_dados ? 'end_res_cep'         then nullif(p_dados->>'end_res_cep','')         else end_res_cep         end,
    dados_confirmados_em       = now(),
    dados_confirmados_campanha = v_camp
  where id = v_me.id;        -- SEMPRE o próprio militar da sessão

  return jsonb_build_object('ok', true, 'confirmado_em', now(), 'campanha', v_camp);
end;
$$;

-- ─── 6) CAMPANHA — abrir / fechar / ler (Aux P1 / Comando) ─────────────
create or replace function public.efetivo_att_abrir(p_token uuid, p_prazo date default null, p_escopo_pel text default null, p_mensagem text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_id uuid;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Abrir campanha restrito ao Aux P1 / Comando.';
  end if;
  -- fecha qualquer campanha aberta antes de abrir a nova
  update public.efetivo_att_campanha set aberta = false, fechada_em = now() where aberta = true;
  insert into public.efetivo_att_campanha (prazo, escopo_pel, mensagem, criada_por)
    values (p_prazo, nullif(btrim(p_escopo_pel),''), nullif(btrim(p_mensagem),''), v_me.id)
    returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.efetivo_att_fechar(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Fechar campanha restrito ao Aux P1 / Comando.';
  end if;
  update public.efetivo_att_campanha set aberta = false, fechada_em = now() where aberta = true;
  return jsonb_build_object('ok', true);
end;
$$;

-- Campanha atual (para o painel do efetivo). Devolve null se não houver aberta.
create or replace function public.efetivo_att_atual(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; c record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Restrito ao Aux P1 / Comando.';
  end if;
  select * into c from public.efetivo_att_campanha where aberta = true order by criada_em desc limit 1;
  if c.id is null then return null; end if;
  return jsonb_build_object('id', c.id, 'prazo', c.prazo, 'escopo_pel', c.escopo_pel,
    'mensagem', c.mensagem, 'criada_em', c.criada_em);
end;
$$;

-- ─── GRANTS ────────────────────────────────────────────────────────────
grant execute on function public.efetivo_listar(uuid, boolean)                  to anon;
grant execute on function public.meus_dados_ler(uuid)                           to anon;
grant execute on function public.meus_dados_salvar(uuid, jsonb)                 to anon;
grant execute on function public.efetivo_att_abrir(uuid, date, text, text)      to anon;
grant execute on function public.efetivo_att_fechar(uuid)                       to anon;
grant execute on function public.efetivo_att_atual(uuid)                        to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar DEPOIS do db/173 (idempotente).
-- ══════════════════════════════════════════════════════════════════════

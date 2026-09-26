-- ══════════════════════════════════════════════════════════════════════
--  EFETIVO — dados pessoais/funcionais completos (ficha do militar)
--  Acesso segue restrito a Aux P1 / Admin Geral / CMT Cia (efetivo_*).
--  Puxados da Baliza na importação; exibidos na ficha (clicar no nome).
--  Depende de: 102 (colunas base + funções). Idempotente. Rodar depois do 106.
-- ══════════════════════════════════════════════════════════════════════

-- 1) COLUNAS NOVAS
alter table public.militares add column if not exists rg                    text;
alter table public.militares add column if not exists cpf                   text;
alter table public.militares add column if not exists titulo_eleitor        text;
alter table public.militares add column if not exists cnh_numero            text;
alter table public.militares add column if not exists cnh_categoria         text;
alter table public.militares add column if not exists cnh_validade          date;
alter table public.militares add column if not exists data_nascimento       date;
alter table public.militares add column if not exists telefone_funcional    text;
alter table public.militares add column if not exists telefone_pessoal1     text;
alter table public.militares add column if not exists telefone_pessoal2     text;
alter table public.militares add column if not exists endereco_funcional    text;
alter table public.militares add column if not exists endereco_residencial1 text;
alter table public.militares add column if not exists endereco_residencial2 text;
alter table public.militares add column if not exists email_pessoal         text;
alter table public.militares add column if not exists email_funcional       text;
alter table public.militares add column if not exists sexo                  text;

-- 2) LISTAR (inclui os novos campos)
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

-- 3) SALVAR (aceita os novos campos, edição parcial por chave)
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
    antiguidade_ordem      = case when p_dados ? 'antiguidade_ordem'      then nullif(p_dados->>'antiguidade_ordem','')::int else antiguidade_ordem      end,
    rg                     = case when p_dados ? 'rg'                     then nullif(p_dados->>'rg','')                     else rg                     end,
    cpf                    = case when p_dados ? 'cpf'                    then nullif(p_dados->>'cpf','')                    else cpf                    end,
    titulo_eleitor         = case when p_dados ? 'titulo_eleitor'         then nullif(p_dados->>'titulo_eleitor','')         else titulo_eleitor         end,
    cnh_numero             = case when p_dados ? 'cnh_numero'             then nullif(p_dados->>'cnh_numero','')             else cnh_numero             end,
    cnh_categoria          = case when p_dados ? 'cnh_categoria'          then nullif(p_dados->>'cnh_categoria','')          else cnh_categoria          end,
    cnh_validade           = case when p_dados ? 'cnh_validade'           then nullif(p_dados->>'cnh_validade','')::date     else cnh_validade           end,
    data_nascimento        = case when p_dados ? 'data_nascimento'        then nullif(p_dados->>'data_nascimento','')::date  else data_nascimento        end,
    telefone_funcional     = case when p_dados ? 'telefone_funcional'     then nullif(p_dados->>'telefone_funcional','')     else telefone_funcional     end,
    telefone_pessoal1      = case when p_dados ? 'telefone_pessoal1'      then nullif(p_dados->>'telefone_pessoal1','')      else telefone_pessoal1      end,
    telefone_pessoal2      = case when p_dados ? 'telefone_pessoal2'      then nullif(p_dados->>'telefone_pessoal2','')      else telefone_pessoal2      end,
    endereco_funcional     = case when p_dados ? 'endereco_funcional'     then nullif(p_dados->>'endereco_funcional','')     else endereco_funcional     end,
    endereco_residencial1  = case when p_dados ? 'endereco_residencial1'  then nullif(p_dados->>'endereco_residencial1','')  else endereco_residencial1  end,
    endereco_residencial2  = case when p_dados ? 'endereco_residencial2'  then nullif(p_dados->>'endereco_residencial2','')  else endereco_residencial2  end,
    email_pessoal          = case when p_dados ? 'email_pessoal'          then nullif(p_dados->>'email_pessoal','')          else email_pessoal          end,
    email_funcional        = case when p_dados ? 'email_funcional'        then nullif(p_dados->>'email_funcional','')        else email_funcional        end,
    sexo                   = case when p_dados ? 'sexo'                   then nullif(p_dados->>'sexo','')                   else sexo                   end
  where id = p_id;
  if not found then raise exception 'Militar não encontrado.'; end if;
end;
$$;

-- 4) IMPORTAR (cria/atualiza, agora com os pessoais)
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
      if v_nome is null then v_ignorados := v_ignorados || (v_clean || ' (sem nome)'); continue; end if;
      v_mat := case when length(v_clean)=7 then substr(v_clean,1,3)||'.'||substr(v_clean,4,3)||'-'||substr(v_clean,7,1) else v_clean end;
      insert into public.militares (
        matricula, matricula_clean, posto_graduacao, nome_completo, nome_guerra, funcao,
        nivel_acesso, senha_hash, primeiro_acesso, ativo,
        cod_rpm, nome_rpm, cod_unidade_principal, nome_unidade_principal, cod_unidade,
        nome_unidade, cod_siad, tipo_atividade, cod_municipio,
        ultima_promocao, classificacao_curso, antiguidade_ordem, situacao_efetivo,
        rg, cpf, titulo_eleitor, cnh_numero, cnh_categoria, cnh_validade, data_nascimento,
        telefone_funcional, telefone_pessoal1, telefone_pessoal2,
        endereco_funcional, endereco_residencial1, endereco_residencial2,
        email_pessoal, email_funcional, sexo
      ) values (
        v_mat, v_clean, nullif(v_lin->>'posto_graduacao',''), v_nome,
        nullif(v_lin->>'nome_guerra',''), nullif(v_lin->>'funcao',''),
        'operacional', crypt('Mudar@123', gen_salt('bf')), true, true,
        nullif(v_lin->>'cod_rpm',''), nullif(v_lin->>'nome_rpm',''),
        nullif(v_lin->>'cod_unidade_principal',''), nullif(v_lin->>'nome_unidade_principal',''),
        nullif(v_lin->>'cod_unidade',''), nullif(v_lin->>'nome_unidade',''),
        nullif(v_lin->>'cod_siad',''), nullif(v_lin->>'tipo_atividade',''), nullif(v_lin->>'cod_municipio',''),
        nullif(v_lin->>'ultima_promocao','')::date, nullif(v_lin->>'classificacao_curso',''),
        nullif(v_lin->>'antiguidade_ordem','')::int, coalesce(nullif(v_lin->>'situacao_efetivo',''),'ATIVO'),
        nullif(v_lin->>'rg',''), nullif(v_lin->>'cpf',''), nullif(v_lin->>'titulo_eleitor',''),
        nullif(v_lin->>'cnh_numero',''), nullif(v_lin->>'cnh_categoria',''), nullif(v_lin->>'cnh_validade','')::date,
        nullif(v_lin->>'data_nascimento','')::date,
        nullif(v_lin->>'telefone_funcional',''), nullif(v_lin->>'telefone_pessoal1',''), nullif(v_lin->>'telefone_pessoal2',''),
        nullif(v_lin->>'endereco_funcional',''), nullif(v_lin->>'endereco_residencial1',''), nullif(v_lin->>'endereco_residencial2',''),
        nullif(v_lin->>'email_pessoal',''), nullif(v_lin->>'email_funcional',''), nullif(v_lin->>'sexo','')
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
        situacao_efetivo       = coalesce(nullif(v_lin->>'situacao_efetivo',''),       situacao_efetivo),
        rg                     = coalesce(nullif(v_lin->>'rg',''),                     rg),
        cpf                    = coalesce(nullif(v_lin->>'cpf',''),                    cpf),
        titulo_eleitor         = coalesce(nullif(v_lin->>'titulo_eleitor',''),         titulo_eleitor),
        cnh_numero             = coalesce(nullif(v_lin->>'cnh_numero',''),             cnh_numero),
        cnh_categoria          = coalesce(nullif(v_lin->>'cnh_categoria',''),          cnh_categoria),
        cnh_validade           = coalesce(nullif(v_lin->>'cnh_validade','')::date,     cnh_validade),
        data_nascimento        = coalesce(nullif(v_lin->>'data_nascimento','')::date,  data_nascimento),
        telefone_funcional     = coalesce(nullif(v_lin->>'telefone_funcional',''),     telefone_funcional),
        telefone_pessoal1      = coalesce(nullif(v_lin->>'telefone_pessoal1',''),      telefone_pessoal1),
        telefone_pessoal2      = coalesce(nullif(v_lin->>'telefone_pessoal2',''),      telefone_pessoal2),
        endereco_funcional     = coalesce(nullif(v_lin->>'endereco_funcional',''),     endereco_funcional),
        endereco_residencial1  = coalesce(nullif(v_lin->>'endereco_residencial1',''),  endereco_residencial1),
        endereco_residencial2  = coalesce(nullif(v_lin->>'endereco_residencial2',''),  endereco_residencial2),
        email_pessoal          = coalesce(nullif(v_lin->>'email_pessoal',''),          email_pessoal),
        email_funcional        = coalesce(nullif(v_lin->>'email_funcional',''),        email_funcional),
        sexo                   = coalesce(nullif(v_lin->>'sexo',''),                   sexo)
      where id = v_id;
      v_atualizados := v_atualizados + 1;
    end if;
  end loop;

  return jsonb_build_object('criados', v_criados, 'atualizados', v_atualizados,
    'ignorados', to_jsonb(v_ignorados), 'qtd_ignorados', coalesce(array_length(v_ignorados,1),0));
end;
$$;

grant execute on function public.efetivo_listar(uuid, boolean)       to anon;
grant execute on function public.efetivo_salvar(uuid, uuid, jsonb)   to anon;
grant execute on function public.efetivo_importar(uuid, jsonb)       to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do 106.
-- ══════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════
--  db/176 — RG: órgão expedidor + UF (estado) separados; e a Última
--           promoção passa a ser confirmável/editável pelo próprio militar
--  Data: 2026-11-05
--
--  1) Nova coluna rg_orgao_uf (ex.: 'MG'). O órgão (rg_orgao_expedidor)
--     guarda a sigla (ex.: 'SSP') e a tela exibe junto: "SSP/MG".
--  2) efetivo_listar passa a devolver rg_orgao_uf.
--  3) efetivo_salvar (P1) passa a gravar rg_orgao_uf.
--  4) meus_dados_ler devolve rg_orgao_uf.
--  5) meus_dados_salvar: militar passa a poder gravar rg_orgao_uf E
--     ultima_promocao (esta SEM trava — confere/corrige toda vez; a data
--     de ingresso continua travada após o 1º preenchimento).
--
--  Idempotente. Rodar DEPOIS do db/175.
-- ══════════════════════════════════════════════════════════════════════

alter table public.militares add column if not exists rg_orgao_uf text;

-- ─── efetivo_listar (db/175 + rg_orgao_uf) ─────────────────────────────
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

-- ─── efetivo_salvar (db/173 + rg_orgao_uf) ─────────────────────────────
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
    grupamento_id          = case when p_dados ? 'grupamento_id'          then nullif(p_dados->>'grupamento_id','')          else grupamento_id          end,
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
    rg_orgao_expedidor     = case when p_dados ? 'rg_orgao_expedidor'     then nullif(p_dados->>'rg_orgao_expedidor','')     else rg_orgao_expedidor     end,
    rg_orgao_uf            = case when p_dados ? 'rg_orgao_uf'            then nullif(p_dados->>'rg_orgao_uf','')            else rg_orgao_uf            end,
    rg_emissao             = case when p_dados ? 'rg_emissao'             then nullif(p_dados->>'rg_emissao','')::date       else rg_emissao             end,
    cpf                    = case when p_dados ? 'cpf'                    then nullif(p_dados->>'cpf','')                    else cpf                    end,
    titulo_eleitor         = case when p_dados ? 'titulo_eleitor'         then nullif(p_dados->>'titulo_eleitor','')         else titulo_eleitor         end,
    cnh_numero             = case when p_dados ? 'cnh_numero'             then nullif(p_dados->>'cnh_numero','')             else cnh_numero             end,
    cnh_categoria          = case when p_dados ? 'cnh_categoria'          then nullif(p_dados->>'cnh_categoria','')          else cnh_categoria          end,
    cnh_validade           = case when p_dados ? 'cnh_validade'           then nullif(p_dados->>'cnh_validade','')::date     else cnh_validade           end,
    data_nascimento        = case when p_dados ? 'data_nascimento'        then nullif(p_dados->>'data_nascimento','')::date  else data_nascimento        end,
    data_ingresso          = case when p_dados ? 'data_ingresso'          then nullif(p_dados->>'data_ingresso','')::date    else data_ingresso          end,
    nome_mae               = case when p_dados ? 'nome_mae'               then nullif(p_dados->>'nome_mae','')               else nome_mae               end,
    nome_pai               = case when p_dados ? 'nome_pai'               then nullif(p_dados->>'nome_pai','')               else nome_pai               end,
    telefone_funcional     = case when p_dados ? 'telefone_funcional'     then nullif(p_dados->>'telefone_funcional','')     else telefone_funcional     end,
    telefone_pessoal1      = case when p_dados ? 'telefone_pessoal1'      then nullif(p_dados->>'telefone_pessoal1','')      else telefone_pessoal1      end,
    telefone_pessoal2      = case when p_dados ? 'telefone_pessoal2'      then nullif(p_dados->>'telefone_pessoal2','')      else telefone_pessoal2      end,
    endereco_funcional     = case when p_dados ? 'endereco_funcional'     then nullif(p_dados->>'endereco_funcional','')     else endereco_funcional     end,
    endereco_residencial1  = case when p_dados ? 'endereco_residencial1'  then nullif(p_dados->>'endereco_residencial1','')  else endereco_residencial1  end,
    endereco_residencial2  = case when p_dados ? 'endereco_residencial2'  then nullif(p_dados->>'endereco_residencial2','')  else endereco_residencial2  end,
    end_res_logradouro     = case when p_dados ? 'end_res_logradouro'     then nullif(p_dados->>'end_res_logradouro','')     else end_res_logradouro     end,
    end_res_numero         = case when p_dados ? 'end_res_numero'         then nullif(p_dados->>'end_res_numero','')         else end_res_numero         end,
    end_res_complemento    = case when p_dados ? 'end_res_complemento'    then nullif(p_dados->>'end_res_complemento','')    else end_res_complemento    end,
    end_res_bairro         = case when p_dados ? 'end_res_bairro'         then nullif(p_dados->>'end_res_bairro','')         else end_res_bairro         end,
    end_res_cidade         = case when p_dados ? 'end_res_cidade'         then nullif(p_dados->>'end_res_cidade','')         else end_res_cidade         end,
    end_res_cep            = case when p_dados ? 'end_res_cep'            then nullif(p_dados->>'end_res_cep','')            else end_res_cep            end,
    email_pessoal          = case when p_dados ? 'email_pessoal'          then nullif(p_dados->>'email_pessoal','')          else email_pessoal          end,
    email_funcional        = case when p_dados ? 'email_funcional'        then nullif(p_dados->>'email_funcional','')        else email_funcional        end,
    sexo                   = case when p_dados ? 'sexo'                   then nullif(p_dados->>'sexo','')                   else sexo                   end
  where id = p_id;
  if not found then raise exception 'Militar não encontrado.'; end if;
end;
$$;

-- ─── meus_dados_ler (db/175 + rg_orgao_uf) ─────────────────────────────
create or replace function public.meus_dados_ler(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; m record; c record; v_scope_ok boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into m from public.militares where id = v_me.id;
  if m.id is null then raise exception 'Militar não encontrado.'; end if;

  select * into c from public.efetivo_att_campanha where aberta = true order by criada_em desc limit 1;
  v_scope_ok := c.id is not null and coalesce(m.categoria,'militar') <> 'colaborador' and (
       c.escopo_pel is null
    or c.escopo_pel = coalesce(substring(upper(coalesce(m.grupamento_id,'')||' '||coalesce(m.nome_unidade,'')) from '([0-9]+)\s*(?:º|O|ª)?\s*PEL'), '')
  );

  return jsonb_build_object(
    'matricula', m.matricula, 'posto_graduacao', m.posto_graduacao,
    'nome_completo', m.nome_completo, 'nome_guerra', m.nome_guerra, 'funcao', m.funcao,
    'grupamento_id', m.grupamento_id, 'nome_unidade', m.nome_unidade,
    'data_ingresso', m.data_ingresso, 'ultima_promocao', m.ultima_promocao,
    'email_funcional', m.email_funcional,
    'nome_mae', m.nome_mae, 'nome_pai', m.nome_pai,
    'telefone_funcional', m.telefone_funcional, 'telefone_pessoal1', m.telefone_pessoal1,
    'telefone_pessoal2', m.telefone_pessoal2, 'email_pessoal', m.email_pessoal,
    'rg', m.rg, 'rg_orgao_expedidor', m.rg_orgao_expedidor, 'rg_orgao_uf', m.rg_orgao_uf, 'rg_emissao', m.rg_emissao,
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

-- ─── meus_dados_salvar (db/175 + rg_orgao_uf + ultima_promocao) ────────
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
    rg_orgao_uf         = case when p_dados ? 'rg_orgao_uf'         then nullif(p_dados->>'rg_orgao_uf','')         else rg_orgao_uf         end,
    rg_emissao          = case when p_dados ? 'rg_emissao'          then nullif(p_dados->>'rg_emissao','')::date    else rg_emissao          end,
    cpf                 = case when p_dados ? 'cpf'                 then nullif(p_dados->>'cpf','')                 else cpf                 end,
    titulo_eleitor      = case when p_dados ? 'titulo_eleitor'      then nullif(p_dados->>'titulo_eleitor','')      else titulo_eleitor      end,
    cnh_numero          = case when p_dados ? 'cnh_numero'          then nullif(p_dados->>'cnh_numero','')          else cnh_numero          end,
    cnh_categoria       = case when p_dados ? 'cnh_categoria'       then nullif(p_dados->>'cnh_categoria','')       else cnh_categoria       end,
    cnh_validade        = case when p_dados ? 'cnh_validade'        then nullif(p_dados->>'cnh_validade','')::date  else cnh_validade        end,
    data_nascimento     = case when p_dados ? 'data_nascimento'     then nullif(p_dados->>'data_nascimento','')::date else data_nascimento   end,
    sexo                = case when p_dados ? 'sexo'                then nullif(p_dados->>'sexo','')                else sexo                end,
    -- data de ingresso: só preenche quando está vazia (depois fica fixa)
    data_ingresso       = case when (p_dados ? 'data_ingresso') and data_ingresso is null then nullif(p_dados->>'data_ingresso','')::date else data_ingresso end,
    -- última promoção: o militar confere/corrige SEMPRE (sem trava)
    ultima_promocao     = case when p_dados ? 'ultima_promocao'     then nullif(p_dados->>'ultima_promocao','')::date else ultima_promocao   end,
    end_res_logradouro  = case when p_dados ? 'end_res_logradouro'  then nullif(p_dados->>'end_res_logradouro','')  else end_res_logradouro  end,
    end_res_numero      = case when p_dados ? 'end_res_numero'      then nullif(p_dados->>'end_res_numero','')      else end_res_numero      end,
    end_res_complemento = case when p_dados ? 'end_res_complemento' then nullif(p_dados->>'end_res_complemento','') else end_res_complemento end,
    end_res_bairro      = case when p_dados ? 'end_res_bairro'      then nullif(p_dados->>'end_res_bairro','')      else end_res_bairro      end,
    end_res_cidade      = case when p_dados ? 'end_res_cidade'      then nullif(p_dados->>'end_res_cidade','')      else end_res_cidade      end,
    end_res_cep         = case when p_dados ? 'end_res_cep'         then nullif(p_dados->>'end_res_cep','')         else end_res_cep         end,
    dados_confirmados_em       = now(),
    dados_confirmados_campanha = v_camp
  where id = v_me.id;

  return jsonb_build_object('ok', true, 'confirmado_em', now(), 'campanha', v_camp);
end;
$$;

-- ─── GRANTS ────────────────────────────────────────────────────────────
grant execute on function public.efetivo_listar(uuid, boolean)       to anon;
grant execute on function public.efetivo_salvar(uuid, uuid, jsonb)   to anon;
grant execute on function public.meus_dados_ler(uuid)                to anon;
grant execute on function public.meus_dados_salvar(uuid, jsonb)      to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar DEPOIS do db/175 (idempotente).
-- ══════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
--  CARTÃO PROGRAMA — restringe a visão do GRUPAMENTO à gestão
--
--  Antes: QUALQUER militar via todos os cartões do próprio grupamento.
--  Agora: só a GESTÃO vê o grupamento inteiro —
--     • Comandante de Grupamento (admin_gp)
--     • Comandante / Auxiliar de Pelotão (admin_pelotao)
--     • Admin Geral (admin / admin_geral)
--     • Comandante de Cia (funcao CMT + CIA)
--  O OPERACIONAL passa a ver apenas os cartões em que ele está na equipe
--  (comandante, motorista ou patrulheiro — casa pela matrícula).
--
--  Não muda quem EMITE (segue admin_gp+), nem quem ATENDE (a equipe continua
--  respondendo o cartão do próprio grupamento, via fallback do cartao_atender).
--
--  Depende de: 127 (cartoes_programa, _cartao_pode_ver, cartao_listar),
--              130 (_cartao_tem_militar), 04 (_nivel_num). Idempotente.
-- ════════════════════════════════════════════════════════════════════════

-- ─── Escopo: só a GESTÃO vê o grupamento inteiro ────────────────────────
-- Mantém a mesma regra de abrangência de antes (ADM / pelotão / grupamento
-- exato), mas agora o operacional (nível 0) cai no "return false": ele não
-- enxerga o grupamento — só os próprios cartões (tratado no cartao_listar).
create or replace function public._cartao_pode_ver(v_nivel text, v_funcao text, v_grup_me text, p_grupamento text)
returns boolean language plpgsql immutable as $$
declare v_ge boolean; v_adm boolean; v_pel text; v_pel_alvo text;
begin
  v_ge  := coalesce(v_nivel,'') in ('admin_geral','admin')
        or (upper(coalesce(v_funcao,'')) like '%CMT%' and upper(coalesce(v_funcao,'')) like '%CIA%');
  if v_ge then return true; end if;
  -- Daqui pra baixo, só gestão (Cmt GP, Cmt/Aux Pelotão). Operacional = false.
  if public._nivel_num(coalesce(v_nivel,'')) < public._nivel_num('admin_gp') then
    return false;
  end if;
  v_adm := upper(btrim(coalesce(v_grup_me,''))) like 'ADM%';
  if v_adm then return upper(btrim(coalesce(p_grupamento,''))) like 'ADM%'; end if;
  if coalesce(v_nivel,'') = 'admin_pelotao' then
    v_pel      := (regexp_match(upper(coalesce(v_grup_me,'')),   '(\d+)\s*PEL'))[1];
    v_pel_alvo := (regexp_match(upper(coalesce(p_grupamento,'')), '(\d+)\s*PEL'))[1];
    return v_pel is not null and v_pel = v_pel_alvo;
  end if;
  return p_grupamento = v_grup_me;
end;
$$;

-- ─── LISTAR: gestão vê o escopo; operacional vê só os próprios cartões ───
create or replace function public.cartao_listar(
  p_token uuid, p_ano int default null, p_status text default null,
  p_data date default null, p_grupamento text default null
) returns setof public.cartoes_programa
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  return query
    select c.* from public.cartoes_programa c
    where c.ativo = true
      and ( public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, c.grupamento_id)
            or public._cartao_tem_militar(c, v_me.matricula_clean) )
      and (p_ano is null or c.ano = p_ano)
      and (p_status is null or c.status = p_status)
      and (p_data is null or c.data_empenho = p_data)
      and (p_grupamento is null or c.grupamento_id = p_grupamento)
    order by c.data_empenho desc, c.numero_seq desc;
end;
$$;

grant execute on function public.cartao_listar(uuid, int, text, date, text) to anon;
-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 127 e 130).
-- ════════════════════════════════════════════════════════════════════════

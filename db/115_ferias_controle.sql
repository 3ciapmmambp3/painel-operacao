-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — LISTAGEM DE CONTROLE DA P1 (modelo da planilha da Cia)
--  Rodar depois do 101 (e demais do módulo férias).
--
--  Função NOVA e aditiva: NÃO altera ferias_pedidos_listar (usada pela aba
--  "Lançamentos" e pelo "Aprovar Pelotão"). Serve a aba "Controle" (só-leitura),
--  que reproduz a planilha "Férias e Férias-Prêmio":
--     LOCAL(pelotão) · GP(fração) · MILITAR(nome completo) · FRAÇÃO(cidade/lotação)
--     · TIPO · ORDEM(antiguidade) · DIAS · DATA INÍCIO · DATA TÉRMINO · SITUAÇÃO
--
--  Enriquece cada pedido com dados da tabela `militares` (nome completo, cidade
--  = nome_unidade, ordem de antiguidade), que não estão no jsonb `militar` do
--  pedido. Mesmo ESCOPO por perfil de ferias_pedidos_listar (db/101).
-- ══════════════════════════════════════════════════════════════════════

drop function if exists public.ferias_controle_listar(uuid, int);
create or replace function public.ferias_controle_listar(p_token uuid, p_ano int default null)
returns table (
  id            uuid,
  ordem         int,      -- antiguidade (militares.antiguidade_ordem)
  pelotao       text,     -- LOCAL
  fracao        text,     -- GP (grupamento_id do militar)
  matricula     text,
  pg            text,
  nome          text,     -- nome COMPLETO
  cidade        text,     -- FRAÇÃO na planilha = lotação/cidade (nome_unidade)
  tipo          text,     -- ANUAL / PREMIO
  modalidade    text,     -- 25_DIRETO / 15_10_FRACIONADO
  exercicio     int,
  situacao      text,     -- PENDENTE / APROVADO_PEL / VALIDADO / REJEITADO
  parcelas      jsonb     -- período final definido (parcela/ini/fim)
)
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_ano    int := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_p1     boolean;
  v_pel    text;
  v_cmtpel boolean;
  v_cmtgp  boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  v_p1  := public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao);
  v_pel := public._ferias_pelotao(v_me.grupamento_id);
  v_cmtpel := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* 'pel')
              or coalesce(v_me.nivel_acesso,'') = 'admin_pelotao';
  v_cmtgp  := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* '(gp|grupamento)')
              or coalesce(v_me.nivel_acesso,'') = 'admin_gp';

  return query
    select
      p.id,
      m.antiguidade_ordem                                        as ordem,
      p.pelotao,
      coalesce(m.grupamento_id, p.grupamento_id)                 as fracao,
      p.militar->>'matricula'                                    as matricula,
      coalesce(m.posto_graduacao, p.militar->>'pg')              as pg,
      coalesce(m.nome_completo, p.militar->>'nome',
               p.militar->>'guerra')                             as nome,
      m.nome_unidade                                             as cidade,
      p.tipo,
      p.modalidade,
      p.exercicio,
      p.situacao,
      p.parcelas
    from public.ferias_pedidos p
    left join public.militares m on m.id = p.militar_id
    where p.ano = v_ano
      and (
            v_p1
         or (v_cmtpel and p.pelotao is not distinct from v_pel)
         or (v_cmtgp  and p.grupamento_id is not distinct from v_me.grupamento_id)
         or (p.militar_id = v_me.id)
          )
    order by coalesce(m.antiguidade_ordem, 999999) asc,
             public._posto_rank((p.militar->>'pg')) asc,
             (p.militar->>'matricula') asc;
end;
$$;

grant execute on function public.ferias_controle_listar(uuid, int) to anon;

-- Reverter:
--   drop function if exists public.ferias_controle_listar(uuid,int);

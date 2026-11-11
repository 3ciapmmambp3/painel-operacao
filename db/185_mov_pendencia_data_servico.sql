-- ════════════════════════════════════════════════════════════════════════
-- 185_mov_pendencia_data_servico.sql
--   Ficha de Movimentação pendente: datar pela DATA DO SERVIÇO do relatório,
--   não pela data em que o relatório foi lançado.
--
--   PROBLEMA (achado 2026-11-11, caso Wagner 142.485-2 / VTR 36689):
--   Ao enviar um relatório de serviço, o painel cria uma "ficha pendente" para
--   cada viatura (relatorio-servico.html → mov_pendencia_criar). A RPC (db/37,
--   db/84) carimbava a pendência SEMPRE com a data de HOJE (now() Brasília),
--   ignorando a data real do serviço. Quando a equipe lança relatórios ATRASADOS
--   (backfill) — ex.: no dia 11/11 o Joabe lançou os relatórios de 30/09→06/11,
--   todos com a viatura antiga 36689 — cada um gerava uma ficha pendente de 36689
--   DATADA HOJE para o motorista daquele dia. Resultado: o Wagner, cujo serviço
--   de hoje é na 36682 (ficha já lançada), via uma "ficha pendente 36689 de hoje"
--   fantasma. Pior: se clicasse "Selecionar" e salvasse, criaria uma ficha da
--   36689 datada hoje — dado errado. (É o análogo, na CRIAÇÃO, do que o db/179
--   corrigiu na BAIXA.)
--
--   FIX:
--   • mov_pendencia_criar ganha o 7º param p_dia (data do serviço, 'YYYY-MM-DD',
--     com default null = hoje). Usa essa data (limitada a <= hoje) como v_dia em
--     todos os pontos: check "já tem ficha?", pendência aberta do dia e insert.
--     Assim, relatório de 06/11 lançado hoje → v_dia=06/11 → acha a ficha de 06/11
--     que já existe (inicio=06/11) → ja_tem_ficha → NÃO cria pendência nenhuma.
--   • tta.html continua chamando com 6 args (sem p_dia) → v_dia=hoje (TTA é sempre
--     do dia). relatorio-servico.html passa a enviar p_dia = data do serviço.
--
--   Depende de: 08 (mov_viaturas/mov_pendencias), 37, 84 (versão atual do RPC).
--   Idempotente. Rodar no SQL Editor depois do 84.
-- ════════════════════════════════════════════════════════════════════════

-- ── Criação/enriquecimento da pendência, agora datando pelo serviço ──────
drop function if exists public.mov_pendencia_criar(uuid, text, text, text, text, text);
create or replace function public.mov_pendencia_criar(
  p_token uuid, p_prefixo text, p_mot_mat text, p_mot_nome text,
  p_com_mat text default null, p_com_nome text default null,
  p_dia text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_row   public.mov_pendencias%rowtype;
  -- data do serviço do relatório, se veio válida ('YYYY-MM-DD'); nunca futura.
  v_dia   date := case
            when coalesce(p_dia,'') ~ '^\d{4}-\d{2}-\d{2}$'
              then least(p_dia::date, (now() at time zone 'America/Sao_Paulo')::date)
            else (now() at time zone 'America/Sao_Paulo')::date
          end;
  v_mot   text := nullif(regexp_replace(coalesce(p_mot_mat,''),'\D','','g'),'');
  v_com   text := nullif(regexp_replace(coalesce(p_com_mat,''),'\D','','g'),'');
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(p_prefixo,'') = '' then return jsonb_build_object('ok',false); end if;
  -- já existe ficha (na data do serviço) p/ a viatura? não precisa de pendência
  if exists (select 1 from public.mov_viaturas
             where prefixo=p_prefixo and ativo=true
               and (coalesce(inicio, criado_em) at time zone 'America/Sao_Paulo')::date = v_dia) then
    return jsonb_build_object('ok',true,'ja_tem_ficha',true);
  end if;
  -- pendência aberta nesse dia: enriquece (motorista/comandante) e devolve
  select * into v_row from public.mov_pendencias
   where prefixo=p_prefixo and dia=v_dia and atendida=false limit 1;
  if v_row.id is not null then
    update public.mov_pendencias set
      motorista_matricula  = coalesce(motorista_matricula, v_mot),
      motorista_nome       = coalesce(motorista_nome, nullif(p_mot_nome,'')),
      comandante_matricula = coalesce(comandante_matricula, v_com),
      comandante_nome      = coalesce(comandante_nome, nullif(p_com_nome,''))
     where id = v_row.id
    returning * into v_row;
    return to_jsonb(v_row);
  end if;
  insert into public.mov_pendencias
    (prefixo, dia, motorista_matricula, motorista_nome,
     comandante_matricula, comandante_nome, solicitado_por_matricula, solicitado_por_nome)
  values (p_prefixo, v_dia, v_mot, nullif(p_mot_nome,''),
     v_com, nullif(p_com_nome,''), v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo))
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

grant execute on function public.mov_pendencia_criar(uuid, text, text, text, text, text, text) to anon;

-- ── Limpeza retroativa PONTUAL (caso Wagner/36689 de 2026-11-11) ─────────
--    A ficha pendente de 36689 datada 11/11 nasceu do backfill dos relatórios
--    de 05/11 e 06/11 (lançados hoje). As fichas desses dias JÁ EXISTEM em
--    mov_viaturas (inicio 05/11 e 06/11), então não há nada pendente de fato.
--    Fecha como atendida (some do banner, que filtra atendida=false) apontando
--    a ficha 36689 mais recente do Wagner. Alvo pelo id, sem tocar em mais nada.
update public.mov_pendencias p
   set atendida = true,
       mov_id   = coalesce(p.mov_id, (
         select m.id from public.mov_viaturas m
          where m.prefixo = '36689' and m.ativo = true
            and regexp_replace(coalesce(m.motorista_matricula,''),'\D','','g') = '1424852'
          order by coalesce(m.inicio, m.criado_em) desc
          limit 1))
 where p.id = 'de100f83-40c5-4055-aa25-ea1aa94e90ee'
   and p.atendida = false;

-- Conferência (opcional):
-- select id, prefixo, dia, motorista_nome, atendida
--   from public.mov_pendencias where prefixo='36689' and dia='2026-11-11';

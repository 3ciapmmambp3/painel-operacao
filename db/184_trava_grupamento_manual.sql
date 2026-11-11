-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║ db/184 — Trava de "Corrigir grupamento responsável" contra o sync      ║
-- ╚══════════════════════════════════════════════════════════════════════╝
--
--  PROBLEMA
--  --------
--  No painel, a gestão (Aux P2/P3 + Admin) usa "Corrigir grupamento
--  responsável" para escopar a demanda no GP certo. Isso grava direto
--  gp_responsavel / grupamento_completo / fracao_responsavel na linha.
--
--  Mas o sync (Apps Script, cron 05h/20h → RPCs *_sync) RECALCULA o
--  grupamento pelo MUNICÍPIO a cada execução (vw_municipio_grupamento) e,
--  no "on conflict do update", sobrescreve o grupamento com
--  coalesce(excluded.gp_responsavel, …). Como o município quase sempre
--  resolve para algum GP, a correção manual era REVERTIDA toda noite.
--  (Ex.: NUDEN 2026.10.01.503.0000592 e ...0000601 — corrigidas para GP
--  Águas Formosas e voltando sozinhas para GP Teófilo Otoni.)
--
--  SOLUÇÃO (sem reescrever as 5 funções de sync)
--  --------------------------------------------
--  1) Marca-se a correção manual com gp_manual_at (carimbo de data/hora).
--  2) Um trigger BEFORE UPDATE preserva o trio de grupamento quando a linha
--     JÁ tem gp_manual_at e o UPDATE em curso NÃO está fazendo uma nova
--     correção manual (ou seja, não mexeu em gp_manual_at). O sync nunca
--     escreve gp_manual_at → fica travado. Uma nova correção pelo painel
--     SEMPRE manda gp_manual_at = now() → passa e vence.
--
--  Afeta os 5 módulos com essa mesma gestão: NUDEN, DDU, RI, Emergência, MC.
--  Denúncias NÃO entra: lá a correção é por município (recalcula o GP),
--  então não há o que travar.
--
--  Depende de: db/151, db/152, db/154, db/155, db/157 (tabelas *_demandas).
--  Idempotente: pode rodar mais de uma vez.
-- ────────────────────────────────────────────────────────────────────────

-- ─── 1) colunas de marcação da correção manual ───────────────────────────
alter table public.nuden_demandas      add column if not exists gp_manual_at timestamptz;
alter table public.nuden_demandas      add column if not exists gp_manual_por text;
alter table public.ddu_demandas        add column if not exists gp_manual_at timestamptz;
alter table public.ddu_demandas        add column if not exists gp_manual_por text;
alter table public.ri_demandas         add column if not exists gp_manual_at timestamptz;
alter table public.ri_demandas         add column if not exists gp_manual_por text;
alter table public.emergencia_demandas add column if not exists gp_manual_at timestamptz;
alter table public.emergencia_demandas add column if not exists gp_manual_por text;
alter table public.mc_demandas         add column if not exists gp_manual_at timestamptz;
alter table public.mc_demandas         add column if not exists gp_manual_por text;

-- ─── 2) função do trigger (genérica p/ as 5 tabelas) ─────────────────────
-- Preserva o trio de grupamento quando a linha está "travada" (gp_manual_at
-- preenchido) e o UPDATE atual não é uma nova correção manual (gp_manual_at
-- igual ao que já estava). Assim o sync não reverte; o painel, que sempre
-- renova gp_manual_at, continua podendo re-corrigir.
create or replace function public.preserva_grupamento_manual()
returns trigger
language plpgsql
as $$
begin
  if OLD.gp_manual_at is not null
     and NEW.gp_manual_at is not distinct from OLD.gp_manual_at then
    NEW.gp_responsavel      := OLD.gp_responsavel;
    NEW.grupamento_completo := OLD.grupamento_completo;
    NEW.fracao_responsavel  := OLD.fracao_responsavel;
    NEW.gp_manual_por       := OLD.gp_manual_por;
  end if;
  return NEW;
end;
$$;

-- ─── 3) trigger em cada tabela ───────────────────────────────────────────
-- Nome "…_zpreserva" só p/ garantir que roda DEPOIS do trg_*_touch (ordem
-- alfabética dos BEFORE UPDATE) — irrelevante p/ a lógica, mas determinístico.
drop trigger if exists trg_nuden_zpreserva_grp on public.nuden_demandas;
create trigger trg_nuden_zpreserva_grp before update on public.nuden_demandas
  for each row execute function public.preserva_grupamento_manual();

drop trigger if exists trg_ddu_zpreserva_grp on public.ddu_demandas;
create trigger trg_ddu_zpreserva_grp before update on public.ddu_demandas
  for each row execute function public.preserva_grupamento_manual();

drop trigger if exists trg_ri_zpreserva_grp on public.ri_demandas;
create trigger trg_ri_zpreserva_grp before update on public.ri_demandas
  for each row execute function public.preserva_grupamento_manual();

drop trigger if exists trg_emerg_zpreserva_grp on public.emergencia_demandas;
create trigger trg_emerg_zpreserva_grp before update on public.emergencia_demandas
  for each row execute function public.preserva_grupamento_manual();

drop trigger if exists trg_mc_zpreserva_grp on public.mc_demandas;
create trigger trg_mc_zpreserva_grp before update on public.mc_demandas
  for each row execute function public.preserva_grupamento_manual();

-- ─── 4) correção pontual das 2 NUDEN já revertidas ───────────────────────
-- Reaplica Águas Formosas e já deixa travado (gp_manual_at). Grafia do GP
-- vem da tabela grupos (match sem acento), então não hardcoda a grafia.
update public.nuden_demandas nd
   set gp_responsavel      = g.gp_responsavel,
       grupamento_completo = g.grupamento_completo,
       fracao_responsavel  = g.grupamento_completo,
       gp_manual_at        = now(),
       gp_manual_por       = coalesce(nd.gp_manual_por, 'db/184 (correção retroativa)')
  from public.grupos g
 where nd.codigo in ('2026.10.01.503.0000592', '2026.10.01.503.0000601')
   and translate(upper(g.gp_responsavel),
                 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','AAAAAEEEEIIIIOOOOOUUUUC')
       like '%AGUAS FORMOSAS%';

-- Conferência (rodar à mão depois, se quiser):
-- select codigo, municipio, gp_responsavel, gp_manual_at
--   from public.nuden_demandas
--  where codigo in ('2026.10.01.503.0000592','2026.10.01.503.0000601');

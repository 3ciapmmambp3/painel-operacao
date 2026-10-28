-- ══════════════════════════════════════════════════════════════════════
--  165 · MC — resolução robusta de grupamento por município (Opção B)
--
--  PROBLEMA: o órgão externo (SEMAD/empresa) manda alguns municípios com
--  grafia que não casa com a tabela municipios_grupos (via a view
--  vw_municipio_grupamento). A RPC mc_sync resolve o gp_responsavel com
--  match EXATO só dobrando acento (translate) — então "SEM-PEIXE"×"SEM PEIXE",
--  "ABRE-CAMPO"×"ABRE CAMPO" (hífen/espaço) e grafias trocadas
--  ("FELIZBURGO"×"FELISBURGO", "ITABIRINHA DE MANTENA"×"ITABIRINHA") entram
--  SEM grupamento no painel.
--
--  SOLUÇÃO (restrita ao MC): um gatilho BEFORE INSERT/UPDATE em mc_demandas
--  que, quando a linha chega SEM grupamento, resolve pelo município usando
--  normalização forte (ignora acento, espaço, hífen e pontuação) + aliases.
--  Assim NÃO precisa reescrever a função mc_sync e NÃO afeta os outros
--  módulos (nuden/ddu/ri/emergência). Também faz o BACKFILL das já existentes.
--
--  Idempotente. Rodar uma vez no Supabase (SQL editor).
--  Depende de: public.vw_municipio_grupamento (db/00) e public.mc_demandas (db/157).
-- ══════════════════════════════════════════════════════════════════════

-- 1) Normalização forte: MAIÚSCULAS, sem acento, só A-Z0-9 (tira espaço/hífen/pontuação)
create or replace function public.mc_muni_norm(p text)
returns text language sql immutable as $$
  select regexp_replace(
           translate(upper(coalesce(p, '')),
             'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'AAAAAEEEEIIIIOOOOOUUUUC'),
           '[^A-Z0-9]', '', 'g');
$$;

-- 2) Canônico: aplica os aliases de grafia do órgão externo → grafia oficial.
--    Compara já normalizado. Caso novo? Acrescente um WHEN aqui.
create or replace function public.mc_muni_canon(p text)
returns text language sql immutable as $$
  select case public.mc_muni_norm(p)
           when public.mc_muni_norm('FELIZBURGO')            then public.mc_muni_norm('FELISBURGO')
           when public.mc_muni_norm('ITABIRINHA DE MANTENA') then public.mc_muni_norm('ITABIRINHA')
           -- hífen vs espaço (SEM-PEIXE/SEM PEIXE, ABRE-CAMPO/ABRE CAMPO) já é
           -- tratado pela mc_muni_norm (remove tudo que não é A-Z0-9) — não
           -- precisa de alias.
           else public.mc_muni_norm(p)
         end;
$$;

-- 3) Gatilho: preenche o grupamento quando a linha MC entra/atualiza SEM ele.
--    Só age quando gp_responsavel está vazio — NUNCA sobrescreve um grupamento
--    já definido (inclusive correção manual do gestor).
create or replace function public.mc_fill_grupamento()
returns trigger language plpgsql as $$
declare
  v_gp  text;
  v_gpc text;
begin
  if NEW.gp_responsavel is null or NEW.gp_responsavel = '' then
    select v.gp_responsavel, v.grupamento_completo
      into v_gp, v_gpc
      from public.vw_municipio_grupamento v
     where public.mc_muni_norm(v.municipio_upper) = public.mc_muni_canon(NEW.municipio)
     limit 1;
    if v_gp is not null then
      NEW.gp_responsavel := v_gp;
      if NEW.grupamento_completo is null or NEW.grupamento_completo = '' then
        NEW.grupamento_completo := coalesce(v_gpc, v_gp);
      end if;
      if NEW.fracao_responsavel is null or NEW.fracao_responsavel = '' then
        NEW.fracao_responsavel := coalesce(v_gpc, v_gp);
      end if;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_mc_fill_grupamento on public.mc_demandas;
create trigger trg_mc_fill_grupamento
  before insert or update on public.mc_demandas
  for each row execute function public.mc_fill_grupamento();

-- 4) BACKFILL imediato das demandas MC que já estão SEM grupamento.
update public.mc_demandas d
   set gp_responsavel      = v.gp_responsavel,
       grupamento_completo = coalesce(nullif(d.grupamento_completo, ''), v.grupamento_completo, v.gp_responsavel),
       fracao_responsavel  = coalesce(nullif(d.fracao_responsavel,  ''), v.grupamento_completo, v.gp_responsavel)
  from public.vw_municipio_grupamento v
 where (d.gp_responsavel is null or d.gp_responsavel = '')
   and d.municipio is not null
   and public.mc_muni_norm(v.municipio_upper) = public.mc_muni_canon(d.municipio);

-- ─── Teste rápido ──────────────────────────────────────────────────────
-- select public.mc_muni_canon('ITABIRINHA DE MANTENA');  -- = ITABIRINHA
-- select public.mc_muni_canon('SEM-PEIXE');               -- = SEMPEIXE
-- select codigo, municipio, gp_responsavel from public.mc_demandas where gp_responsavel is null;

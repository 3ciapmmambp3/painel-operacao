-- db/182_corrige_metas_gdo_2026.sql
-- Corrige a DISTRIBUICAO MENSAL das metas da GDO Especializada 2026 (rural).
-- Fonte oficial: Caderno GDO 2026 / CGA-DOp (Tabelas 9 MV, 10 CVPE, 11 CVPA, 12 IF).
-- As metas mensais no banco estavam embaralhadas (import de 18/06/2026);
-- populacao_rural, meta_anual_taxa e meta_anual_abs JA estavam corretos -> nao sao tocados.
-- So atualiza meta_jan..meta_dez. Reversivel. Rodar no SQL editor do Supabase.
BEGIN;
-- MV
UPDATE gdo_especializada_metas SET meta_jan=2.86, meta_fev=2.86, meta_mar=1.23, meta_abr=2.45, meta_mai=3.68, meta_jun=3.27, meta_jul=3.27, meta_ago=2.25, meta_set=2.04, meta_out=3.48, meta_nov=2.66, meta_dez=3.07, atualizado_em=now() WHERE id=1; -- MV CIA1
UPDATE gdo_especializada_metas SET meta_jan=1.04, meta_fev=0.47, meta_mar=1.32, meta_abr=0.38, meta_mai=0.28, meta_jun=1.41, meta_jul=1.04, meta_ago=0.66, meta_set=1.04, meta_out=0.66, meta_nov=0.47, meta_dez=0.66, atualizado_em=now() WHERE id=2; -- MV CIA2
UPDATE gdo_especializada_metas SET meta_jan=1.23, meta_fev=0.98, meta_mar=1.17, meta_abr=1.23, meta_mai=1.11, meta_jun=1.78, meta_jul=1.05, meta_ago=1.23, meta_set=1.66, meta_out=1.41, meta_nov=1.29, meta_dez=1.60, atualizado_em=now() WHERE id=3; -- MV CIA3
UPDATE gdo_especializada_metas SET meta_jan=1.12, meta_fev=1.12, meta_mar=1.26, meta_abr=0.70, meta_mai=0.70, meta_jun=0.84, meta_jul=1.40, meta_ago=1.40, meta_set=1.40, meta_out=0.98, meta_nov=1.81, meta_dez=0.84, atualizado_em=now() WHERE id=4; -- MV CIA4
UPDATE gdo_especializada_metas SET meta_jan=0.72, meta_fev=0.52, meta_mar=0.52, meta_abr=0.52, meta_mai=0.62, meta_jun=0.72, meta_jul=0.52, meta_ago=0.72, meta_set=0.10, meta_out=0.62, meta_nov=0.93, meta_dez=0.31, atualizado_em=now() WHERE id=5; -- MV CIA5
UPDATE gdo_especializada_metas SET meta_jan=2.43, meta_fev=0.81, meta_mar=1.62, meta_abr=0.40, meta_mai=1.62, meta_jun=2.43, meta_jul=1.62, meta_ago=1.21, meta_set=1.21, meta_out=2.43, meta_nov=1.62, meta_dez=2.43, atualizado_em=now() WHERE id=6; -- MV CIA6
UPDATE gdo_especializada_metas SET meta_jan=1.06, meta_fev=1.42, meta_mar=1.77, meta_abr=1.06, meta_mai=0.35, meta_jun=0.71, meta_jul=1.77, meta_ago=1.06, meta_set=0.00, meta_out=0.35, meta_nov=2.13, meta_dez=1.06, atualizado_em=now() WHERE id=7; -- MV CIA7
-- CVPE
UPDATE gdo_especializada_metas SET meta_jan=2.86, meta_fev=3.05, meta_mar=2.10, meta_abr=1.34, meta_mai=3.05, meta_jun=2.29, meta_jul=2.86, meta_ago=2.10, meta_set=0.95, meta_out=0.38, meta_nov=1.34, meta_dez=2.86, atualizado_em=now() WHERE id=8; -- CVPE CIA1
UPDATE gdo_especializada_metas SET meta_jan=0.22, meta_fev=0.22, meta_mar=0.66, meta_abr=0.35, meta_mai=0.31, meta_jun=2.17, meta_jul=0.18, meta_ago=0.27, meta_set=0.09, meta_out=0.80, meta_nov=0.18, meta_dez=0.40, atualizado_em=now() WHERE id=9; -- CVPE CIA2
UPDATE gdo_especializada_metas SET meta_jan=1.29, meta_fev=0.91, meta_mar=1.49, meta_abr=1.29, meta_mai=1.10, meta_jun=1.23, meta_jul=1.42, meta_ago=1.42, meta_set=1.42, meta_out=0.78, meta_nov=1.10, meta_dez=1.42, atualizado_em=now() WHERE id=10; -- CVPE CIA3
UPDATE gdo_especializada_metas SET meta_jan=0.91, meta_fev=0.78, meta_mar=1.04, meta_abr=0.65, meta_mai=1.95, meta_jun=0.91, meta_jul=0.65, meta_ago=0.39, meta_set=1.82, meta_out=1.04, meta_nov=0.91, meta_dez=1.82, atualizado_em=now() WHERE id=11; -- CVPE CIA4
UPDATE gdo_especializada_metas SET meta_jan=0.40, meta_fev=0.40, meta_mar=0.55, meta_abr=0.55, meta_mai=0.32, meta_jun=1.82, meta_jul=0.48, meta_ago=0.24, meta_set=0.32, meta_out=0.32, meta_nov=0.40, meta_dez=0.40, atualizado_em=now() WHERE id=12; -- CVPE CIA5
UPDATE gdo_especializada_metas SET meta_jan=3.12, meta_fev=2.08, meta_mar=5.72, meta_abr=2.08, meta_mai=3.64, meta_jun=0.52, meta_jul=2.60, meta_ago=3.12, meta_set=3.64, meta_out=0.00, meta_nov=3.64, meta_dez=1.56, atualizado_em=now() WHERE id=13; -- CVPE CIA6
UPDATE gdo_especializada_metas SET meta_jan=1.94, meta_fev=1.94, meta_mar=1.29, meta_abr=1.61, meta_mai=1.61, meta_jun=1.61, meta_jul=0.97, meta_ago=1.94, meta_set=0.32, meta_out=1.94, meta_nov=0.97, meta_dez=1.61, atualizado_em=now() WHERE id=14; -- CVPE CIA7
-- CVPA
UPDATE gdo_especializada_metas SET meta_jan=14.77, meta_fev=16.51, meta_mar=12.69, meta_abr=11.30, meta_mai=9.04, meta_jun=10.95, meta_jul=14.77, meta_ago=9.21, meta_set=9.21, meta_out=8.52, meta_nov=11.65, meta_dez=9.91, atualizado_em=now() WHERE id=15; -- CVPA CIA1
UPDATE gdo_especializada_metas SET meta_jan=3.18, meta_fev=2.02, meta_mar=3.42, meta_abr=2.79, meta_mai=2.48, meta_jun=1.94, meta_jul=2.48, meta_ago=1.55, meta_set=2.25, meta_out=2.25, meta_nov=1.79, meta_dez=1.94, atualizado_em=now() WHERE id=16; -- CVPA CIA2
UPDATE gdo_especializada_metas SET meta_jan=3.24, meta_fev=4.03, meta_mar=3.02, meta_abr=2.07, meta_mai=2.44, meta_jun=3.55, meta_jul=3.98, meta_ago=2.97, meta_set=2.55, meta_out=3.13, meta_nov=2.49, meta_dez=2.55, atualizado_em=now() WHERE id=17; -- CVPA CIA3
UPDATE gdo_especializada_metas SET meta_jan=5.44, meta_fev=7.75, meta_mar=3.70, meta_abr=4.51, meta_mai=5.09, meta_jun=5.21, meta_jul=6.13, meta_ago=6.60, meta_set=4.17, meta_out=5.32, meta_nov=5.44, meta_dez=5.09, atualizado_em=now() WHERE id=18; -- CVPA CIA4
UPDATE gdo_especializada_metas SET meta_jan=6.39, meta_fev=4.74, meta_mar=4.81, meta_abr=5.46, meta_mai=3.30, meta_jun=3.81, meta_jul=5.89, meta_ago=4.53, meta_set=5.10, meta_out=4.17, meta_nov=5.03, meta_dez=5.10, atualizado_em=now() WHERE id=19; -- CVPA CIA5
UPDATE gdo_especializada_metas SET meta_jan=21.53, meta_fev=13.89, meta_mar=14.93, meta_abr=15.63, meta_mai=20.49, meta_jun=18.40, meta_jul=20.14, meta_ago=25.70, meta_set=14.59, meta_out=15.63, meta_nov=14.24, meta_dez=10.07, atualizado_em=now() WHERE id=20; -- CVPA CIA6
UPDATE gdo_especializada_metas SET meta_jan=9.07, meta_fev=4.69, meta_mar=4.07, meta_abr=2.50, meta_mai=2.82, meta_jun=3.75, meta_jul=3.44, meta_ago=6.57, meta_set=3.75, meta_out=2.19, meta_nov=5.63, meta_dez=9.70, atualizado_em=now() WHERE id=21; -- CVPA CIA7
-- IF
UPDATE gdo_especializada_metas SET meta_jan=140.14, meta_fev=128.07, meta_mar=140.59, meta_abr=139.47, meta_mai=148.86, meta_jun=134.78, meta_jul=140.14, meta_ago=139.25, meta_set=132.54, meta_out=124.05, meta_nov=126.73, meta_dez=121.14, atualizado_em=now() WHERE id=22; -- IF CIA1
UPDATE gdo_especializada_metas SET meta_jan=37.12, meta_fev=34.80, meta_mar=41.04, meta_abr=34.35, meta_mai=35.07, meta_jun=34.71, meta_jul=35.24, meta_ago=35.07, meta_set=30.25, meta_out=34.35, meta_nov=30.34, meta_dez=26.50, atualizado_em=now() WHERE id=23; -- IF CIA2
UPDATE gdo_especializada_metas SET meta_jan=29.10, meta_fev=27.35, meta_mar=25.40, meta_abr=28.77, meta_mai=28.32, meta_jun=27.48, meta_jul=28.64, meta_ago=26.83, meta_set=25.15, meta_out=24.17, meta_nov=23.85, meta_dez=22.94, atualizado_em=now() WHERE id=24; -- IF CIA3
UPDATE gdo_especializada_metas SET meta_jan=50.01, meta_fev=45.42, meta_mar=54.91, meta_abr=48.90, meta_mai=47.16, meta_jun=56.18, meta_jul=59.82, meta_ago=58.87, meta_set=57.13, meta_out=48.90, meta_nov=50.17, meta_dez=42.73, atualizado_em=now() WHERE id=25; -- IF CIA4
UPDATE gdo_especializada_metas SET meta_jan=73.11, meta_fev=61.91, meta_mar=66.33, meta_abr=65.15, meta_mai=64.36, meta_jun=60.82, meta_jul=64.95, meta_ago=65.84, meta_set=60.14, meta_out=69.96, meta_nov=67.80, meta_dez=60.33, atualizado_em=now() WHERE id=26; -- IF CIA5
UPDATE gdo_especializada_metas SET meta_jan=198.75, meta_fev=164.88, meta_mar=142.46, meta_abr=160.90, meta_mai=163.88, meta_jun=176.84, meta_jul=167.37, meta_ago=155.91, meta_set=139.48, meta_out=162.89, meta_nov=158.90, meta_dez=165.88, atualizado_em=now() WHERE id=27; -- IF CIA6
UPDATE gdo_especializada_metas SET meta_jan=80.12, meta_fev=77.37, meta_mar=74.62, meta_abr=72.21, meta_mai=77.03, meta_jun=64.30, meta_jul=66.37, meta_ago=73.24, meta_set=58.80, meta_out=63.27, meta_nov=62.58, meta_dez=68.09, atualizado_em=now() WHERE id=28; -- IF CIA7
COMMIT;

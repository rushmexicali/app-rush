-- Siembra UNA fila sintetica en `stg_cnt` para que el dry-run del import tenga
-- de verdad algo que insertar.
--
-- POR QUE EXISTE ESTE ARCHIVO (hallazgo del critico de completitud, 22/ago):
-- la prueba del dry-run corria sobre el `stg_cnt` real, que despues de un
-- import trae sus filas YA importadas. El dedup las descarta todas, asi que el
-- INSERT se ejercitaba con CERO filas y la asercion (`grep -q DRYRUN`) salia
-- igual con 0 que con 240. `pruebas/README.md` lo dice: una prueba que no puede
-- fallar no sirve.
--
-- Va concatenado ANTES del dry-run, en la MISMA transaccion: el `raise` final
-- del dry-run revierte tambien esta siembra, asi que no ensucia nada.
--
-- El nombre lleva un sufijo que ninguna persona real puede tener, y el ticket
-- es un numero que Zettle no ha alcanzado, para que el dedup por ticket no lo
-- confunda con una venta de verdad.
alter table public.stg_cnt add column if not exists tz text;

insert into public.stg_cnt (nombre, dt_local, es_gratis, monto_cent, ticket, tz)
values ('zz prueba dryrun 129', '2026-01-02 10:11:12', false, 26000, '99000001',
        'America/Tijuana');

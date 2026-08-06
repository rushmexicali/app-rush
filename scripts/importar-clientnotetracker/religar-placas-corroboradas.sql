-- =====================================================================
-- RE-LIGAR placas a clientes con CERTEZA ABSOLUTA (regla del dueno, 5/ago/2026).
-- "Solo liga placas de clientes con 2+ visitas y que puedas confirmar al 1000%."
--
-- Regla estricta = corroboracion independiente: una placa se liga a un cliente
-- solo si la MISMA placa fue leida en 2+ carros distintos de ese cliente (dos
-- fotos independientes coinciden). Eso descarta la foto-mal-pegada (que aparece
-- una sola vez). Marca confirmada=true, origen='corroborada'.
--
-- Idempotente: no duplica (unique persona_id, placa_norm). Correr tras cada import.
-- El historial de placas en `carros` NO se toca; esto solo (re)construye el vinculo
-- cliente<->placa en persona_placas.
-- =====================================================================
insert into public.persona_placas (persona_id, placa_norm, placa_como_se_lee, confirmada, origen)
select v.persona_id,
       public.normalizar_placa(coalesce(c.placa_display, c.placa)),
       (array_agg(coalesce(c.placa_display, c.placa) order by c.id desc))[1],
       true,
       'corroborada'
from public.visitas v
join public.carros c on c.id = v.carro_id
where v.persona_id is not null and c.placa is not null
  and not coalesce(c.es_prueba, false) and c.cancelado_en is null
group by v.persona_id, public.normalizar_placa(coalesce(c.placa_display, c.placa))
having count(distinct c.id) >= 2
on conflict (persona_id, placa_norm) do nothing;

select count(*) placas_ligadas, count(distinct persona_id) clientes
from public.persona_placas where confirmada;

# Despliegue pendiente — al CIERRE

> ⚠️ **Un solo `deploy` de `app` sube DOS cosas**, porque van en el mismo archivo:
> 1. El **obrero de relectura** de la migración `104` (esta guía).
> 2. El arreglo del **punto 4 de la auditoría**: que un error del backend se vea como
>    error (`marcarError` en el ayudante `json()`). Ya está probado —
>    `bash pruebas/correr.sh`, 14 casos— y no necesita ningún paso extra: en cuanto
>    la función suba, las 57 respuestas de error empiezan a traer `ok:false`.
>
> **Antes de desplegar, siempre:**
> ```bash
> bash pruebas/correr.sh && supabase functions deploy app --no-verify-jwt
> ```

---

## La parte del obrero de relectura (migración 104)

> La migración `104` **ya está aplicada** y NO cambia el comportamiento actual: la función `app`
> desplegada no manda `p_hubo_lectura` (el default es `true`) y el cron todavía no existe.
> Lo que falta es lo que sí se ve, y por eso va después de las 8 PM: toca `caja.html`.

## 1. El token de la tarea (una sola vez)

Se genera uno y **el mismo valor** va en los dos lados. Nunca en Git.

```bash
openssl rand -hex 32
```

- **Secreto de la función:** `supabase secrets set RELECTURA_TOKEN=<valor>`
- **Vault** (de donde lo lee el cron):
  `select vault.create_secret('<valor>', 'relectura_token');`

## 2. Desplegar back y front JUNTOS

```bash
supabase functions deploy app --no-verify-jwt
```

Luego commit + push de `docs/` (la app de la caja va en `sw.js` **v11**).

## 3. Probar el camino completo ANTES de agendar el cron

Se usa un carro real de un día **ya congelado**, para que la prueba ejercite también el
recongelado. Apuntar primero lo que tiene, por si hay que devolverlo:

```sql
select id, placa, placa_organizacion, marca, submarca, tipo_unidad, placa_intentos
from carros where id = <carro>;

update carros set placa_en = null, placa_intentos = 0, placa_intento_en = null
 where id = <carro>;
```

Disparar a mano (sin esperar al cron) y ver la respuesta:

```bash
curl.exe -s -X POST -H "x-tarea: <valor>" "https://rwoyfvddhlabmmuvkpjx.supabase.co/functions/v1/app/releer-pendientes"
```

Debe devolver `leidos: 1` y el día en `recongelados`. Comprobar que el carro quedó con la misma
placa que tenía y que el reporte de ese día subió su `con_placa`. Si algo sale mal, se restaura
con los valores apuntados.

## 4. Agendar el cron

```sql
select cron.schedule('releer-fotos-pendientes', '*/5 * * * *',
                     $$select public.releer_fotos_si_toca();$$);
```

⚠️ **La guardia va en la FUNCIÓN, no en el horario del cron** — mismo principio que
`sincronizar_jibble_si_toca` y `congelar_reporte`. Cuando la cola está vacía, `releer_fotos_si_toca`
es un `count` sobre el índice parcial y ni siquiera sale de la base.

## 5. Verificar al día siguiente

```sql
select jobid, jobname, schedule, active from cron.job;
select * from cron.job_run_details where jobid = <id> order by start_time desc limit 10;
select public.fotos_pendientes_del_rango(current_date - 7, current_date);
```

## Cómo revertir, si hace falta

```sql
select cron.unschedule('releer-fotos-pendientes');
```

Con el cron apagado, todo lo demás queda inerte: la vista y las funciones no las llama nadie, y
`p_hubo_lectura` tiene default `true`, o sea el comportamiento de antes.

# Pruebas — se corren ANTES de cada despliegue

```bash
bash pruebas/correr.sh
```

Sale con código 0 si todo pasó y 1 si algo falló, para poder encadenarlo:

```bash
bash pruebas/correr.sh && supabase functions deploy app --no-verify-jwt
```

## Por qué existe esto

La auditoría del 19/ago/2026 encontró 46 hallazgos, y al agruparlos por causa
salieron **cuatro patrones repetidos**, no 46 problemas distintos:

| Patrón | Casos |
|---|---|
| La misma regla escrita en dos lugares, que divergen en silencio | 6 |
| Un error que se responde como éxito | 5 |
| Trabajo a medio terminar que queda inerte sin fallar | 3 |
| Un dato viejo que envenena un cálculo | 2 |

**Ninguno de los cuatro se atrapa revisando mejor el código antes de subirlo.**
Los cuatro se atrapan con una prueba que corra sola. El proyecto ya tenía la
técnica —el bloque `do $$ … raise` contra la base real, que revierte al
terminar— pero se escribía a mano para cada cambio y **se tiraba después de
usarse**. Esta carpeta es donde dejan de tirarse.

## Las tres reglas de esta carpeta

1. **Una prueba no copia el código que prueba: lo EXTRAE.** `marcar-error.js`
   lee `marcarError` de `supabase/functions/app/index.ts` en cada corrida y le
   quita las anotaciones de tipo. Si alguien cambia la función, la prueba corre
   la versión nueva. Una copia sería exactamente el patrón #1 de la tabla, esta
   vez dentro de las pruebas.

2. **Una prueba que no puede fallar no sirve.** Antes de dar por buena una
   prueba nueva, hay que **romper el código a propósito** y confirmar que la
   prueba lo detecta. `marcar-error.js` se validó así: cambiando el umbral de
   400 a 500, cuatro casos fallaron y salió con código 1.

   > 🔴 **Y le pasó a esta misma suite, que es la mejor prueba de que la regla
   > hace falta.** El grupo del dry-run del import (agregado el 21/ago) corría
   > sobre `stg_cnt`, que **después de un import queda con sus filas ya
   > importadas**: el dedup las descartaba todas, el `INSERT` se ejercitaba con
   > **cero filas**, y la aserción era un `grep -q DRYRUN` que sale igual con 0
   > que con 240. Lo cachó el crítico de completitud de la auditoría del 22/ago.
   > Arreglado el 23/ago: `pruebas/dryrun-import.sh` **siembra una fila** en la
   > misma transacción que revierte y exige `visitas +[1-9]`. Medido: sin la
   > siembra el dry-run dice `visitas +0`, o sea que la aserción nueva sí lo
   > rechaza.
   >
   > 🔄 **Reapuntada el 28/ago:** ese día el import incremental quedó retirado
   > (cada import es borrón y cuenta nueva), así que la prueba ejercitaba un
   > archivo que ya nadie corre — la misma falla de fondo, otra vez: *medir el
   > camino equivocado se ve igual que pasar*. Ahora corre **`reset-total.sql`**
   > con su `raise notice` final convertido en `raise exception`, y exige que
   > importe personas y visitas, que ligue al menos un lavado, y que la
   > operación (`carros`) quede intacta. **Toma candados sobre `visitas` unos
   > 7 s**: se corre antes de desplegar, y desplegar va en el corte.
   >
   > ⚠️ Y de paso, el propio arreglo rompió el cierre de `correr.sh` (se comió
   > el bloque que cuenta los fallos, así que la suite salía con código 0
   > pasara lo que pasara). Se detectó porque **faltaba el banner `TODO PASO`**
   > al final. Al tocar `correr.sh`, comprobar siempre que el banner salga y que
   > el `if [ "$fallos" -eq 0 ]` siga ahí.

3. **Un falso positivo mata la suite.** Una prueba que grita por algo que en
   producción funciona se deja de correr a la semana, y entonces no protege
   nada. Cuando el arnés tenga una limitación (ver abajo), se documenta y se
   compensa en el arnés — nunca degradando el código real.

## Limitaciones del entorno, dichas de frente

**No hay `node` ni `deno` en esta máquina.** El único motor de JavaScript
disponible es el de Windows (`cscript //E:JScript`), que es de la época de
Internet Explorer. Eso obliga a dos concesiones, las dos en el arnés y ninguna
en el código de producción:

- **Le faltan `Array.isArray` y `Object.keys`.** `marcar-error.js` las rellena
  antes de evaluar la función extraída.
- **No acepta palabras reservadas como nombre de propiedad.** `st.delete(id)`
  —legal en cualquier navegador— le parece un error de sintaxis. Por eso
  `sintaxis-front.sh` renombra `.catch(` y `.delete(` sobre una **copia
  temporal** antes de pasarlas por el intérprete. Sin ese renombre, la prueba
  reprobaba `docs/index.html`, que lleva semanas funcionando en el taller.

Por lo mismo, `sintaxis-front.sh` sólo comprueba que las pantallas **parseen**.
El error `'document' is undefined` es el resultado esperado y correcto:
significa que el archivo está bien formado y llegó a ejecutarse.

## La que NO va en `correr.sh`: el respaldo

```bash
bash pruebas/respaldo-completo.sh
```

Recorre `/respaldo` entero contra la API real y comprueba que **cada tabla
entregue exactamente las filas que promete el manifiesto**. Son ~37,000
renglones y ~4 minutos, así que queda **fuera de la suite de despliegue** a
propósito: correrla antes de cada `deploy` costaría cinco minutos cada vez.
Se corre **cuando se toque `/respaldo`** y de vez en cuando por gusto.

Vale la pena leer por qué existe: el modo de falla que importa en un respaldo
no es que truene, es que **baje de menos y se vea completo**. Y eso fue justo
lo que encontró la primera vez que se corrió — PostgREST recorta en 1,000
filas sin avisar, así que las tablas con página de 2,000 bajaban 1,000 y se
detenían creyéndose enteras. `etapas` se respaldaba al 12%. Leyendo el código
no se veía.

## La otra que NO va en `correr.sh`: el front del supervisor, en un navegador

```bash
bash pruebas/front-supervisor/armar.sh
```

Levanta la pantalla del supervisor con un `fetch` falso y permite manejarla
con el wifi lento, colgado o caído. Tiene su propio `README.md` con las
perillas y con lo medido antes y después de cada arreglo.

Existe porque la auditoría del 21–22/ago declaró su propio límite así:
**«nadie ejecutó una sola pantalla en un navegador»**. Al ejecutarlos el
24/ago, **tres de sus cuatro hallazgos del front eran reales y uno no se
reprodujo** — y los tres reales son carreras que sólo salen con el wifi
lento, o sea que leyendo el código no se veían.

Queda fuera de la suite porque **no hay `node` ni `deno` en esta máquina**:
no se puede manejar un navegador sin una persona. Se corre **cuando se toque
`docs/index.html`**, igual que el respaldo.

## Qué falta agregar

Cada hallazgo de la auditoría debería acabar aquí como un caso permanente. Los
más valiosos, por orden:

- El contador de "encimados", con un carro cancelado en el escenario — el bug
  que hizo ver a dos personas saturadas durante 25 días.
- El canje sin saldo en la caja.
- Que `/cola` no se vacíe ante una respuesta que no sea una lista de carros.
- Que `editar_carro` no escriba nada si va a rechazar el guardado.
- Las reglas de clasificación (`es_lavado_express`, `lleva_aspirado`,
  `clase_de_gratis`) contra el catálogo real de Zettle.

Los que tocan la base se escriben con el patrón `do $$ … raise` que ya usa el
proyecto: arman el escenario contra la base real y lo revierten al terminar.

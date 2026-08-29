# Importar ClientNoteTracker → RUSH (personas + visitas + lealtad + gasto)

Guía completa y **repetible** para migrar el historial del app viejo
**ClientNoteTracker** al CRM nuevo. Pensada para re-correrse tal cual cuando
el dueño suba la **base real y definitiva** antes de arrancar en vivo.

Primera corrida: **27/jul/2026** — 13,312 visitas, 4,545 clientes, **913 gratis**,
$2,936,802 conciliados, **243 lavados gratis acumulados en 239 personas** a honrar.
Todo verificado (regla de gratis = UNIÓN CNT/Zettle, ver §1).

---

## 0. El mapa (qué es qué)

Hay **DOS fuentes** y una llave que las une:

1. **Export de ClientNoteTracker** (PDF): la lista de clientes + una "nota" por
   cada visita, con `Name / Time / Ticket:<numero>`. La palabra **GRATIS** en el
   ticket = se entregó lavado gratis. El campo `Note` viene vacío.
2. **Ventas de Zettle** (API `purchases/v2`): cada venta con `purchaseNumber`,
   `amount` (centavos) y sus `products`.

🔑 **El número de ticket de ClientNoteTracker == `purchaseNumber` de Zettle.**
Verificado (mismo número y misma hora). Por eso podemos traer el **monto** de cada
visita y validar los gratis.

⚠️ **Zettle arrancó en `purchaseNumber` 1 = 1-sep-2025.** Las visitas de
ClientNoteTracker de **ago-2025 son PRE-Zettle** (tickets 1,2,3,1623…) → NO tienen
monto. Rebanada chica.

---

## 1. Reglas (NO cambiar sin pensarlo — costaron cotejo)

- **es_gratis (UNIÓN — CNT O Zettle):** `es_gratis = 1` si la **nota de CNT** lo dice
  (contiene "gratis" o un typo a distancia de edición ≤2: grqatis, gtratis, grstis…;
  **"pendiente" NO cuenta**, se le guarda al cliente) **O** si la visita tiene match del
  mismo día (±3) con una compra de Zettle cuyo **producto se llama "Gratis"** (variante
  "6to Lavado", $0).
  - 🔴 **Por qué UNIÓN y no "Zettle manda":** la primera corrida usó "Zettle manda"
    (Zettle sobrescribe a CNT). ERROR: quitaba redenciones que la cajera SÍ anotó pero
    Zettle registró distinto (los 15 casos de "$50–$400"). Lo cachó el dueño con **Mario
    Torres** (ticket 25011, 25-jul: CNT="GRATIS", Zettle=$50 → se le quitó el canje y le
    sobró 1 gratis). La UNIÓN **agrega** los que la cajera olvidó (Zettle) **sin quitar**
    los que la cajera anotó (CNT). Cotejo CNT vs Zettle: 99.7% de acuerdo; los ~40
    desacuerdos se resuelven a favor del que diga "gratis".
- **Número de ticket:** normalizar **O → 0** (la cajera teclea la letra O por el 0,
  ej. `2O969`→20969) y tomar la corrida de dígitos más larga (`grqatis#6134`→6134).
- **Monto:** el `amount` de Zettle (centavos → pesos), **solo** con match del mismo
  día. Ticket que mapea a fecha lejana = mal escrito → sin monto (no se inventa).
  Además, si la visita es **gratis** pero Zettle NO la tiene como producto "Gratis"
  (gz≠1 → el número apunta a una venta pagada ajena) → **sin monto** (el lavado fue
  gratis; no se le atribuye ese pago). Los gratis reales (gz=1) conservan su $0/extra.
- **Fecha:** el `Time` es hora local **America/Tijuana**. Se guarda en 24h y en SQL
  se convierte: `dt_local::timestamp at time zone 'America/Tijuana'`.
- **Personas:** dedup por `normalizar_nombre` (minúsculas + sin acentos). Nombre =
  un solo campo (First+Last juntos). `origen='import'`, `visitas_seed=0`,
  `sellos_iniciales=0` (las visitas reales dan el conteo). Dos personas distintas con
  nombre idéntico se FUNDEN (sin teléfono/placa no hay forma de separarlas — decisión
  del dueño).
- **Overlap:** las visitas del periodo con webhook (≈19-jul en adelante) se **ligan**
  a su `carro` real por `ticket == purchaseNumber`.
- **Override manual (revisar si aplica):** Gabriel Rodriguez Valdez, ticket "6" del
  2026-04-25 = gratis (ticket ilegible, el dueño lo juzgó olvido). Vive en
  `staging.awk`. Quitarlo si en la base nueva no aplica.

---

## 2. Prerrequisitos / herramientas

- `pdftotext` (viene con Git): `C:\Program Files\Git\mingw64\bin\pdftotext.exe`.
- `gawk` (Git bash) — para `mktime` y Levenshtein.
- `.env` con `ZETTLE_API_KEY`, `ZETTLE_CLIENT_ID`, `SUPABASE_ACCESS_TOKEN`,
  `SUPABASE_PROJECT_REF`.
- Token de Zettle: `scripts/2-token-zettle.ps1 -Mostrar` (dura 2 h).
- SQL a la base: `POST https://api.supabase.com/v1/projects/<ref>/database/query`
  con `SUPABASE_ACCESS_TOKEN`. **Mandar el body como UTF-8 sin BOM** (WriteAllText +
  `--data-binary`), si no se mutilan los acentos.

Estos archivos: `staging.awk`, `import.sql`, este RUNBOOK.

---

## 2-bis. El camino corto (24/ago/2026) — tres comandos

Los pasos 3.1–3.7 y el §4 se derivaron a mano tres veces antes de que alguien los escribiera. Ya
están escritos, y **los tres scripts hacen exactamente lo que dice el resto de este archivo**:

```bash
# 1. PDF -> texto, Zettle, staging y lotes. SOLO LECTURA, no toca nada.
bash scripts/importar-clientnotetracker/preparar-import.sh <export.pdf> <carpeta>

# 2. Carga stg_cnt, la cuadra contra el archivo, MIDE la zona horaria contra
#    Zettle y limpia los tickets. Toca stg_cnt y NADA del CRM.
bash scripts/importar-clientnotetracker/cargar-staging.sh <carpeta>

# 3. El reset. Ensayalo primero (ver su encabezado: un raise exception y listo).
bash scripts/releer-fotos/q.sh scripts/importar-clientnotetracker/reset-total.sql
```

**El orden no es casual: los dos primeros no tocan el CRM.** Cuando se llega al 3, el staging ya
está cargado, medido y limpio, así que el borrado y el import van juntos en una sola petición y el
CRM no pasa ni un segundo vacío. Y antes del 3, siempre:

```bash
bash scripts/bajar-respaldo.sh "C:/Users/luis_/Desktop/respaldo-rush-AAAA-MM-DD"
```

> 🔑 **SIEMPRE ES BORRÓN Y CUENTA NUEVA. Ya no hay import incremental.** Decisión del dueño el
> 28/ago/2026, textual: *"Cada import de ahora en adelante será borrón y cuenta nueva siempre. Nada
> de actualizar la base de datos actual. Así nos evitamos problema."*
>
> El problema que evita: ese mismo día la app de la caja entró en uso real (16 visitas) **y la
> cajera siguió llenando el ClientNoteTracker en paralelo**. El dedup del incremental sólo compara
> contra `v.caja = 'import'`, así que una visita de la caja le es invisible y habría metido una
> **segunda** visita por el mismo lavado — sello doble, el bug de §11.35. El reset lo resuelve solo
> porque su `delete from public.visitas` no lleva `where`.
>
> `import.sql`, `import-incremental.sql` e `import-incremental-dryrun.sql` quedaron **con candado**:
> si alguien los corre, abortan con la razón escrita. El cuerpo viejo está en el historial de Git.
>
> ⚠️ Esto vuelve al CNT la **única** fuente de la lealtad. El reset ahora reporta
> `CAJA se borraron N visitas; M sin respaldo en el CNT` — si esa M no es ~0 después de cargar un
> export que ya cubra esos días, la cajera dejó de llenar el CNT y el reset está perdiendo datos
> reales.

El resto de este archivo explica **por qué** cada paso hace lo que hace. Se lee cuando algo no
cuadra, que es cuando de verdad importa.

## 3. Pasos

Sea `$W` una carpeta de trabajo. Todo intermedio vive ahí.

### 3.1 Export PDF → texto
```
pdftotext.exe -enc UTF-8 -layout "client_note_tracker_*.pdf" "$W/notas_utf8.txt"
```

🔴 **LA HORA DEL EXPORT NO ES DE FIAR: sale del TELÉFONO del dueño.** Las primeras líneas traen
`Timezone (…)`:

```
head -8 notas_utf8.txt | grep -i "timezone\|start date\|end date"
```

Todos los exports hasta el 17/ago/2026 decían **America/Tijuana**; el del **21/ago dijo
America/Ciudad_Juarez**, una hora adelante. **No fue que el app cambiara** — lo explicó el dueño
el 21/ago: *"mi teléfono se jodió con el horario y creo que eso causó el error"*. El ClientNoteTracker
escribe la hora con la zona del teléfono, así que ese encabezado puede decir cualquier cosa.

👉 **La regla, y no admite excepción: TODO se guarda en la hora de Tijuana.** El negocio está en
Mexicali y no hay un solo dato en este proyecto que viva en otra zona.

**Por eso la zona NO se toma del encabezado: se MIDE contra Zettle.** El ticket de cada nota es el
`purchaseNumber` de una venta cuya hora sí es confiable, así que el desfase se calcula y se
corrige. La columna `stg_cnt.tz` guarda la zona en que resultaron estar escritas las horas (no la
que diga el PDF), y el import convierte con `at time zone coalesce(s.tz,'America/Tijuana')`.

**Y hay un segundo cotejo, gratis: SIEMPRE se cierra a las 8 PM.** Si después de convertir
aparecen notas pasadas de las ~20:00 hora de Tijuana, el desfase está mal — no es que hayan
trabajado hasta tarde.

```sql
select count(*) as notas_despues_de_cerrar
from public.stg_cnt
where extract(hour from (dt_local::timestamp at time zone coalesce(tz,'America/Tijuana')
                         at time zone 'America/Tijuana')) >= 20;
```

**Cómo se verifica después de cargar** (debe dar ~0 min con la zona correcta):

```sql
with z as (select (public.detalle_venta(payload)->>'purchaseNumber') recibo,
                  creado_en from public.ventas)
select round(extract(epoch from ((s.dt_local::timestamp at time zone coalesce(s.tz,'America/Tijuana'))
                                 - z.creado_en))/60.0) dif_min, count(*)
from public.stg_cnt s join z on z.recibo = s.ticket group by 1 order by 2 desc limit 5;
```
Anota la línea donde empieza la sección de notas:
`NL = grep -n "^ *Notes *$" notas_utf8.txt` (la primera).

⚠️ **Si ese grep no encuentra nada, NO improvises: usa la primera línea `^Name:`.**
`-layout` acomoda el PDF en columnas y puede **pegar el encabezado `Notes` al final de una línea
`First name:`` (pasó el 15/ago/2026: `First name: zairy aguilar       Notes`). Además la palabra
"Notes" cae **a media lista de clientes**, no al final, así que ni siquiera partiéndola sirve como
corte. El corte correcto es donde empieza el primer bloque de nota de verdad:
```
NL = grep -n "^Name:" notas_utf8.txt | head -1
```
Con el corte mal puesto, `padron.awk` **trunca el padrón** y el diff reporta como "desaparecidas"
a personas que sí están. Comprueba siempre que `wc -l padron.tsv` sea del orden del total de
clientes (≈4,900 al 15/ago/2026), no menos.

### 3.2 Jalar Zettle con la bandera "Gratis"

**Atajo que funciona desde el 19/jul/2026: sacarlo de nuestra propia tabla `ventas`** en vez de
pegarle a la API. `ventas.payload` **es** el aviso crudo de Zettle, así que es la misma fuente sin
token de 2 horas ni paginación. Sólo hay que comprobar antes que no falte ninguna venta del
periodo — si la secuencia de `purchaseNumber` no tiene huecos, está completa:

```sql
with v as (select (public.detalle_venta(payload)->>'purchaseNumber')::bigint n,
                  (creado_en at time zone 'America/Tijuana')::date f
           from public.ventas
           where public.detalle_venta(payload)->>'purchaseNumber' ~ '^[0-9]+$')
select count(*) from (
  select generate_series(min(n), max(n)) g from v where f between :desde and :hasta
  except select n from v) h;   -- 0 = no falta ninguna
```

El 21/ago dio **27008..27264, 257 ventas, 0 huecos** para el 17–20/ago.

El TSV se arma con `purchaseNumber, amount, fecha, gz`, donde `gz=1` si algún producto se llama
`(?i)gratis` — igual que lo hacía el jalón de la API.

⚠️ Y **usa `detalle_venta(payload)`, nunca `payload->>'purchaseNumber'` a secas**: Zettle manda el
aviso envuelto en la llave `payload` unas veces y plano otras, y leer una sola forma devuelve
nulos en silencio (es el bug que la migración `115` le corrigió a `ventas_indexar` y la `118` al
ligado del import).

#### 3.2-bis  El jalón por la API (si algún día `ventas` no alcanza)  (PowerShell)
Paginar `purchases/v2` (cursor `lastPurchaseHash`), y por cada compra escribir
`purchaseNumber \t amount \t YYYY-MM-DD \t gz` donde `gz=1` si algún producto se
llama (regex `(?i)gratis`). → `$W/zettle_gratis.tsv`.
(Token con `2-token-zettle.ps1 -Mostrar`; endpoint
`https://purchase.izettle.com/purchases/v2?limit=1000[&lastPurchaseHash=…]`.)

### 3.3 Staging (una fila por visita)
```
awk -v nl=$NL -f staging.awk "$W/zettle_gratis.tsv" "$W/notas_utf8.txt" > "$W/staging_full.tsv"
```
Columnas: `nombre_norm  display  fecha_24h  es_gratis  monto_cent  ticket`.
Debe dar ~13,312 filas (una por bloque `Name:`, incluidas las sin ticket).

### 3.4 Cargar a stg_cnt  (PowerShell, en lotes de ~1500)
```sql
drop table if exists public.stg_cnt;
create table public.stg_cnt (nombre text, dt_local text, es_gratis boolean, monto_cent integer, ticket text);
```
Insertar `display, fecha_24h, es_gratis(true/false), monto_cent|null, ticket|null`, **más `tz`**.
La columna se agrega sola: `alter table public.stg_cnt add column if not exists tz text;` — los
tres scripts del import la crean si falta, así que no puede quedar a medias.

> 🔴 **`tz` NO es la zona que declara el PDF.** Aquí decía que sí, y contradecía al paso 3.1 —que
> dice justo lo contrario— desde el 21/ago. Como éste es el paso que de verdad se ejecuta, ganaba
> el equivocado. **`tz` es la zona en la que RESULTARON estar escritas las horas, medida contra
> Zettle.** El encabezado del export sale del teléfono del dueño y puede decir cualquier cosa: el
> 21/ago dijo `America/Ciudad_Juarez` porque *"mi teléfono se jodió con el horario"*.
>
> **El orden correcto es cargar, medir y luego corregir `tz`** (hay que tener los datos adentro
> para poder medirlos):
>
> 1. Cargar con `tz = 'America/Tijuana'`, que es la regla del proyecto y el caso normal.
> 2. Correr la consulta de desfase del paso 3.1 (`dif_min` contra `ventas`). Si el grueso de las
>    notas cae en **0**, ya está.
> 3. Si cae en **60** (o en otro número redondo), las horas venían de otra zona: se corrige con
>    `update public.stg_cnt set tz = '<la zona que explica el desfase>';` y se vuelve a medir hasta
>    que `dif_min` dé 0.
> 4. Cotejar además que **no queden notas después de las 8 PM** (paso 3.1). Ese solo cotejo habría
>    cachado el error del 21/ago: sin corregir, las últimas notas quedaban en 20:21 y 20:22.
>
> **Nada de esto se hace a ojo**: si el desfase no queda en 0, el import mete cada visita una hora
> tarde **y** el dedup de la siguiente tanda —que compara `creado_en` al segundo— deja de
> reconocerlas y las duplica.
Verificar: `select count(*), count(*) filter (where es_gratis), sum(monto_cent)/100
from stg_cnt;` — debe cuadrar con el staging.

### 3.5 Esquema (una sola vez)  → migración `078`
`alter table visitas add column if not exists monto numeric, add ... ticket text;`

### 3.6 Import
Correr `import.sql` (es idempotente: borra el import previo y reinserta).
Para **probar sin escribir**, meter `raise exception 'dry-run'` antes del `end $$;`.

### 3.7 Verificar
```sql
select count(*) v, count(*) filter (where es_gratis) g, round(sum(monto)) monto,
       count(*) filter (where carro_id is not null) ligadas
from visitas where caja='import';
select count(*) filter (where disponibles>0) personas, sum(disponibles) gratis
from lealtad_por_persona;
```
Comparar contra los conteos del staging. Si no cuadra, **no** seguir.

---

## 4. RESET / re-corrida con la base REAL (el caso del dueño)

> 🔴 **LO QUE DECÍA AQUÍ ERA UN RESET PARCIAL, Y ES JUSTO EL QUE EL DUEÑO RECHAZÓ.**
> Decía borrar sólo `visitas where caja='import'` y `personas where origen='import'`, dejando
> vivas las visitas de la caja, `persona_placas` y todas las tablas de trabajo. Textual del dueño
> el 21/ago/2026: *"Quiero borrar absolutamente todo y hacer un import de cero del CNT y ligar con
> las fotos que ya tenemos… no como la vez pasada que por decisión tuya no lo hiciste."*
> Corregido el 24/ago/2026.

Cuando llegue el export definitivo, el borrado es **completo**. Lo que hay hoy, medido el
24/ago/2026, para que se vea qué alcanza cada línea:

| Tabla | Filas | ¿Se borra en el reset completo? |
|---|---|---|
| `visitas` (`caja='import'`) | 15,050 | **Sí** |
| `visitas` (`caja='principal'`) | 21 | **Sí** ✅ (ver abajo) |
| `personas` (`origen='import'`) | 4,955 | **Sí** |
| `personas` (`origen='caja'`) | 2 | **Sí** ✅ (ver abajo) |
| `persona_placas` | 222 | **Sí** (se reconstruye con corroboración de 2+ carros) |
| `stg_cnt`, `stg_names`, `stg_padron` | 240 / 239 / 5,075 | **Sí** (son andamio de la corrida anterior) |
| `ren_*` (7 tablas) | 8 a 107 | **Sí** |
| `imp_ligado_conflictos` | 11 | **Sí** |
| `bak_*` (20 tablas) | — | ⛔ **NO** — se conservan (dueño, 24/ago/2026) |

✅ **La actividad de la caja también se va** (dueño, 24/ago/2026): *"Todo lo que se ha hecho de
caja es prueba meramente. Se borra toda actividad de caja al momento de hacer el import
definitivo."* O sea que las 21 visitas y las 2 personas de la caja entran al borrado — el borrado
de `visitas` y `personas` va **sin `where`**.

⛔ **Las tablas `bak_*` SE CONSERVAN** (dueño, 24/ago/2026: *"consérvalas"*). Son los respaldos de
los resets anteriores, y borrarlas **justo antes de la operación más destructiva del proyecto**
sería exactamente al revés: si el import definitivo sale mal, son lo único que queda del CRM
viejo. Ocupan poco y no estorban a nadie.

> 👉 **Con esto ya no queda ninguna pregunta abierta del reset.** Las cuatro decisiones (sin
> renombres, ligado por ticket, las dos reglas de placa, y los lavados dobles se revisan juntos)
> más ésta y la de la caja están todas contestadas. Falta únicamente el export.

⛔ **LO QUE NO SE TOCA NUNCA, porque es la OPERACIÓN y no el CRM:** `carros`, `etapas`,
`asignaciones`, `ventas`, `empleados`, `reportes_diarios` y las fotos de Storage. El CRM se
reconstruye; la operación no. Las placas que ya leyeron las fotos siguen ahí, y de ahí sale el
religado.

👉 **La regla de método, que es la que costó:** si veo una razón para conservar algo que él dijo
borrar, **la digo y él decide** — no la aplico solo. Las tres filas de ⚠️ arriba son exactamente
eso: no son del ClientNoteTracker, así que **hay que preguntárselas antes**, no decidirlas por él.

### El orden

```sql
-- 0) RESPALDAR ANTES. Sin esto no hay vuelta atras.
create table public.bak_personas_<fecha>       as select * from public.personas;
create table public.bak_persona_placas_<fecha> as select * from public.persona_placas;
create table public.bak_visitas_map_<fecha>    as select * from public.visitas;
```
Y además bajar el respaldo completo por **`/respaldo`** desde la página del dueño — ya baja las 11
tablas de verdad, no las 94 kB de antes (ver `CLAUDE.md §11.20`).

```sql
-- 1) El CRM, completo (con lo que el dueno haya confirmado de las filas ⚠️)
delete from public.visitas;          -- SIN where: la actividad de caja tambien se va (24/ago)
delete from public.persona_placas;
delete from public.personas;         -- SIN where: idem

-- 2) El andamio de la corrida anterior
drop table if exists public.stg_names, public.stg_padron;
drop table if exists public.ren_cand, public.ren_cand_ticket_0815,
                     public.ren_cand_ticket_descartado, public.ren_desaparecen,
                     public.ren_esqueleto, public.ren_nuevas, public.ren_prefijo;

-- ⛔ `imp_ligado_conflictos` NO se dropea. `ligar_visitas_de_import()` le hace
--    `delete` al empezar pero NO la crea: sin la tabla, el import entero truena.
--    Se limpia sola, asi que dropearla no gana nada y cuesta el import.
-- ⛔ `stg_cnt` tampoco, si ya viene cargada con el export nuevo: es el staging
--    que se esta por importar. Se recrea en el paso 3.4, no aqui.
-- ⛔ Las `bak_*` NO aparecen aqui a proposito: se conservan (dueno, 24/ago).
--    Si el import definitivo sale mal, son lo unico que queda del CRM viejo.
```

> 🔴 **El `drop table if exists public.imp_ligado_conflictos` estuvo escrito aqui hasta el
> 24/ago/2026, y habria tumbado el import completo.** Es la misma forma de falla que la migracion
> `114` produjo el 19/ago (§4e): un `do $$` sin manejador que revienta y no deja entrar **ni una**
> visita. Se encontro leyendo `pg_get_functiondef('ligar_visitas_de_import()')` **antes** de correr
> el reset, no ejecutandolo. 👉 **Antes de dropear una tabla de andamio, comprueba quien la lee.**

⚠️ **`visitas` tiene `carro_id`, y borrarlas NO toca los carros.** Es un enlace, no el carro: el
lavado, sus tiempos y su foto siguen igual. Lo que se pierde es *de quién era*, que es justo lo
que se va a reconstruir.

Luego rehacer los pasos **3.1–3.7** con el PDF nuevo y el jalón de Zettle nuevo, **con
`limpiar-tickets.sql` entre el 3.4 y el 3.6** (§4d).

> 💡 **Lo que funcionó el 24/ago y conviene repetir: cargar el staging ANTES de borrar, y mandar el
> borrado y el import en UNA sola petición.** La API de administración corre cada petición en una
> transacción implícita, así que si el import truena el borrado se revierte solo — y el CRM nunca
> se queda vacío entre dos peticiones. Ensayarlo antes es gratis: el mismo archivo con un
> `raise exception` al final da los números finales sin escribir nada.

### 🚩 EN LA CORRIDA FINAL **NO HAY RENOMBRES** (decisión del dueño, 24/ago/2026)

Textual: *"Ya no habrá renombres. El export completo que te daré será para borrar absolutamente
todos los clientes y hacer la base desde 0 con los nombres que ya se tienen."*

Y tiene toda la lógica: **un renombre sólo existe cuando hay un "antes" contra el cual comparar.**
En un borrón y cuenta nueva no lo hay — el padrón del export **es** la verdad, tal como está. Así
que en esa corrida:

- ⛔ **NO se corre `diff-renombres.sql` ni `aplicar-renombres.sql`.**
- ⛔ **NO aplican §4a (punto de renombres), §4c ni §4c-bis.** Se quedan escritas porque sí valen
  para los imports **incrementales** de después, cuando ya haya un padrón contra el cual diferir.
- ✅ Sí se conserva **§4d** (tickets mal tecleados y repetidos): eso no compara contra un padrón
  anterior, compara contra Zettle, y sigue haciendo falta.

### 🚩 Cómo se ligan los clientes, y la política de placas (reafirmada el 24/ago/2026)

El dueño: *"con nuestra base de datos y placas y tickets ligadas, podemos ligar a los clientes con
los números de tickets que hay en el CNT"*. Eso es exactamente lo que hace
`ligar_visitas_de_import()` (§4e): empata **por número de ticket** contra `ventas`, y de ahí sale
el carro — con su placa ya leída por la foto y su hora real.

La política de **placa ↔ cliente** tiene **dos reglas distintas**, y la diferencia no es capricho:

| De dónde viene | Qué se necesita | Por qué |
|---|---|---|
| **Nuestro programa de caja** (en vivo) | **Se confirma A LA PRIMERA** | El cliente está enfrente, la cajera lo escoge por su nombre y la cámara fotografía **ese** carro en ese momento. La asociación se **presencia**, no se infiere |
| **Import del ClientNoteTracker** | La **misma placa en 2+ carros** distintos del cliente | Aquí el vínculo se **infiere** de una foto que se pudo haber pegado al carro equivocado — y una foto mal pegada **también** produce una sola coincidencia |

✅ **Comprobado el 24/ago contra la base real: el código ya hace las dos.** La prueba permanente es
`pruebas/placa-caja-confirma-a-la-primera.sql`, ya en `pruebas/correr.sh`.

> ⚠️ **Y hay que probarlo porque el mecanismo es SUTIL.** La caja llama a
> `ligar_placa_a_persona(..., 'foto', false)` — o sea pidiendo *no* confirmar — y aun así queda
> **confirmada**. El motivo: `registrar_visita_con_carro` guarda la placa en `visitas.placa`
> **antes** de ligarla, `visitas.placa_norm` es columna **generada** sobre esa, y
> `ligar_placa_a_persona` confirma cuando *"la persona ya trae esta placa en alguna visita"*. Si
> alguien invierte el orden de esas dos escrituras, **la regla del dueño se rompe en silencio**.

### 🚩 Los lavados que dos clientes reclaman: se revisan juntos

Quedan en `imp_ligado_conflictos` con su motivo, **no se adjudican al azar**. Al terminar el
import se le presentan al dueño (*"los lavados dobles lo revisamos"*, 24/ago/2026). Donde no hay
evidencia, el lavado **se queda sin dueño**: adivinar al 50% y dejarlo escrito como un hecho es
peor que dejarlo vacío (§9 del `CLAUDE.md`).

### Antes de correrlo, releer estas dos

1. **§3.1 — la zona horaria del export.** Sale del teléfono del dueño y ya cambió una vez. Se
   **mide** contra Zettle y se carga en `stg_cnt.tz`; el cotejo de "nunca hay notas después de las
   8 PM" la confirma gratis.
2. **§4e — el ligado vive en `ligar_visitas_de_import()`**, una sola función. No copiarlo.

---

## 4a. RENOMBRES y PLACAS — política del dueño (5/ago/2026)

Las cajeras **editan nombres en CNT** (agregan segundo apellido, corrigen typos). Eso
rompía el dedup del incremental —que empareja personas por `nombre_norm`—: un nombre
editado entraba como **persona nueva** y **partía** al cliente en dos (historia y lealtad
divididas). Al 5/ago ya había 79 clientes partidos así.

**Reglas nuevas (obligatorias en cada import de actualización):**

1. **NO se fusiona en automático.** Cada import produce un **diff** para que el dueño
   **autorice** los merges. Lo arma `diff-renombres.sql`, que llena tres tablas:
   - `ren_cand` — merges/renombres **sugeridos** con alta confianza (detección por ticket).
   - `ren_desaparecen` — personas en la base que ya no están en el padrón y que el diff
     **no** explicó (revisar a mano; casi siempre son renombres con ticket ambiguo).
   - `ren_nuevas` — nombres del padrón que no están en la base y no son destino de un
     renombre (clientes nuevos reales).
2. **La detección de renombres usa solo tickets LIMPIOS.** Un ticket vale para deducir un
   renombre solo si en el export mapea a **un** nombre y en la base pertenece a **una**
   persona. 🔴 Sin esto, los tickets chicos/pre-Zettle compartidos (ej. el ticket `1`, que
   mapea a ~200 nombres) inventan renombres falsos en masa (decenas de personas
   "→Rogelio Valdivia"). Se cayó en esto el 5/ago y se corrigió antes de aplicar.
3. **Aplicar solo lo autorizado:** revisado `ren_cand`, correr `aplicar-renombres.sql`
   (reasigna visitas+placas del duplicado al registro con historia, borra el duplicado,
   renombra). Solo `visitas` y `persona_placas` referencian `personas.id`.
4. **Placas: religado ultra-conservador.** El vínculo cliente↔placa (`persona_placas`) se
   religa con `religar-placas-corroboradas.sql`: una placa se liga a un cliente **solo si
   la MISMA placa fue leída en 2+ carros distintos de ese cliente** (corroboración
   independiente; descarta la foto-mal-pegada). Marca `confirmada=true`,
   `origen='corroborada'`. El **historial de placas en `carros` NO se toca**.

**El reset del 5/ago (lo que se hizo una vez):** se desligaron TODAS las placas
(`delete from persona_placas`, 966), se reconstruyó la lista de clientes para que coincida
exacto con el export (92 renombres/fusiones aplicados, 9 basura sin visitas borradas), se
importó 4-5 ago (+81 visitas, +20 personas) y se religaron 47 placas corroboradas. Respaldo
en `bak_personas_0805`, `bak_persona_placas_0805`, `bak_visitas_map_0805`.

**Herramientas nuevas:** `notas-ticket.awk` (ticket→nombre actual), `padron.awk` (lista
autoritativa), `diff-renombres.sql`, `aplicar-renombres.sql`, `religar-placas-corroboradas.sql`.

### El flujo de un import de actualización (con la política nueva)
```
1. pdftotext export.pdf → notas_utf8.txt ; NL = primera linea "^Name:"  (ver 3.1)
2. gawk -v nl=$NL -f notas-ticket.awk notas_utf8.txt → ticket_nombre.tsv  → cargar stg_names(ticket,display)
   gawk -v nl=$NL -f padron.awk       notas_utf8.txt → padron.tsv        → cargar stg_padron(display)
3. diff-renombres.sql  → ren_cand / ren_desaparecen / ren_nuevas
3b. CRUCE POR PREFIJO (el que de verdad encuentra los renombres, ver 4c)
4. PRESENTAR al dueño y ESPERAR autorización de lo que no sea prefijo estricto.
5. (autorizado) aplicar-renombres.sql
6. staging normal (3.2 Zettle, 3.3 staging.awk) → stg_cnt
6b. COTEJO DE TICKETS MAL TECLEADOS (ver 4d) — ANTES de importar
7. reset-total.sql          (era import-incremental.sql; retirado el 28/ago/2026)
8. religar-placas-corroboradas.sql
9. Cotejo final: visitas por día en la base == filas por día del staging_full.tsv
```

---

## 4c. El renombre se detecta por PREFIJO DE PALABRAS, no por ticket (15/ago/2026)

`ren_cand` (detección por ticket) resultó **inútil y peligrosa** en el import del 15/ago: dio 2
candidatos y **los 2 eran falsos**, disparados por tickets mal tecleados (§4d). El 17/ago volvió a
pasar: **1 candidato, también falso** (`MIGUEL ANGEL RODRIGUEZ`→`EDGAR AYON`, ticket `25786`). Van
**3 de 3 falsos**; trátala como sospechosa por defecto. Lo que sí funciona es cruzar las dos listas
que el propio diff ya produce:

```sql
create table public.ren_prefijo as
select d.id old_id, d.nombre old_nombre, d.nombre_norm old_norm, d.visitas,
       n.display new_nombre, n.nombre_norm new_norm
from public.ren_desaparecen d
join public.ren_nuevas n on n.nombre_norm like d.nombre_norm || ' %';
```

✅ **Desde el 17/ago esto ya vive dentro de `diff-renombres.sql`** (paso 4), junto con los tres
contadores de control. Ya no hay que escribirlo a mano.

### 🔴 4c-bis. El prefijo tiene DOS puntos ciegos, y los dos cuestan clientes partidos (17/ago/2026)

El cruce por prefijo del 4c **no encuentra la mayoría de los renombres**, y el 17/ago se reportó
—mal— que 13 clientes habían "desaparecido sin destino". El dueño lo corrigió de memoria:
*"No fueron borrados, se les agregó el segundo apellido"*. Tenía razón. Los dos huecos:

1. **Solo mira `ren_nuevas`, que EXCLUYE a quien ya existe como persona.** Si la cajera creó la
   ficha corregida en un export **anterior**, ese nombre ya entró a la base en el import pasado y
   el prefijo no lo ve **nunca**. `GABRIELA COLLINS VARGAS` se creó el 9/ago y `HECTOR FIGUEROA
   DAUTO` el 7/ago: los dos ya eran personas cuando corrió el diff del 17.
2. **Exige prefijo EXACTO, así que un typo corregido lo rompe.** La cajera no solo agrega el
   apellido: de paso **arregla la ortografía**. `hector figeroa`→`HECTOR FIGUEROA DAUTO` y
   `gabriela colins`→`GABRIELA COLLINS VARGAS` no son prefijo de nada.

**El arreglo (paso 5 de `diff-renombres.sql`, tabla `ren_esqueleto`): comparar el ESQUELETO DE
CONSONANTES contra TODAS las personas.** Se quitan vocales y `h`, y las letras repetidas se
aplastan:

```
colins / collins   -> clns
figeroa / figueroa -> fgr
henri / henrri     -> hnr
```

Se pide que un esqueleto **contenga** al otro (por palabras) y 2+ palabras, así que además caza
los **reordenes**: `Arizona Guadalupe Ramos` ↔ `GUADALUPE RAMOS ARIZONA`. El 17/ago encontró
**14 de 20** desaparecidos, contra 4 del método viejo.

⚠️ **Es una LISTA PARA EL DUEÑO, no se aplica sola** — a diferencia del prefijo, no tiene un
criterio de "tres ceros" que la haga segura:
- **Da falsos:** `ARTURO CONTRERAS` → `VICENTE ARTURO CHAVARI CONTRERAS`.
- **Da ambiguos:** `JAVIER MEZA` empata con `JAVIER CHAVEZ MEZA` **y** `JAVIER MONTAÑO MEZA`.
  La columna `candidatos_del_viejo` los marca; con 2+ candidatos siempre se pregunta.
- **Y no lo caza todo:** una letra cambiada de verdad rompe el esqueleto
  (`KIANA ASCURO` → `KIANA ASPURO`, `scr` vs `spr`). Ésos siguen apareciendo como sin candidato,
  así que la lista de "sin destino" **nunca es prueba de que la ficha se borró**.

O sea: **el nombre viejo es prefijo exacto por palabras del nuevo** (la cajera agregó apellido).
El 15/ago dio **70 pares** con:

- `viejos_ambiguos = 0` y `nuevos_ambiguos = 0` → el emparejamiento es **1 a 1**.
- `choca_con_persona_existente = 0` → el nombre nuevo **no existe** como persona, así que es un
  **renombre puro**: no se fusiona ni se borra a nadie, solo se actualiza `nombre`/`nombre_norm`.

**Esos tres ceros son la condición para aplicarlo sin preguntar.** Si alguno no da cero, ese caso
se le presenta al dueño. Se aplican metiéndolos en `ren_cand` y corriendo `aplicar-renombres.sql`
(con `choca_id = null`, que hace que el script solo renombre). Respaldar antes en
`bak_personas_<fecha>`, `bak_persona_placas_<fecha>`, `bak_visitas_map_<fecha>`.

**Lo que este cruce NO atrapa, y hay que presentar aparte:** los clientes **partidos en el
origen** — el nombre viejo **sigue** en el padrón *y además* hay ficha nueva con el apellido
completo. Ahí CNT tiene dos fichas de la misma persona (20 casos el 15/ago). Se detectan cruzando
las personas creadas por el import contra las viejas, con el mismo `like ... || ' %'`.
🔴 **No fusionar por parecido:** el 15/ago se buscó corroboración por placa y **ninguno de los 20
compartía placa**; en 3 las placas eran **distintas**, o sea que bien podían ser homónimos. Regla
del dueño: **1000% o nada**. Eso se arregla en caja, no aquí.

---

## 4d. Cotejo obligatorio: tickets mal tecleados (15/ago/2026)

Un número de ticket mal escrito que **colisiona con un ticket viejo** hace daño en dos lados a la
vez, y los dos en silencio:

1. **El dedup del incremental descarta la visita nueva.** Si esa visita era un **canje gratis**,
   el cliente conserva un sello que ya usó → el negocio regala un lavado de más. El 15/ago pasó
   **dos veces** (Dennis Bosquez con el ticket `22658`, de junio; Astrid Mascareño con el `391`,
   de sep/2025 — los dos eran canjes).
2. **`diff-renombres.sql` inventa un merge falso**, porque cree que ese ticket cambió de dueño.

⚠️ **Y hay un tercer caso:** dos filas del **mismo** export con el mismo ticket **entran las dos**
(el `not exists` se evalúa contra la tabla previa, no contra lo que se está insertando). El 15/ago
el ticket `26258` quedó en dos visitas; **Zettle desempata por fecha** (era del 8/ago, así que era
de Leonel Gallardo, no de Arturo Coronel, cuya nota es del 7/ago) — al otro se le quita el ticket
**y el monto**, si no se cuenta el mismo dinero dos veces.

✅ **Desde el 24/ago/2026 esto ya es un script: `limpiar-tickets.sql`.** Hace los tres cotejos y
resuelve cada uno con la misma regla —se descarta el **ticket**, nunca la visita— y revienta si al
terminar queda algún ticket repetido. Es **idempotente** (correrlo dos veces reporta 0/0/0), así
que se corre siempre, sin decidir nada a mano. En el reset del 24/ago quitó **443** marcadores
`0`–`5`, **70** números que Zettle no tiene y **196** repetidos (los 6 empates exactos se quedan sin dueño: nadie conserva el ticket).

⚠️ **El orden importa y está fijado adentro:** los repetidos se resuelven **al final**. Si (C)
corriera primero, los 281 marcadores `1` se pelearían entre sí y 280 saldrían "perdedores" de un
desempate que no significa nada.

Las consultas de abajo siguen sirviendo para **mirar** qué va a pasar antes de aplicarlo:

Correr **antes** del import:

```sql
-- (a) tickets del export que ya existen con fecha ANTERIOR = mal tecleados
select s.nombre, s.dt_local, s.ticket, s.es_gratis, p.nombre as duena_de_la_vieja
from stg_cnt s
join visitas v on v.caja='import' and v.ticket = s.ticket
join personas p on p.id = v.persona_id
where (v.creado_en at time zone 'America/Tijuana')::date < (s.dt_local::timestamp)::date;

-- (b) tickets repetidos DENTRO del propio export
select ticket, count(*), string_agg(nombre || ' @' || dt_local, ' | ')
from stg_cnt where ticket is not null group by ticket having count(*) > 1;
```

**Qué hacer:** la visita **sí va** (el cliente vino de verdad); lo que se descarta es el **ticket**
(y su monto, que apunta a una venta ajena). Nunca al revés.

⚠️ **Y un tercer cotejo que faltaba (17/ago/2026): tickets que NO EXISTEN en Zettle.** El export
traía `27927` cuando el máximo de Zettle era `27046` — o sea un número al que Zettle **todavía no
llega**. Hoy no colisiona con nada, así que ningún cotejo lo atrapa; pero dentro de unas semanas
Zettle sí va a emitir ese número, y entonces el dedup de un import futuro va a descartar la visita
buena creyéndola repetida. **Es una mina con fecha.** Se descarta igual:

```sql
select nombre, dt_local, ticket from stg_cnt
where ticket is not null and monto_cent is null and not es_gratis;
```

**Y no se adivina el número correcto**, aunque se vea obvio. El 17/ago los tres descartados tenían
un candidato evidente por la secuencia horaria (los tickets suben con la hora): `27927`→`26927` y
`26907`→`26909`, los dos libres y encajando entre sus vecinos. Se dejaron **sin ticket** de todos
modos, y se le reportó la hipótesis al dueño. Costo: $530 de gasto sin atribuir en 2 visitas de
14,810. Inventar un número es exactamente el error que este proyecto ya pagó caro.

---

## 4e. 🔴 El LIGADO vive en UNA función, y por qué (21/ago/2026, migración `118`)

**El candado que se puso el 19/ago mató al import el mismo día, y el CRM pasó CINCO DÍAS sin
registrar una sola visita** (17 al 21/ago): 248 lavados sin sello y 35 gratis entregados sin
descontar.

Cómo: la migración `114` creó el índice único `visitas_un_lavado_un_cliente` — un lavado no puede
estar a nombre de dos clientes. El paso de ligado del import hacía un `update ... set carro_id`
**sin preguntar si ese carro ya tenía visita activa**, chocaba con el índice, y como el import es
un `do $$` sin manejador **se caía el bloque entero: no entraba NI UNA visita**. El encabezado de
la propia `114` ya decía que al import le faltaba esa comprobación; lo que faltaba era ponérsela.

Ahora el ligado es **`public.ligar_visitas_de_import()`** y quien importa la llama. Antes el mismo
`update` estaba **copiado tres veces** (`import.sql`, `import-incremental.sql` y el dryrun) — tres
copias de la misma regla es exactamente como se desfasan las cosas en este proyecto.

> Desde el 28/ago/2026 el único que la llama es **`reset-total.sql`**: los otros tres quedaron con
> candado (§2-bis). Que el ligado ya viviera en una sola función es lo que hizo barato retirarlos —
> no hubo que tocar ni una línea de esa lógica.

Los tres candados que pone, uno por cada error ya pagado:

| | Qué hace | Por qué |
|---|---|---|
| **a** | El número de venta sale de `detalle_venta()` | Los scripts leían `(payload->>'payload')::jsonb->>'purchaseNumber'`, o sea **sólo el aviso envuelto**. Zettle también lo manda plano, y esas ventas se quedaban sin ligar **en silencio**. Mismo error que la `115` le corrigió a `ventas_indexar` |
| **b** | Un carro que ya tiene visita activa **no se toca** | La regla de la `114`, ahora preguntada ANTES de escribir en vez de descubierta al chocar |
| **c** | Si dos visitas se pelean el mismo carro, gana **una** y de forma determinista: la más cercana en el tiempo a ese carro | Es el mismo criterio de "Zettle desempata por fecha" del §4d. En la base ya hay 164 tickets reclamados por dos clientes, así que el empate no es hipotético |

Y el `update` va en su propio sub-bloque con manejador: **si aun así chocara se pierden los
ENLACES, nunca las VISITAS**. Un enlace se rehace; una visita que no entró hay que volver a
sacarla del export.

**Lo que no se liga queda ANOTADO, no descartado en silencio** (la lección de la `108`): la tabla
**`public.imp_ligado_conflictos`** dice carro, visita, ticket, cliente y motivo. Revísala después
de cada import:

```sql
select motivo, count(*) from public.imp_ligado_conflictos group by 1;
```

El 21/ago dejó **11**: 9 "dos visitas se pelean el mismo lavado" y 2 "ese lavado ya está asignado
a otro cliente", **todos de visitas viejas** (jul y principios de ago), ninguno del export nuevo.

⚠️ **A propósito NO llama a `enlazar_visita_a_carro`**, aunque esa función ya trae la comprobación.
Además escribe `carros.cliente`, la foto y la placa **de la visita** sobre el carro, y una visita de
import no trae nada de eso: le pisaría al carro el nombre que puso la cajera en su nota. El import
liga; no reescribe el carro.

**Se prueba**, y ésa es la otra mitad del arreglo: `pruebas/import-cnt.sql` está en
`pruebas/correr.sh`. Reproduce el bug viejo contra producción antes de comprobar el nuevo — si esa
primera parte dejara de reventar, la prueba avisa que dejó de medir el bug. La suite también corre
el **dry-run de verdad** (revierte por diseño), que es la única forma de ejercitar el archivo
completo en vez de una copia de su lógica.

> ⚠️ **Trampa de SQL que salió midiendo esto, y que vale para cualquier consulta del proyecto:**
> `creado_en >= (date '2026-08-17' at time zone 'America/Tijuana')` **NO** es "desde la medianoche
> de Mexicali". Postgres castea la `date` a `timestamptz` y aplica la conversión al revés, así que
> el corte queda en **2026-08-16 17:00 UTC** — casi 7 horas antes. Contando lavados, eso metió 87
> carros de más y me hizo reportar 407 donde eran 248. La forma correcta es
> `(creado_en at time zone 'America/Tijuana')::date >= date '2026-08-17'`.

---

## 4b. INCREMENTAL — ⛔ RETIRADO EL 28/ago/2026, NO SE USA

> **Ya no se corre. Cada import es borrón y cuenta nueva (§2-bis).** El dedup de abajo sólo mira
> `v.caja = 'import'`, así que no ve las visitas de la app de la caja y duplicaría los sellos.
> Los tres archivos abortan si alguien los corre. Todo lo que sigue en esta sección se conserva
> como historia: describe cómo dedupeaba, que es el punto de partida si algún día el
> ClientNoteTracker deja de llenarse en paralelo y hay que revivirlo — **arreglándole el dedup
> primero**.

En vez del RESET (borrar todo y re-importar), en el flujo en vivo el dueño sube un
export **de los días nuevos** (o del día, filtrado con Start/End date en el app) y
solo se agrega lo que falta, **sin duplicar**:

1. Extraer el PDF nuevo → texto (3.1), jalar Zettle (3.2), staging (3.3).
2. `truncate stg_cnt` y cargar SOLO el export nuevo (3.4).
3. Correr **`import-incremental.sql`** (NO borra; agrega solo lo que no exista ya).
   Dedup: una visita ya está si hay un import con **el mismo ticket**, o con la
   **misma persona + misma hora** (`creado_en`). Cubre notas sin ticket.
4. Dry-run opcional: `inc_dryrun` (mismo cuerpo + `raise`) dice cuántas agregaría.

Probado (27/jul/2026): la 1a export tenía hoy hasta 18:05; la 2a (solo hoy, hasta
19:17) traía 105 notas → **96 duplicados detectados, 10 nuevos agregados**, 13,312→
13,322. Idempotente: re-correr agrega 0. El padrón del export siempre viene completo;
las notas son las date-filtradas.

**Dry-run:** correr `import-incremental-dryrun.sql` (mismo cuerpo + `raise`, revierte)
para ver `visitas +N / personas +N / ligadas` antes de escribir. Luego el real.

5. ⛔ **OBSOLETO desde el 5/ago/2026 — NO correr este bloque.** La política del dueño
   (§4a punto 4) es **1000% o nada**: el vínculo cliente↔placa solo se crea con
   corroboración de 2+ carros (`religar-placas-corroboradas.sql`, paso 8). Este bloque
   crea enlaces **sugeridos** de una sola foto, que es justo lo que el reset del 5/ago
   borró (966 placas). Se deja escrito solo para que nadie lo reviva por error.
   Comprobado el 15/ago: `persona_placas` tiene 123 filas, **todas** `confirmada` y
   `origen='corroborada'`, 0 sugeridas.

   ⛔ **Y el helper de la migración `086` TAMPOCO se corre — decisión del dueño del
   21/ago/2026.** Es el bloque que propaga a `persona_placas` la placa de los carros ya
   ligados a una visita, como **sugerida** (`ligar_placa_a_persona(..., 'foto', false)`):

   ```sql
   -- ⛔ NO CORRER. Se deja escrito para que nadie lo reviva por error.
   do $$ declare r record; begin
     for r in select v.persona_id, coalesce(c.placa_display, c.placa) as p
                from public.visitas v join public.carros c on c.id=v.carro_id
               where v.estado='activa' and c.placa is not null and v.persona_id is not null
     loop perform public.ligar_placa_a_persona(r.persona_id, r.p, 'foto', false); end loop;
   end $$;
   ```

   **Qué pasó:** el 21/ago se corrió porque este RUNBOOK lo mandaba, y `persona_placas`
   pasó de **166 a 1,671 filas** — 1,452 sugeridas de golpe. El 29/jul había agregado 131
   y por eso nadie había visto la escala. Se le presentó al dueño y contestó **quitarlas:
   sigue mandando "1000% o nada"**. Se borraron (quedaron 213 confirmadas + las 6
   sugeridas que ya existían de antes).

   👉 **El único camino para ligar placa↔cliente en el import es
   `religar-placas-corroboradas.sql`** (paso 8): la MISMA placa leída en **2+ carros
   distintos** del cliente. Una sola foto no basta, aunque el carro ya esté ligado —
   porque una foto mal pegada también produce una sola coincidencia.

   La memoria `placa-de-foto-al-cliente-sugerida` sigue siendo válida **para el camino en
   vivo** (lo que lee el supervisor o teclea la cajera, que sí entra como "por
   confirmar"). Lo que quedó prohibido es hacerlo **en masa desde el import**.

## 5. Números de la 1a corrida (27/jul/2026) — para comparar

- Visitas: **13,312** (913 gratis, $2,936,802, 575 ligadas a carro).
- Personas: **4,545** import (+ 1 caja de prueba = 4,546).
- Lealtad acumulada a honrar: **243 gratis en 239 personas**.
- Top gasto: Felipe Castañeda $23,395 (77 visitas). Cuadra.
- ~5.5% de visitas sin monto (tickets ilegibles / pre-Zettle) — piso, no total.

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

## 3. Pasos

Sea `$W` una carpeta de trabajo. Todo intermedio vive ahí.

### 3.1 Export PDF → texto
```
pdftotext.exe -enc UTF-8 -layout "client_note_tracker_*.pdf" "$W/notas_utf8.txt"
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

### 3.2 Jalar Zettle con la bandera "Gratis"  (PowerShell)
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
Insertar `display, fecha_24h, es_gratis(true/false), monto_cent|null, ticket|null`.
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

Cuando llegue el export definitivo y haya que "borrar lo actual y subir lo real":

```sql
-- 1) Borrar TODO lo importado (no toca lo de la caja en vivo ni los carros)
delete from public.visitas  where caja  = 'import';
delete from public.personas where origen = 'import';
-- (opcional) limpiar seeds viejos de carros.cliente que no sean personas:
-- delete from personas where origen='import' and nombre in ('CORTESIA', ...);
```
Luego rehacer los pasos 3.1–3.7 con el nuevo PDF y el nuevo jalón de Zettle.
`import.sql` ya hace el `delete where caja='import'` al inicio, así que re-correrlo
es seguro aunque se olvide el paso 1.

⚠️ **NO** borrar `visitas` con `caja <> 'import'` (esas son de la caja en vivo) ni
los `carros`/`ventas` (historial de operación). El import solo vive en
`origen='import'` / `caja='import'`.

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
7. import-incremental.sql
8. religar-placas-corroboradas.sql
9. Cotejo final: visitas por día en la base == filas por día del staging_full.tsv
```

---

## 4c. El renombre se detecta por PREFIJO DE PALABRAS, no por ticket (15/ago/2026)

`ren_cand` (detección por ticket) resultó **inútil y peligrosa** en el import del 15/ago: dio 2
candidatos y **los 2 eran falsos**, disparados por tickets mal tecleados (§4d). Lo que sí funciona
es cruzar las dos listas que el propio diff ya produce:

```sql
create table public.ren_prefijo as
select d.id old_id, d.nombre old_nombre, d.nombre_norm old_norm, d.visitas,
       n.display new_nombre, n.nombre_norm new_norm
from public.ren_desaparecen d
join public.ren_nuevas n on n.nombre_norm like d.nombre_norm || ' %';
```

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

---

## 4b. INCREMENTAL — agregar solo los días nuevos (RECOMENDADO en vivo)

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

   **Propagar placas al CRM (migración `086`).** Las visitas nuevas que quedaron
   ligadas a un carro con placa de foto deben alimentar `persona_placas` (si no, la
   placa se queda en el carro y no llega a caja/búsqueda). El import inserta visitas
   directo (no pasa por `enlazar_visita_a_carro`), así que hay que correr el helper a
   mano — es idempotente (solo agrega sugeridas nuevas y auto-confirma repetidas):
   ```sql
   do $$ declare r record; begin
     for r in select v.persona_id, coalesce(c.placa_display, c.placa) as p
                from public.visitas v join public.carros c on c.id=v.carro_id
               where v.estado='activa' and c.placa is not null and v.persona_id is not null
     loop perform public.ligar_placa_a_persona(r.persona_id, r.p, 'foto', false); end loop;
   end $$;
   ```
   Probado 29/jul: +131 enlaces placa↔cliente de los carros nuevos. Ver la memoria
   `placa-de-foto-al-cliente-sugerida`.

## 5. Números de la 1a corrida (27/jul/2026) — para comparar

- Visitas: **13,312** (913 gratis, $2,936,802, 575 ligadas a carro).
- Personas: **4,545** import (+ 1 caja de prueba = 4,546).
- Lealtad acumulada a honrar: **243 gratis en 239 personas**.
- Top gasto: Felipe Castañeda $23,395 (77 visitas). Cuadra.
- ~5.5% de visitas sin monto (tickets ilegibles / pre-Zettle) — piso, no total.

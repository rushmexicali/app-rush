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

5. **Propagar placas al CRM (migración `086`).** Las visitas nuevas que quedaron
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

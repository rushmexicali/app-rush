# Pendientes por hacer — se trabajan DESPUÉS del cierre (8 PM)

> Este archivo es la bandeja de entrada. Nada de aquí se toca mientras el autolavado esté
> abierto: cualquier despliegue a medio turno le puede tumbar la app al supervisor.
> Cuando algo se hace, se mueve al `CLAUDE.md` con su razón y se borra de aquí.

---

## 🔬 AUDITORÍA COMPLETA DEL 19/ago/2026 — 46 hallazgos

Siete revisiones en paralelo sobre todo el código (base, API, las tres pantallas, funciones de fondo,
costos). **Nada se tocó: fue de solo lectura.** Lo marcado ✔ se comprobó a mano contra la base de
producción, no solo se leyó.

> **El patrón de fondo, que es lo que hay que arreglar de verdad.** Los 46 hallazgos son cuatro
> causas repetidas: **regla duplicada que divergió** (6), **error que se responde como éxito** (5),
> **trabajo a medio terminar** (3) y **dato viejo que envenena un cálculo** (2). Ninguna se atrapa
> leyendo mejor el código; las cuatro se atrapan con una **suite de regresión que se corra antes de
> cada despliegue**. Ver el último punto.

### 🔴 Rompen algo hoy

1. ✔ **El contador de "encimados" lleva 25 días mintiendo sobre dos personas.** La CTE `encimados`
   de `reporte_del_rango` no filtra `cancelado_en`. Los carros **515 y 516** (24/jul, cancelados al
   descontrolarse la cola, `entregado_en` nulo) tienen asignación a **Jorge Luna** y **Jaime
   Gallegos**, y los dejan "ocupados para siempre". Medido el 16/ago: Jorge 7/7 (100%) → **1/10
   (10%)**; Jaime 6/6 → **1/9 (11%)**. Acumulado: **201 de 935 encimados son falsos (21%)**.
   🔴 **Invalida lo escrito en §11.65 y §11.75** sobre esas dos personas ("es posición o forma de
   asignar", "su secado no se puede comparar contra el de nadie", "el mejor dato del fin de semana
   estando siempre saturado"). **No estaban saturados.**
   *Arreglo:* `and c2.cancelado_en is null and not c2.es_prueba`; cerrar 515/516; re-congelar desde
   el 26/jul (solo cambia `encimados`, el secado no).
2. ✔ **La caja puede regalar un lavado y quitarle al cliente el que sí ganó.**
   `registrar_visita_con_carro` **no verifica saldo**; la vieja `registrar_visita` **sí** — regla
   duplicada divergente. `lealtad_por_persona` tapa el descubierto con `greatest(0, …)`. Hoy hay
   **26 personas con canjes > ganados** (déficit 31 sellos), todas del import, pero el camino sigue
   abierto. **Decisión del dueño**: ¿se rechaza o pasa y queda anotado?
3. ✔ **Un error 500 vacía la cola en pantalla Y apaga el aviso.** `docs/index.html:1311`
   `carros = d.carros || []` seguido de `avisarError(false)`. El supervisor lee "No hay carros en
   proceso" sin señal de falla, y al volver el servicio los 15 carros vuelven a sonar como nuevos.
4. ✔ **Los errores del backend no llevan `ok:false`, y los tres fronts los leen como éxito.**
   401/500/400/405/503. En caja: "listo, siguiente cliente" con la visita sin registrar (la fuga de
   lealtad reintroducida por el **formato** de la respuesta). En supervisor: "Entregado" se cierra
   como si hubiera funcionado. *Arreglo de una línea:* que `json()` agregue `ok:false` cuando
   `status >= 400` — cubre las 33 rutas.
5. **El perfil de Trabajadores muestra minutos fabricados como medidos.** `perfil_de_secador` no
   excluye `cerrado_automaticamente` ni secados < 3 min, que el resto del reporte sí excluye.
   Visibles hoy: carro 2164 = **298 min** (Saul Ramirez), 2121 = **180 min** (Jaime Gallegos). Y 99
   carros históricos de < 3 min salen como "0/1/2 min". Es la pantalla donde se evalúa a una persona.

### ⏰ Bombas con fecha

6. ✔ **El obrero de relectura (104) NUNCA ha corrido.** Falta desplegar `app`, crear
   `relectura_token` en Vault y agendar el cron. `placa_intentos = 0` en los 2,654 carros. Y
   `/fotos-pendientes` da 404, que el reporte lee como cero: **la alerta no aparecería nunca.**
   👉 Es trabajo mío a medio terminar. Pasos en `scripts/releer-fotos/DESPLIEGUE-104.md`.
7. ✔ **`limpiar-fotos` nunca ha borrado nada; su primera corrida real son ~7,400 archivos.** 21
   corridas, 0 archivos (la más vieja tiene 31 días, el umbral 90). Primera real ~**17/oct/2026**:
   ~15 tandas en una invocación contra el límite de tiempo. Si se corta, quedan ligas muertas.
   *Arreglo:* tope por corrida y **probarlo antes de octubre**.
8. ✔ **Storage es el límite que se rompe primero.** 251 MB hoy, +8.5 MB/día → **765 MB en régimen
   (77% de 1 GB)**. A 150-200 carros/día **no cabe**. Bajar la retención de 90 a 60 días lo deja en
   510 MB — decisión del dueño (¿para qué sirven las fotos viejas?).
9. ✔ **Un 200 con lista vacía de Jibble marca a TODA la plantilla como "fuera".** El guard solo
   cubre el fallo duro. Y un `id` nulo desactiva la barrida entera: `'a' <> all(array['b',null])`
   devuelve **NULL**, no true (verificado en la base), así que nadie se marca fuera nunca.

### 🔒 Seguridad

10. ✔ **`anon` ejecuta 7 funciones `SECURITY DEFINER` y lee las 5 vistas.** Entre ellas
    `olvidar_fotos_viejas` (con `p_dias:=0` deja sin foto a todos los carros) y
    `sincronizar_empleados`. Las vistas no son `security_invoker`, así que brincan RLS:
    `historial_placas` (placas+clientes+dinero de 2,641 carros) y `lealtad_por_persona` (4,919
    saldos). **Atenuante: la llave `anon` NO está en el repo.** *Arreglo:* `revoke execute` +
    `security_invoker=on`. No afecta a la app (usa `service_role`).
11. **Un solo código abre las tres apps.** El del supervisor alcanza `/respaldo` (todo el
    histórico), `/personas` (4,871 con teléfono), `/tickets` (todas las ventas) y editar clientes.
    Vive en el `localStorage` de un teléfono que rota entre turnos.
12. **El webhook de Zettle no verifica la firma.** La URL se deduce del repo público → se pueden
    **inyectar ventas falsas**. NO puede cancelar carros reales (el `purchase_uuid` nunca sale por
    la API), NO duplica (unique) y NO lee datos. `ZETTLE_SIGNING_KEY` ya está guardada sin usarse.

### 📊 Números que no cuadran (reporte del dueño)

13. **En el día en curso el desglose suma más que el total.** "Vehículos lavados" cuenta entregados;
    "con/sin aspirado" cuenta todos. Hoy: titular **25**, desglose **29**. En días congelados cuadra
    → el error **solo aparece cuando se mira el día en curso**.
14. **El encabezado de sección no cuadra con su tabla, y el faltante es la señal.** El 11/ago:
    encabezado **22 carros**, tabla **15**. Los 7 que faltan son los que nunca se asignaron — el
    peor día de abandono del mes, y la pantalla no lo dice.
15. **"Secado promedio general" mezcla express con completos**, lo que el resto del reporte prohíbe.
    13/ago 29.8 min (39% express) contra 17/ago 39.8 min (24%): los extremos son la mezcla, no el
    taller.
16. **Rechazos, `rechazos_por_secador` y `cancelados` se calculan y nunca se pintan.** La `083` dice
    textualmente de los cancelados *"que no desaparezcan en silencio"* — y desaparecen.

### 🔧 Backend

17. ✔ **`editar_carro` escribe antes de validar.** El `update` va ANTES de los tres checks de
    secadores, y un `return` en plpgsql **no revierte**: el color se guarda aunque el guardado
    "falle" por dejar 0 secadores.
18. **`guardar_datos_de_foto` borra lo que viene nulo**, contradiciendo la "aceptación parcial por
    campo" de §9: una re-toma que no saca marca **borra la marca buena anterior**. Con el botón
    "tomar foto otra vez" (103) esto se dispara solo.
19. ✔ **`/foto` no limpia `placa_en`** al subir foto nueva, así que una re-toma **nunca** entra a la
    cola de reintentos (`fotos_por_leer` exige `placa_en is null`). Justo el flujo de las pickups.
20. ✔ **`buscar_tickets` tiene dos sobrecargas** y la llamada de 2 argumentos revienta con `42725`.
    La `098` agregó en vez de reemplazar — la lección exacta de la `052`. *Arreglo:* `drop` la vieja.
21. **`trabajadores()` y `perfil_de_secador()` cuentan rechazos con `count(*)`**; el reporte con
    `count(distinct grupo)`. Un rechazo con 2 motivos dará 2 en un lado y 1 en el otro (bug de la
    `036`, arreglado solo en el reporte).
22. **7 sitios desenvuelven `payload` a mano** en vez de usar `detalle_venta()`. Ya hay **2 ventas
    invisibles** para `buscar_tickets`, `tickets_recientes` y `ticket_detalle` (su carro sí se creó).
23. **El webhook descarta en silencio** por tres caminos (cuerpo ilegible, JSON inválido, sin
    `purchase_uuid`): responde 200 y el único rastro son logs de ~1 día que nadie mira.
24. **`crear_carro_desde_venta` no tiene `exception when others`**: un error en el trigger **tumba
    la venta completa**. Es la lección de §7 un nivel más abajo.
25. **Menores:** falta índice en `asignaciones(empleado_id)` (3 funciones hacen seq scan) e índices
    trigram para las búsquedas; `encimados` escanea toda la historia (18 ms/día consultado, crece
    cuadrático); `cerrar_pendientes` no alcanza carros creados después de las 20:30;
    `enlazar_visita_a_carro` escribe placa cruda y brinca el candado de la `100`; `desenlazar_visita`
    borra la foto y el `cliente` que puso la nota de caja; no hay unique parcial en
    `visitas(carro_id) where estado='activa'`; `iniciales_de` repite (Jaime Gallegos y Jesús Gil = JG);
    `sincronizar-jibble` no tiene candado (a diferencia de `limpiar-fotos`);
    **`Gratis`+`6to Express` ya son 10 casos, no 5.**

### 📱 Estabilidad del supervisor

26. **Ninguna petición tiene timeout.** Una colgada deja **todos los botones muertos y mudos**; la
    única salida es cerrar y reabrir, y nada lo sugiere. La misma falta mata la cola de fotos toda la
    sesión (el mutex nunca se suelta).
27. **Sin red, la cola congelada se ve viva**: los relojes siguen corriendo y las tarjetas se ponen
    rojas con datos viejos. El aviso solo sale si la cola está vacía.
28. ✔ **El `wakeLock` nunca se vuelve a pedir**: `candado` no se re-inicializa a `null`, así que tras
    el primer minimizado la pantalla se apaga sola el resto del turno.
29. ✔ **`escapar()` divergió**: `index.html:970` es el único de los tres sin la guarda de nulos.
30. **Del rechazo no hay regreso** (solo "Cancelar", que cierra todo) — posible causa de que la
    pantalla lleve 25 días sin uso. Fuga de temporizador en el desglose en vivo. Re-tomar una foto
    mientras se sube la anterior puede perder la nueva.

### 💰 Costos (medidos)

31. ✔ **El `CLAUDE.md` documenta mal el gasto de Anthropic por 5.4×.** Medido con `count_tokens`
    sobre una foto real: **3,101 tokens de entrada**, no 1,698. Real: **$17.80 USD/mes**, y
    **$26.70 desde el 1/sep** al terminar el precio de introducción. A 200 carros/día, $61. También
    está mal el peso de la foto: **100 KB**, no 150.
32. **Los dos crones por minuto son el mayor desperdicio**: 44% del CPU de la base, 24% de las
    invocaciones, 4,800 llamadas/día a Jibble para refrescar 19 personas. A cada 5 min: −46,600
    invocaciones/mes y −80% de las llamadas. En dinero, $0 (el plan gratis aguanta).
33. **NO tocar, con su razón:** el sondeo de 3 s (medido **5,939 llamadas/día reales, no 28,800** —
    el navegador estrangula el temporizador; bajarlo ahorra $0; **el disparador a vigilar es un
    segundo teléfono**); las 20 tablas `bak_*`/`stg_*`/`ren_*` (5.4 MB = 1% del límite, y son la
    evidencia de las fusiones autorizadas a mano); los índices (**no hay ninguno sin uso**); la
    resolución de la foto (ahorraría $9/mes empeorando la lectura de placa, que viene en su peor mes).

### ✅ Lo que se comprobó que está bien (para no volver a auditarlo)

- ✔ **0 ventas perdidas: 2,690 tickets consecutivos (24504→27193), sin un solo hueco.**
- ✔ **0 corridas de cron fallidas** en 74,995. Latencia del webhook: 1.21 s promedio.
- ✔ **`/cola` está sana**: `Index Scan`, 0.14 ms, 6 buffers. No crece con el histórico.
- ✔ **Las 3 columnas generadas en sincronía**: 0 desviaciones en 2,641 carros.
- ✔ **El congelado resiste el cambio de horario**: 365 días, 0 duplicados, 0 huecos en 2026.
- ✔ **0 índices muertos**, 0 degenerados. La `057` quedó bien.
- ✔ **La fuga de lealtad de esta bandeja ya está CERRADA** y **`sw.js` ya tiene el `if (r && r.ok)`**.
  Los dos pendientes viejos se pueden tachar.
- ✔ 0 etapas negativas, 0 asignaciones abiertas de carros entregados, 0 express fuera de la línea 1.
- ✔ Ninguna función `SECURITY DEFINER` con `search_path` suelto. Sin secretos en `docs/`.
- ✔ `leerFoto` distingue bien "miré y no vi" de "no alcancé a mirar". Es la parte mejor construida.

### 🎯 Orden sugerido

1. `ok:false` automático cuando `status >= 400` (#4) — **una línea, mata la clase entera**.
2. Encimados + re-congelar desde el 26/jul (#1) — desbloquea la analítica por persona.
3. Que la cola no mienta (#3, #26, #27).
4. Terminar el despliegue de la 104 (#6) — hoy la cola está en cero.
5. Cerrar permisos de `anon` (#10).
6. Decidir la regla del canje sin saldo (#2) y la del `6to Express` (#25).
7. Tope al borrado de fotos y probarlo antes de octubre (#7).

### 🧪 Y lo único que evita que esto se repita

**Una suite de regresión que se corra antes de cada despliegue.** El proyecto ya tiene la técnica
(el bloque `do $$ … raise` contra la base real, que revierte al terminar), pero se escribe a mano
para cada cambio y **se tira después de usarse**. Juntarlas convierte cada hallazgo de esta
auditoría en una prueba permanente: la próxima vez que alguien duplique una regla o rompa un
cálculo, lo dice la máquina y no la operación tres semanas después. Es el único punto de la lista
que no arregla un error sino **la razón por la que aparecen**.

---

## 📊 DEL CIERRE DEL 17–18/ago/2026 (hecho el 19/ago) — lo nuevo

Análisis completo en `CLAUDE.md §11.60`. Aquí sólo lo que espera trabajo o decisión.

### 🔴 La lectura de placa se puede caer y NADIE se entera

El 17/ago, de **16:40 a 18:20**, 17 carros seguidos subieron foto y **nunca se intentó leerla**
(`placa_en` nulo, y placa/marca/submarca en nulo). Es la razón completa del 69% de placa de ese
día. Se midió todo agosto: **0 casos todos los días menos ése**. No es un bug crónico; es un
evento sin alarma.

Dos cosas separadas que decidir:

- ✅ **RESUELTO, mejor que con una alarma (19/ago, migración `104`).** El dueño pidió que se
  arreglara **solo**, no que avisara. Ya hay un obrero de fondo que relee las fotos pendientes en
  cuanto vuelve el servicio, corrige el bloque `placas` del reporte congelado y liga la placa al
  cliente. El contador en el reporte se quedó, pero como señal de problema permanente, no como
  alarma. Ver `CLAUDE.md §11.55`.
  - ⏳ **PENDIENTE DE DESPLEGAR** (19/ago): la migración ya está aplicada y no cambia el
    comportamiento actual. Falta subir la función `app`, `caja.html`/`reporte.html`, poner el
    secreto `RELECTURA_TOKEN` y agendar el cron. Va **al cierre**, porque toca `caja.html`.
- ✅ **HECHO el 19/ago — recuperadas.** Se releyeron **24 carros** (los 17 de la caída + 7
  sueltos desde el 29/jul); **21 sacaron placa**. El 17/ago pasó de 69% a **88%** de placa, y
  `foto sin intento de lectura` quedó en **0 en toda la base**. Se re-congelaron los 4 días
  tocados conservando `congelado_en` (el diff campo por campo confirmó que sólo cambia el bloque
  `placas`). La herramienta quedó en `scripts/releer-fotos/` con su README.
- 🔵 **Causa raíz: no se sabe.** Los logs de Edge Functions ya no cubren el 17/ago. Si vuelve a
  pasar y hay alerta, se puede mirar en caliente.

### ❓ Se suma a las preguntas al dueño

- 🟠 **`6to Express` ya va por la séptima vez.** Dos casos nuevos: carros **2607** (17/ago) y
  **2694** (18/ago). Total: 1547, 2208, 2211, 2290, 2590, 2607, 2694 — todos contados como
  completo con aspirado y mandados fuera de la línea 1. La pregunta sigue siendo la misma y sin
  respuesta.
- 🟠 **La caja nueva sigue en cero.** Las únicas dos visitas por `caja='principal'` del 17–18 son
  la prueba de la cámara Reolink, y quedaron descartadas. **22 lavados gratis vendidos** en esos
  dos días, **0 registrados como canje.**

### 🟢 Lo que salió bien y no necesita nada

0 rechazos, 0 devoluciones, 0 cerrados automáticamente, 0 placas repetidas, 41/41 express en la
línea 1, nota de caja 100%/98%. Los olvidos bajaron a 7–8% (el mejor nivel medido).

### ✅ HECHO el 19/ago — se deshizo la prueba de la cámara sobre `Guillermo Lara Torres`

Ver `CLAUDE.md §11.60`. Se le quitó la placa `9VYE404` (que es de un cliente recurrente real),
se descartaron sus dos visitas de prueba y los carros 2643/2649 volvieron a quedar sin cliente.
**Las fotos y la placa del carro se conservaron**: se verificaron contra la imagen y la cámara
había sacado el carro correcto las dos veces.

---

## 📊 DEL ANÁLISIS DEL 4–14/ago/2026 (hecho el 15/ago) — lo que necesita decisión

El análisis completo está en `CLAUDE.md §11.75`. Aquí sólo lo que espera respuesta o trabajo.

### ✅ RESUELTO — 20 clientes partidos en el CNT: NO se fusionan (decisión del dueño, 15/ago/2026)

**El dueño decidió dejarlos como están.** No se fusionan ni ahora ni en imports futuros. Encaja
con su propia regla de *1000% o nada*: no hay evidencia de que sean la misma persona (ninguno
comparte placa, y en 3 las placas son distintas), y fusionar por parecido de nombre es
exactamente el error que la política del 5/ago existe para evitar.

⚠️ **Regla para el próximo import: estos casos se REPORTAN, no se preguntan otra vez.** Ya están
decididos. Solo vale volver a sacarlos si aparece corroboración de verdad — la misma placa leída
en carros de las dos fichas —, y ahí ya no sería fusionar por parecido.

El detalle de los 20 queda abajo como referencia.

#### (Referencia) Los 20 casos

El import 6–14/ago ya está aplicado (590 visitas, 70 renombres, corte al 14/ago). Pero quedaron
**20 clientes con DOS fichas en el ClientNoteTracker**: la vieja con la historia y una nueva con
el apellido completo, porque la cajera creó ficha en vez de buscar al cliente. Ejemplos:

| Ficha con historia | Ficha nueva | ¿Placa? |
|---|---|---|
| `gustavo diaz` (14 visitas) | `GUSTAVO DIAZ CONTRO` (1) | **distintas** |
| `ADRIAN MARTINEZ` (7) | `ADRIAN MARTINEZ MORENO` (1) | **distintas** |
| `KEVIN HERNANDEZ RAMIREZ` (3) | `KEVIN HERNANDEZ` (1) | **distintas** |
| `RAMON CERVANTES` (3), `gerardo espinoza` (3), `JAVIER LIMON` (3)… | +apellido | vieja sin placa |

**NO se fusionaron**, a propósito: se buscó corroboración por placa y **ninguno de los 20 comparte
placa**; en los 3 de arriba las placas son **distintas**, o sea que podrían ser homónimos reales.
La regla del dueño es *1000% o nada*.

- ✅ **Decidido (15/ago): NO se fusionan.** Ver arriba.
- 📌 **La raíz se arregla en caja, no en el CRM:** si la cajera busca al cliente existente en vez
  de crear ficha nueva, esto deja de pasar. Mientras siga, cada import trae más partidos — y con
  la decisión tomada, se quedan partidos.

### ❓ Preguntas al dueño (el dato no las contesta)

- 🔴 **¿Quién estuvo de supervisor el 6, el 10 y el 11 de agosto?** Son los tres días donde la
  app se abandonó por rachas (29%, 21% y 46% de carros afectados). El 11 hubo **9 carros
  seguidos sin tocar desde las 17:14 hasta el cierre**. La app no guarda quién la opera, así
  que es la única forma de saber si es entrenamiento de una persona o proceso de todos.
- 🟠 **¿Un 6to lavado gratis de un EXPRESS es express?** Hoy `Gratis`+`6to Express` se cuenta
  como completo y no va a la línea 1 (3 casos: carros 2208, 2211, 2290). Si la respuesta es
  sí, el arreglo es una línea en `es_lavado_express`. **No se toca la regla sin su palabra.**
- 🟠 **¿Por qué nadie usa el rechazo de entrega?** 0 usos en 25 días (~1,900 carros); la tabla
  tiene 3 filas históricas. ¿No hay rechazos, o no se usa la pantalla?
- 🟠 **¿La app de la cajera se va a usar o el ClientNoteTracker es lo definitivo?** 15 visitas
  por `caja='principal'` contra 14,025 por `import`. Hoy la lealtad depende de que alguien
  corra la importación a mano.
- 🔵 **¿El 12/ago cerraron temprano?** Última venta 15:32 (dato de Zettle, no de la app), 38
  ventas. Y el 11 sólo 39. Dos días chicos seguidos.
- 🟡 **`A GRIS`** (carro 2183, 13/ago) — segundo caso del código `A` por `AU` (el primero fue
  `A GUINDA` el 20/jul). Sigue sin decidirse si se acepta `A` = automóvil o se corrige en caja.

### 📌 Para el CLAUDE.md cuando se toque el catálogo

`Completo Cera` ya no existe (último 28/jul); lo reemplazó **`Completo RUSH`** con variantes
`Chico`/`Grande`. Clasifica bien (`'completo%'`), pero el catálogo documentado en §12.1 está
viejo.

---

## 🔍 SEGUNDA REVISIÓN COMPLETA DE CÓDIGO — 3/ago/2026

**Qué es esto:** una auditoría de "desarrollador externo que abre el repo por primera vez", pedida
por el dueño para apartarse y mirar el conjunto. Se leyó **todo**: la API (`app/index.ts`, 1331 líneas),
los 3 HTML (`index`/`reporte`/`caja`, ~5,400 líneas), el `sw.js`, las 3 Edge Functions restantes y las
95 migraciones. **Nada se ha tocado todavía** — esto es el hallazgo, no el arreglo.

**Veredicto:** el proyecto está mucho mejor de lo que 95 migraciones harían temer. Reglas de negocio
en la base, limpieza de julio (055–060) que se sostiene, escape universal, `firmaRender` bien resuelto.
No hay incendio. Hay 3 bugs baratos, 1 hueco de seguridad real acotado, deuda menor, y features de valor
esperando. Regla aplicada: **si el arreglo causa más problemas de los que quita, NO entra** (ver §"NO tocar").

### 🔧 Bugs baratos que arreglar (sin efectos secundarios)

- 🟠 **La cola se vacía en pantalla sin avisar.** `docs/index.html:1309` — `carros = d.carros || []`.
  Si `/cola` responde **200 con JSON inesperado** (`{ok:false}`, cuerpo sin `carros`), la lista se
  vuelve `[]` y se pinta "No hay carros en proceso" **sin señalar error**. Para el supervisor, el turno
  desapareció. Viola "cero sorpresas". Fix: si `d.carros` no es arreglo → mostrar error y **conservar la
  lista anterior**. Riesgo cero.
- 🟠 **`escapar()` divergió entre los 3 HTML** (¡el bug #1 del proyecto, otra vez, en silencio!).
  Caja (`caja.html:501`) y reporte (`reporte.html:302`) son null-safe; `docs/index.html:969` **no** lo
  es → un `null` se pinta como el texto `"null"` en la tarjeta. Justo en el escape de HTML. Fix de una
  línea. **Es la prueba de que la copia de helpers entre los 3 HTML ya duele** (ver §deuda).
- 🟠 **El service worker cachea respuestas no-OK.** `docs/sw.js:56` guarda `r.clone()` sin mirar
  `r.ok`. En la ventana de un deploy de Pages, un 404 con cuerpo HTML queda cacheado y se serviría
  offline. Baja probabilidad, alto impacto (app rota sin wifi). Fix: envolver el `put` en `if (r.ok)`.
- 🟡 **Posible FUGA DE LEALTAD en la caja (el único que toca dinero).** Si la cajera toca "Registrar
  visita" y luego usa el **botón atrás** del teléfono en vez de Listo/Cancelar, el `popstate`
  (`caja.html:597`) limpia `visitaActual` **sin llamar a `/descartar-visita`**. Esa visita ya cuenta
  para "cada 5 = 1 gratis" → queda colgada e infla la lealtad de alguien = un lavado gratis de más.
  **PRIMER PASO: confirmar si el backend barre visitas sin enlazar.** Si no, es fuga real.

### 🔒 Seguridad (real, pero acotado)

- 🔴 **El webhook de Zettle NO verifica la firma.** El `signingKey` se guardó "para más adelante" y
  nunca se implementó. Función pública, `--no-verify-jwt`, URL descubrible (repo público) →
  **cualquiera puede inyectar `PurchaseCreated` falsos** y ensuciar cola y reportes. Acotado por el
  `UNIQUE` de `purchase_uuid` (no duplica), por eso no es emergencia. Cierre: validar el HMAC con el
  `signingKey` que ya tenemos. Sin efectos secundarios.

### 🧹 Deuda y redundancia — CUÁNDO, no "ya"

- **Extraer `rush-comun.js`** (API, código de acceso, `pedir`, `escapar`, `achicar` — ~80-120 líneas
  idénticas y ya divergidas entre los 3 HTML). PERO en este proyecto "un archivo autocontenido" tiene
  valor (wifi flojo, menos piezas), y un archivo nuevo **obliga a meterlo en la precache del `sw.js`** o
  se rompe offline. Hacerlo **la próxima vez que se toque auth/API**, no como refactor especulativo. El
  CSS **no** se extrae (caja y reporte visten distinto a propósito).
- **Unificar "el tipo sale de la submarca"** — copiada en `guardar_datos_de_foto` y
  `enlazar_visita_a_carro` (086). Misma regla calibrada en 063; el día que se cambie una y no la otra,
  se desincronizan en silencio. Extraer helper `tipo_desde_foto(...)`. Bajo riesgo, alto valor preventivo.
- **`schema_actual.sql` de solo lectura** (`supabase db dump --schema-only`) versionado como doc, con
  nota "las migraciones son append-only; esta es la foto de la verdad". Resuelve de raíz el dolor de "el
  archivo miente" para quien entre nuevo. Minutos, riesgo cero. **Este lo haría sin dudar.**
- **Índice en `asignaciones(empleado_id)`** antes de que duela (lo usan el auto-join de encimados,
  `perfil_de_secador`, `secadores_de_placas`). Add barato, no destructivo.
- **Debounce al buscador de placas del reporte** (`reporte.html:652`, hoy un GET por tecla; los otros
  dos buscadores ya lo tienen).
- Cosmético riesgo cero: CSS muerto `.rejilla.marcas` (`index.html:402`); params sin uso en
  `pintarPlacas`/`cliResultadosHTML` del reporte; `textoCarro` duplicado inline en la caja.

### 🚫 Lo que NO tocar (por la regla del dueño)

- **No consolidar/reescribir las 95 migraciones.** Un snapshot que dropea y recrea contra producción es
  peligroso y no mejora el esquema real. El `schema_actual.sql` da el beneficio con 0% del riesgo.
- **No quitar los estados legacy `tunel`/`por_asignar`** (front ni checks) sin confirmar por consulta
  que la base ya no los emite. Son red de seguridad intencional.
- **No materializar `historial_placas`** todavía (1.6 ms hoy; optimizar sería resolver un no-problema).
- El loop de relojes O(n²)/seg **no es problema** (40k iteraciones en un teléfono moderno es nada).

### 💡 Qué construir para el negocio (por valor, atado a dolores ya medidos)

1. **La cámara fija trasera** (ya identificada) — de mayor impacto: ataca de raíz la foto pegada al
   carro equivocado (~2-3/día), las fotos faltantes (lunes 88%) y en parte los olvidos. Ningún software
   cierra los tres; la cámara sí. Ya está en la memoria `camara-caja-frontal-3-4-marca-submarca`.
2. **Sacar a la luz "devolución después de entregar"** — dato YA existe (`ventas` con
   `refundsPurchaseUuid` → carro entregado y sin cancelar). Por definición del dueño es señal de calidad
   *peor* que un rechazo (el cliente ya se fue molesto) y hoy es **invisible**. Contarlo en el reporte
   diario junto a rechazos. Barato. (Ya está en Decisiones pendientes del `CLAUDE.md` §13.)
3. **Usar de verdad la analítica por persona** (era el punto #1 del proyecto, ya calibrada con 064/065).
   Los cierres gritan hallazgos sin explotar: Jorge Luna 100% encimados dos días; Edgar Reyes como dato
   limpio. Es leer lo que ya se mide, no código nuevo.
4. **Aviso al cliente "su carro está listo"** (opcional, costo honesto) — hay teléfonos en el CRM, pero
   requiere integración externa (costo/mensaje + regla de permiso). Evaluar, no recomendación firme.
5. **Vista de horas pico para acomodar personal** — el volumen por hora ya existe (sábado 127, 76%
   encimados). Falta la pantalla.

**Resumen en una frase:** 3 arreglos baratos (cola en blanco, `escapar`, `sw` cache), cerrar la firma
del webhook cuando se pueda, y cobrar los intereses de lo que ya se mide (#2 y #3), mientras la cámara
fija (#1) resuelve de raíz lo que hoy se parcha.

---

## ✅ CIERRE DEL 24/jul/2026 — marca/modelo de la foto, review adversarial, analítica calibrada

**Todo shippeado y verificado.** Migraciones `061`–`065` en producción, Edge Function `app`
desplegada. El estado canónico vive en `CLAUDE.md §11.85` (índice del día), §9 (marca/submarca/tipo
de la foto) y §12 "Lo siguiente" (puntos 1 y 2 ya RESUELTOS). Aquí sólo lo que sigue vivo.

**Lo que se resolvió hoy (ya no está pendiente):**
- ✅ **Marca/submarca/tipo de la foto** — el supervisor ya no captura marca. `061`/`062`/`063`.
- ✅ **Umbral del secado corto** — el dueño fijó **3 min**; fuera del promedio de secado (no de la
  espera, que es real). `064`. Se surface `secados_descartados`.
- ✅ **Punto 8 (cola virtual)** — el dueño escogió **opción B: solo mostrar contexto**. El reporte
  muestra "encimados" por equipo, sin tocar promedios ni pedir toques al supervisor. `065`.
- ✅ **Bitácora dedicada** — se intentó y se **mató** (tercera fuente que se desincroniza). El
  cierre del día vive en `CLAUDE.md` (secciones fechadas) + `memory/`.

**Lo que queda vivo:**

- 🔵 **Avisar cuando dos carros del mismo día comparten placa.** Ya van dos veces (19/jul 69/71,
  21/jul 269/272). Señal barata de foto pegada al carro equivocado. La `063` **angosta** el daño
  (re-tomar foto limpia el dato ajeno) pero no avisa del choque. Sigue pendiente.
- 🟡 **`A GUINDA` por `AU GUINDA`** (carro 124, 20/jul) — decidir si se acepta `A`=automóvil o se
  corrige en caja. No aflojar el parser por cuenta propia.
- 🔵 **Preguntar por dos huecos del 22/jul:** faltan las 4 fotos de 13:00–13:59, y 5 de las 7 notas
  de caja faltantes son de la mañana temprano. Huelen a turno, no a bug. Se confirma preguntando.
- 📌 **Con la analítica ya calibrada (puntos 1 y 2 hechos), leer los tiempos por persona en serio.**

---

## ✅ CIERRE DEL 22/jul/2026 — análisis del día + limpieza del backend

**Todo shippeado y verificado.** Migraciones `055`–`060` aplicadas en producción, Edge
Functions `app` y `sincronizar-jibble` desplegadas. El estado canónico vive en
`CLAUDE.md §11.9`; aquí sólo queda lo que sigue vivo.

**Lo que se hizo:** una sola regla para "servicio especial" (`055`), un solo sistema de colores
y "Saul de Anda" completo (`056`), borrado de lo muerto + índice para `/cola` (`057`), el
reporte deja de escanear la historia (`058`), el trigger de venta deja de reparsear seis veces
(`059`), y Jibble sólo de 6 AM a 10 PM hora local (`060`).

**Cómo se verificó** (el método vale más que los cambios): línea base de 32 KB con la salida
real del sistema **antes** de tocar nada, y comparación después de **cada** migración. 52 casos
de clasificación, 331 ventas releídas, 7 escenarios de reporte, un ciclo completo de carro
(venta → asignar → corregir → rechazar → entregar → restaurar → devolución) y 8,760 horas de
ventana horaria. Todos los endpoints probados con `curl` contra la API real.

### Lo que queda vivo

- 🟡 **DECIDIR: el umbral del secado de 0 segundos.** 8 carros en dos días (5 el 21/jul, 3 el
  22) con secado de ~6 s: son olvidos registrados tarde, no trabajo. Hunden el promedio de la
  persona a la que se le anotan. Sugerido: secado < 3 min cuenta como lavado pero fuera de los
  promedios, igual que `cerrado_automaticamente`. **Falta el número del dueño.**
- ⏸️ **Punto 8 (cola virtual)** — sigue EN PAUSA, el dueño lo analiza. Ya hay dos días de dato:
  infla el secado 4.6 min (20/jul) y 5.9 min (22/jul), y cambia el ranking por persona.
- 🔵 **Avisar cuando dos carros del mismo día comparten placa.** Ya van dos veces (19/jul
  carros 69/71, 21/jul carros 269/272). Señal barata de foto pegada al carro equivocado.
- 🟡 **`A GUINDA` por `AU GUINDA`** (carro 124, 20/jul) — decidir si se acepta `A`=automóvil o
  se corrige en caja. No aflojar el parser por cuenta propia.
- 🔵 **Preguntar por dos huecos del 22/jul:** faltan las 4 fotos de 13:00–13:59, y 5 de las 7
  notas de caja faltantes son de la mañana temprano. Los dos huelen a turno, no a bug.

---

## ✅ CIERRE DEL 20/jul/2026 — todo shippeado

**Todo lo de abajo ya está EN PRODUCCIÓN y en el `CLAUDE.md`** (el estado canónico vive en
`CLAUDE.md §12.0`). Los 10 pedidos del dueño (1–10), más el fix del stutter de los guiones, el
manejo del botón atrás del teléfono, el aviso de secador ponchado (texto + guiones verdes en
demorado), y la regla de prelavado > 20 min. Migraciones `051`–`053` aplicadas; Edge Function
`app` desplegado. El reporte se congela solo a las 8:30.

**Lo único que queda vivo para las próximas sesiones:**

- ⏸️ **Punto 8 (cola virtual del secado)** — EN PAUSA, el dueño lo analiza. Dato del 20/jul:
  infla el secado ~4.6 min de promedio (18 de 59 completos). Ver `CLAUDE.md §12.0` y consulta
  `a6`/`q11`.
- 🔵 **"Saul de Anda" sale "Saul de"** (grilla y reporte) — cosmético, bajo riesgo.
- 🟡 **`A GUINDA` por `AU GUINDA`** (carro 124, 20/jul) — decidir si se acepta `A`=automóvil o
  se corrige en caja. No aflojar el parser por cuenta propia.
- 📌 **Mañana (21/jul, 2º día de prueba):** confirmar que el reporte del 20 se congeló, y
  correr el análisis del día como se hizo hoy.

El resto de este archivo es el detalle histórico de cómo se construyó cada cosa el 20/jul.

---

## Estado del código (20/jul/2026, tarde)

**Lote de bajo riesgo CODIFICADO y probado en el navegador — SIN PUSHEAR.** Los puntos
**2, 4, 6, 7 y 9** ya están en `docs/index.html`, commiteados localmente. El supervisor
NO los ve todavía (falta `git push`, que se hace al cierre). Verificado inyectando datos
falsos en el panel, sin tocar la API real:

- **2** — al reabrir Asignar, el contenedor pasó de 628px de scroll a 0 (abre arriba).
- **4** — "vino tinto" tecleado en minúsculas salió "VINO TINTO" en el campo y en `asig.color`.
- **6** — guiones rojos (- - - -) marchando por la orilla de los 2 botones de Asignar,
  ninguno en el verde de "Entregado". (Primero fue un glow; el dueño lo cambió a guiones
  girando el 20/jul. El glow alcanzó a estar en vivo un rato; estos guiones lo reemplazan.)
- **7** — "Jesús Gil, Pablo Cruz" en la tarjeta, mismo tamaño que el renglón del servicio.
- **9** — cero botones de galería; solo queda la cámara.

Sintaxis validada con `cscript //E:JScript` (el método del proyecto).

**Pendiente al pushear:** mover estos 5 al `CLAUDE.md` con su razón (incluida la sección 4,
que hoy describe el botón de galería que se quitó).

### Lote de lógica — puntos 3 y 10 (CODIFICADO, PROBADO y en camino a live)

- **10 — foto deshabilitada hasta asignar carril y secador.** El botón se ve apagado (no
  desaparece). Probado: en un carro sin asignar `disabled=true`, en uno secando `false`.
  De paso angosta la ventana del bug de la foto mal pegada del 19/jul.
- **3 — Corregir con los secadores PRESELECCIONados y editables.** (El dueño aclaró: quería
  memoria como el tipo/color, no solo lectura.) Al abrir Corregir de un carro secando, los
  secadores actuales salen marcados en la rejilla y se pueden quitar/agregar libremente. Un
  secador que ya checó salida sale igual, en gris, con la nota "ya no aparece", para que se
  vea y se pueda quitar. Al guardar, `editar_carro` reconcilia las asignaciones **sin tocar
  las etapas**, así que el cronómetro de secado NO se reinicia (esa es la diferencia con
  Regresar). Probado: preselección con un ponchado, body correcto (`empleados` ids +
  `secadores` nombres), y sobre la base que el `etapa_inicio` de secado no cambia.
- **3 (backend) — `datos_de_nota` arreglado + reconciliación de secadores.** Migración `051`
  (datos_de_nota solo se apaga si el valor cambia) y `052` (Corregir reconcilia secadores sin
  tocar etapas; absorbe la 051). Probadas con bloques `do $$ ... raise` revertidos:
  `reenvío_mismo=t, cambio=f`; y `Chuy,Pablo → Luis,Pablo` con `etapa_inicio IGUAL = t`.
  **051, 052 y el Edge Function `app` ya están aplicados/desplegados en producción** — todo
  retrocompatible con el front viejo (secador_ids es un campo extra; /editar sin secadores no
  los toca).

### Punto 5 — desglose en vivo de un carro activo (HECHO)

- Botón de **info (ⓘ)** en la tarjeta, donde estaba el de galería (a la izquierda de la
  cámara). Es un botón y **no** un toque a la tarjeta, a pedido del dueño, para no abrirlo por
  accidente.
- Abre el mismo tipo de pantalla que Finalizados, pero **en vivo**: prelavado y túnel
  estáticos, **secado corriendo** (mm:ss, en verde, "· en curso"), total contando desde que
  pagó, y los secadores ("Secando ahora").
- Migración `053`: `detalle_del_carro` ahora devuelve `abierta_etapa` + `abierta_inicio` para
  contar la etapa abierta en vivo (`secando_seg`/`total_seg` salen nulos mientras no se
  entrega). **Ya aplicada en producción.** `/carro` no necesitó cambio de Edge Function.
- Probado: secado avanza 15:09→15:11 con el timer; Finalizados intacto ("Lo secaron",
  minutos, sin timer). El cronómetro se apaga al cerrar la pantalla.

**Con esto la lista completa del dueño (puntos 1–10) queda hecha.**

### Extra — el botón "atrás" del teléfono cierra la pantalla, no sale de la app (HECHO)

Pedido del dueño: en Finalizados (y en cualquier pantalla), el back del teléfono sacaba de la
app. Ahora cierra la pantalla de encima y regresa a la anterior.

- Cada pantalla que se abre (Asignar/Corregir, Entrega, Finalizados, Detalle) empuja un estado
  al historial; el back —o los botones de Volver/Cancelar— consume uno y corre su cierre. Al
  no quedar ninguna, el back ya sale normal.
- Regla anti-desincronización: **todo** cierre pasa por `cerrarPantalla()` → `history.back()`
  → `popstate`, el único que ejecuta el cierre real. Abrir empuja uno, cerrar consume uno.
- Probado en el navegador simulando el back (`history.back()`):
  - Finalizados → back → cola.
  - Finalizados → Detalle → back → Finalizados → back → cola.
  - Finalizados → Corregir → back → **Finalizados** (no la cola) → back → cola.
  - Entrega → back → cola. Y un back con la pila vacía no truena (sale normal).
- `pushState` verificado en file://; en la app real (https) funciona igual.

---

## Pedidos del dueño — 20/jul/2026

### 1. ✅ HECHO (20/jul ~12:5x) — Borrado el rechazo de prueba de Chuy

Lo hizo el dueño a propósito para enseñarles a los supervisores cómo funciona.

Se borró **sólo** `rechazos.id = 9` (carro 116, Jesús Gil, "Vidrios", 11:02), con `delete`
guardado por id + condiciones. Verificado después: `rechazos` quedó en **0 filas** y el
carro 116 sigue `entregado` con su entrega intacta (11:22). El carro no se tocó.

> Se hizo **antes** de las 8:30 a propósito: el reporte se congela a esa hora y guardar el
> rechazo falso en la fila congelada del 20/jul lo habría dejado permanente.
>
> La tabla `rechazos` queda vacía. El primer rechazo real del negocio será el siguiente que
> entre — línea base limpia.

---

### 2. Al asignar, la pantalla debe abrir HASTA ARRIBA

Hoy al picar "Asignar" la pantalla aparece ya recorrida hasta el área de secadores, y el
supervisor se pierde: no ve que arriba hay cosas que llenar.

**Debe abrir en el tope**, para que se entienda que a partir de ahí se va bajando poco a poco.

> **Por qué importa más de lo que parece:** uno de los supervisores es una persona de la
> tercera edad y batalla con la tecnología. Si la pantalla abre a medio camino, no hay forma
> de que sepa que se saltó algo — no hay "arriba" visible. Esto es la regla de la sección 4
> del `CLAUDE.md`, no un detalle estético.

Pista: `abrirPantalla()` en `docs/index.html` (~línea 1014-1071). Probablemente el navegador
está conservando el scroll anterior, o algo recibe foco y el navegador lo trae a la vista.
Al abrir hay que forzar el scroll al tope del contenedor.

---

### 3. "Corregir" debe llegar con TODO lo que ya estaba puesto

Hoy al picar Corregir **los secadores que ya estaban asignados salen sin seleccionar**. El
supervisor no ve el estado real, y si confirma sin fijarse puede borrar lo que había.

**Debe mostrar exactamente lo que está seleccionado hoy** — secadores incluidos, no sólo
tipo/color/marca.

> Es el mismo principio que el punto 2: la pantalla tiene que decir la verdad de lo que hay,
> porque el supervisor no tiene manera de saber lo que la pantalla le está escondiendo.

Pista: la pantalla se llena en `abrirPantalla()` (~1030), que hoy sólo precarga
`tipo/color/marca`. Falta traer las asignaciones vigentes del carro y premarcarlas.

---

### 4. Botón para escribir un color que no esté en los comunes

En el área del supervisor, junto a los colores de siempre.

**Siempre en MAYÚSCULAS**, aunque el teclado del teléfono esté en minúsculas — para que el
formato quede uniforme con lo que llega de la nota de caja (que ya guarda en mayúsculas).

> Cuidado: forzarlo con `text-transform: uppercase` en CSS **sólo lo pinta**; lo que se manda
> seguiría en minúsculas. Hay que subirlo también al escribir y al guardar. `editar_carro`
> ya hace `upper()` del lado de la base, así que ahí queda cubierto — pero el supervisor debe
> **ver** mayúsculas mientras teclea, si no parece que no funcionó.

---

### 5. Tocar el nombre del vehículo en una tarjeta ACTIVA abre su desglose

Igual que ya funciona en Finalizados, pero para un carro que sigue trabajándose.

Debe mostrar:
- tiempo de **prelavado** y de **túnel** (ya cerrados)
- el **contador de secado corriendo**, en vivo
- **quiénes** están secando esa unidad

Pista: `detalle_del_carro` ya existe y ya devuelve los segundos sumados por etapa. Lo que
falta es que acepte un carro **sin entregar** y que la pantalla sepa pintar una etapa abierta
como cronómetro en vez de como número fijo.

---

### 6. Efecto GLOW al botón de Asignar — sólo a ése

El supervisor se confunde: hay muchos azules, y el ícono redondo que dice "prelavado + túnel"
tiene forma parecida al botón. Le estaba picando al ícono.

**Sólo el botón de Asignar lleva glow.** Si se le pone a más de un elemento se pierde el
punto: el glow existe para decir *"éste es el que se toca"*.

---

### 7. Los secadores asignados, en la tarjeta de trabajos activos

Junto al tipo de lavado, la descripción de la unidad y la placa.

**Del mismo tamaño de fuente** que el renglón del tipo de lavado
(ej. `Completo Cera - Completo`), no más chico.

Pista: la tarjeta se arma alrededor de `docs/index.html:729`.

---

### 8. ⏸️ EN PAUSA (decisión del dueño, 20/jul) — Cola virtual del secado

**El dueño lo va a analizar más; por lo pronto se deja el secado como está hoy (reloj de
pared).** No implementar nada de esto hasta que él lo retome.

> **Por qué se pausó, para cuando se retome:** al validar el cálculo como consulta pura
> sobre los 26 carros de hoy, salió un caso (**carro 109, Pablo Cruz**) con secado efectivo
> **negativo**. No era error del cálculo: Pablo traía el 108 y el 109 abiertos a la vez y
> entregó el 109 **antes** que el 108. El supuesto de "es una fila" no siempre se cumple —
> a veces secan dos en paralelo y los terminan en desorden (hoy: 1 de 26).
>
> Alternativa que quedó sobre la mesa para ese día: en vez de "el reloj arranca cuando
> entregó el anterior", **repartir cada minuto del secador entre los carros que traía
> abiertos en ese minuto** (1 carro → minuto completo; 2 carros → medio a cada uno). Una
> sola regla cubre fila y paralelo, nunca sale negativo, y la suma atribuida a un secador es
> exactamente lo que trabajó. La consulta de validación quedó en el scratchpad de esa sesión
> (`q11.sql`).

---

#### (Referencia — el pedido original y la recomendación, congelados hasta que se retome)

**El pedido:** el secado no debe contar el tiempo que el carro estuvo formado

**El pedido:** si a un secador se le asigna un segundo carro sin haber terminado el primero,
el reloj de secado del segundo no debe correr en su contra. El secado real empieza cuando
entregó el anterior. El **total del cliente sí sigue siendo el total** — lo que cambia es lo
que se le atribuye al secador.

#### Recomendación: NO mover la etapa `secando`, calcular el tiempo efectivo aparte

El dueño pidió sugerencias si había mejor forma. Ésta es la que recomiendo, y es una
diferencia importante de implementación:

La etapa `secando` se queda **exactamente como está** (arranca al asignar, reloj de pared).
Encima se calcula un valor derivado:

```
inicio_efectivo(carro) = max(
   inicio de su etapa 'secando',
   la entrega más reciente de CADA uno de sus secadores antes de este carro
)
secado_efectivo = entregado_en - inicio_efectivo
tiempo_en_fila  = inicio_efectivo - inicio de la etapa
```

**Por qué no mover la etapa:** ese mismo dato alimenta tres cosas a la vez — el total del
cliente, el rojo de los 35 minutos en la tarjeta, y el cronómetro que el supervisor ve
correr. Moverlo arreglaría la medición del secador y rompería las otras tres. Derivándolo,
el reloj de pared sigue siendo el reloj de pared y la atribución se arregla igual.

**Ventaja adicional:** no le agrega **ni un toque** al supervisor. Es puro cálculo sobre
datos que ya se guardan. La alternativa obvia — que el supervisor marque "ya empecé con
éste" — choca de frente con la regla de los dos toques.

**Se toma el `max` sobre los secadores** porque un equipo no puede empezar hasta que se
desocupa el **último** de sus integrantes.

#### Lo que hay que cuidar, dicho de frente

1. **⚠️ Esto puede esconder el dato más valioso del proyecto.** Si un secador trae 3 carros
   formados, cada uno sale "rápido" y la saturación del taller **desaparece del reporte** —
   que es justo el cuello de botella que toda la app existe para encontrar.

   **Por eso `tiempo_en_fila` se guarda y se muestra**, no se descarta. El reporte debe decir
   *"secado efectivo 22 min + 18 min formado"*. La fila no es culpa del secador, pero sí es
   un dato del negocio, y borrarlo sería cambiar un número injusto por uno ciego.

2. **Incentivo al revés.** Si lo único que se mide es el secado efectivo, la forma más fácil
   de salir bien en el reporte es aceptar muchos carros. El `tiempo_en_fila` visible también
   tapa este hoyo.

3. **Un carro cerrado automáticamente rompe la cadena.** Su hora de entrega es ficción (ya
   está documentado en el `CLAUDE.md`), así que **no sirve** como punto de arranque del
   siguiente. Regla: si el carro anterior fue `cerrado_automaticamente`, no se usa de
   referencia y el secado efectivo del siguiente se marca como **no medible** — mismo
   criterio que ya se usa para no ensuciar los promedios.

4. **El rojo de los 35 min en un carro formado.** Se va a poner rojo aunque su secador ni
   haya empezado. **Yo lo dejaría rojo**: el cliente sí lleva 35 minutos esperando y el
   supervisor sí debería considerar moverlo a alguien libre. Pero conviene que la tarjeta
   diga **"EN FILA — detrás de <carro>"**, para que entienda por qué no avanza y pueda
   reaccionar. Eso además le sirve directo al supervisor de la tercera edad.
   👉 **Falta decisión del dueño.**

5. **El orden de la fila** se toma por hora de asignación. No hay que capturarlo.

6. **Sólo aplica del 20/jul en adelante.** Las asignaciones del 19/jul se borraron, así que
   ese día no se puede recalcular.

---

### 9. Quitar el botón de "escoger de la galería"

No se está usando. Queda **sólo el de cámara**, al 100%.

> El `CLAUDE.md` (sección 4) documenta por qué se agregó el 19/jul: "por si la foto se tomó
> fuera de la app". El uso real dice que ese caso no ocurre. **Hay que actualizar esa
> sección al hacerlo**, si no queda un `CLAUDE.md` describiendo un botón que ya no existe.
>
> No se puede confirmar por base de datos — no hay columna que distinga cámara de galería,
> así que se toma la palabra del dueño. Es reversible con git si resulta que sí hacía falta.

Beneficio secundario: quitarlo deja **un solo botón** en vez de dos, que es exactamente la
regla de la sección 4. El diseño de dos botones existía para un caso que no pasó.

---

### 10. La foto se habilita SÓLO después de asignar carril y secador

Antes de eso, deshabilitada.

**Se midió antes de aceptarlo, y el cambio va con la corriente:** de las 27 fotos de los
últimos 2 días con hora de asignación conocida,

```
25 se tomaron DESPUÉS de asignar   (promedio: 1.0 min después)
 2 se tomaron antes
```

O sea que esto **no les cambia la costumbre, la formaliza**. Riesgo bajo.

> **Además ataca un bug real.** El 19/jul una foto se le pegó al carro equivocado (los carros
> 69 y 71 quedaron con la misma placa, `BVJ-113-A`) porque en un apuro se fotografió un
> Accord que seguía en el patio. Un carro recién pagado y sin asignar **todavía puede no
> estar físicamente identificable**; uno ya asignado sí está enfrente del supervisor.
> Esto angosta la ventana en la que ese error puede ocurrir. No la cierra — sigue sin haber
> nada que impida fotografiar el carro equivocado.

⚠️ El botón tiene que **verse deshabilitado**, no desaparecer y reaparecer. Un botón que
aparece solo es de las cosas que más confunden al supervisor de la tercera edad.

---

## Decisiones ya tomadas por el dueño (20/jul/2026)

- ⏸️ **Punto 8 — EN PAUSA.** El dueño lo va a analizar más. Por lo pronto el secado se queda
  como está (reloj de pared). La validación destapó un caso negativo (carro 109, secado en
  paralelo) que hay que resolver antes de construir. Ver el punto 8 arriba.
- ✅ **Punto 3 — aprobado:** Corregir debe llegar con los secadores ya premarcados.

---

## Detectado al revisar el día (20/jul/2026, mediodía)

- [ ] 🔴 **`datos_de_nota` mide lo contrario de lo que dice.** La bandera se apaga al
      **asignar**, aunque el supervisor no haya corregido nada.

      Venta → la nota llena tipo/color, bandera = true. El supervisor abre Asignar, la
      pantalla viene **prellenada con esos mismos valores**, él sólo escoge línea y
      secadores, y la app los manda de regreso (`index.html:1334`). La Edge Function llama a
      `editar_carro` (`index.ts:568`), que ve "tocaron los datos" y apaga la bandera
      (`025_editar_carro.sql:71`).

      Resultado: la columna termina contando **carros sin asignar**, no notas de caja.
      El 20/jul dio `1` cuando la verdad era **25 de 25 con nota**. Yo leí ese 1 y le
      reporté al dueño que las cajeras no estaban llenando la nota — al revés de la
      realidad. Es el único uso que tiene la columna.

      **Arreglo:** bajar la bandera sólo cuando el valor **cambió**, no cuando se reenvió
      igual. `editar_carro` tiene los dos valores a la mano; hoy no los compara.

      ⚠️ El histórico de la columna no se puede creer para ningún día ya pasado. Se
      reconstruye releyendo la nota con `interpretar_nota(nota, monto=0)` y comparando —
      así se sacó el 25 de 25.

      > 🔗 **Ojo al hacer el punto 3:** si Corregir empieza a premarcar los secadores, el
      > mismo patrón de "reenviar lo que ya estaba" se repite. Al arreglar la bandera hay que
      > pensarlo para los dos casos, no sólo para Asignar.

- [ ] **La cajera escribió `A GUINDA` en vez de `AU GUINDA`** (carro 124). El código `A`
      no existe, y como la regla es no adivinar, ese carro quedó sin tipo ni color. Único
      del día. **Decisión del dueño:** ¿se acepta `A` como automóvil, o se corrige en caja?
      No aflojar el parser por cuenta propia — así se empiezan a colar datos inventados.

- [ ] **"Saul de Anda" sale como "Saul de" en la grilla.** El nombre corto parte por espacios
      y se queda con la preposición. Es el único de los 18 con el problema; los apellidos
      compuestos (`de`, `del`, `la`) hay que saltarlos al armar `mostrar`.
      Cosmético, pero es un nombre de persona en la pantalla donde el supervisor la escoge.

- [ ] **Verificar el congelado de las 8:30 PM.** Hoy es la primera noche con el horario
      nuevo (`30 3,4 * * *` UTC + guardia de hora local 20). El cron está activo. Mañana:
      `select fecha, congelado_en from reportes_diarios order by fecha desc limit 2`
      y confirmar que existe la fila del 20/jul.

# Pendientes por hacer — se trabajan DESPUÉS del cierre (8 PM)

> Este archivo es la bandeja de entrada. Nada de aquí se toca mientras el autolavado esté
> abierto: cualquier despliegue a medio turno le puede tumbar la app al supervisor.
> Cuando algo se hace, se mueve al `CLAUDE.md` con su razón y se borra de aquí.

---

## 🔍 AUDITORÍA GENERAL del 21–22/ago/2026 — 79 hallazgos, 68 veredictos de refutación

Corrida con `Workflow`: 11 frentes en paralelo, **cada hallazgo atacado por refutadores
independientes** (dos lentes en los graves, una en los medianos), más un crítico de completitud.
El método y la decisión de modelos viven en `.claude/skills/auditoria-general/SKILL.md`.

> ### 👉 POR DÓNDE RETOMAR (sesión del 22/ago cerrada; se sigue el lunes 24)
>
> **Nada de esta auditoría se desplegó.** Todo lo de abajo está pendiente; el árbol de trabajo
> quedó limpio y el informe publicado en
> <https://claude.ai/code/artifact/014aca39-2c86-4724-98b9-f982a64ef119>.
>
> **Lo primero, en este orden:** (1) las «Devoluciones» del reporte — una línea, y es el único
> número falso que el dueño está leyendo hoy; (2) la guarda de error y el corte de tiempo del
> reporte, que van en el mismo despliegue; (3) la cortesía del import; (4) los permisos de la llave
> pública; (5) el índice del ticket y los comodines; (6) la prueba del import que no puede fallar.
>
> **Los 1–2 tocan la pantalla del dueño**, así que van con front y back juntos y en el corte
> (`CLAUDE.md §2`). Los 4–6 son sólo base y pueden ir antes.
>
> **Antes de subir cualquier cosa:** `bash pruebas/correr.sh`, y sumarle un caso por cada hallazgo
> que se arregle.
>
> ⚠️ **No arreglar a ciegas los hallazgos del front** (supervisor atrapado en Finalizados,
> cronómetro que no se apaga, foto que se borra sola, aviso de "sin conexión"): **nadie los
> reprodujo en un navegador**, son lectura de código. Reproducirlos primero.
>
> **Esperan respuesta del dueño:** el servicio de `Faros` de $600 que no crea carro; si la caja
> parte servicios en dos cobros; qué debe contar «Devoluciones»; si los avisos del sistema deben
> poder marcarse como atendidos; y si se recongela el 19/jul.


> 🔑 **Lo que el pase adversarial cambió, y es la razón de tenerlo:** de **18 hallazgos marcados
> `alta` por quien los encontró, sólo 2 sobrevivieron como altas** — y son el mismo bug visto desde
> dos frentes distintos. **9 se refutaron por completo.** Sin este pase, dieciséis números inflados
> habrían entrado a esta lista como urgentes.

### 🔴 Lo único confirmado como ALTA — y por los cuatro refutadores que lo atacaron

1. **El reporte inventa las "Devoluciones": pinta 31 donde hubo 6.**
   `docs/reporte.html:501` calcula `devoluciones = cancelados − borrados` en vez de leer
   `r.devoluciones`, que el backend **ya entrega** desde la migración `120` (21/ago). La migración
   arregló el backend y la pantalla nunca se actualizó.
   - Medido: el 29/jul la tarjeta dice **18** y las devoluciones reales son **0** (los 18 son
     cancelaciones a mano, `cancelado_motivo` nulo, ninguna con reembolso de Zettle detrás).
     Histórico completo: pantalla **31**, real **6**. Un `grep` de `devoluciones` en todo `docs/`
     da 4 líneas, las 4 en ese cálculo: `r.devoluciones` y `r.devoluciones_tras_entregar` no se
     leen en ningún archivo del front.
   - Se verificó contra la página **publicada** en GitHub Pages, no sólo contra el repo: idéntica
     byte por byte.
   - ⚠️ **Contradice lo que el `CLAUDE.md §11.15` ya da por hecho** (*"Ahora se cuentan las de
     verdad"*). Es cierto del backend y falso de la pantalla, que es donde el dueño lee. Y el §13
     define una devolución como *"una falla de servicio que se pagó con dinero para no perder al
     cliente"*: está leyendo 31 fallas donde hubo 6.
   - Arreglo: una línea. Es lo primero que hay que subir.

### 🟠 La clase que se arregló ayer y dejó fuera a la tercera pantalla

Tres frentes la reportaron por separado; **es un solo bug**.

2. **Las cuatro alertas del reporte se borran solas cuando el backend falla.** Placas repetidas,
   placas dudosas, fotos pendientes y avisos del sistema: un 500 se pinta **idéntico** a "no hay
   nada que reportar". `pedirJSON` de `docs/reporte.html` es el único ayudante de las tres
   pantallas **sin** la guarda de error que la `105` puso en las otras dos.
3. **El reporte es la única de las tres pantallas sin corte de tiempo.** Una petición colgada la
   deja en blanco para siempre, sin decir nada. El supervisor y la caja ya cortan a los 20 s.

### 🟠 Seguridad — el `revoke` del 19/ago sólo blindó lo que existía ese día

4. **La llave publicable puede ejecutar seis funciones `SECURITY DEFINER` nuevas, cuatro de ellas
   escriben o borran**: `limpiar_crudo_del_webhook`, `limpiar_bitacora_del_cron`,
   `ligar_visitas_de_import`, `anotar_aviso`, `fotos_huerfanas`, `fotos_huerfanas_lista`.
   - **La causa es estructural, no un olvido:** Supabase tiene un `ALTER DEFAULT PRIVILEGES … GRANT
     EXECUTE … TO anon` sobre el esquema `public`, así que **toda función nacida después del revoke
     sale otorgada de nuevo**. De 118 funciones, `anon` alcanza todas menos las 5 que existían el
     19/ago. Va a volver a pasar con cada migración que cree una función.
   - Comprobado contra la API en vivo sin destruir nada (se llamaron con un rango que no alcanza
     ninguna fila).
   - Atenuante medido, y por eso es 🟠 y no 🔴: la llave publicable **no está en `docs/`**
     (0 coincidencias), así que no se puede sacar del repo público.

### 🟠 Lealtad — le está costando lavados gratis a clientes con nombre

5. **La regla de cortesía nunca llegó al import del ClientNoteTracker.** `visitas.es_cortesia` es
   `true` en **1 de 15,068 filas** (la prueba del dueño del 15/ago). El §11.70 dice que una
   cortesía *"ni suma sello ni consume gratis"*, y esa regla vive en `clase_de_gratis()` — que el
   camino de la caja sí consulta y **el del import no**. Es el patrón de siempre: *el camino que no
   llama a la función se brinca la regla*, igual que pasó con `un lavado, un cliente`.
   - Caso con nombre: **`reynaldo inojosa ramirez`**, 33 lavados pagados. Le tocan 6 gratis; tiene
     9 canjes y **0 disponibles**. Cuatro de esos 9 son `Gratis`+`Cortesia`. Sin ellos serían 5 y
     le quedaría **1 gratis disponible** — o sea que el negocio le está debiendo un lavado.
   - Cotejo independiente (22/jul–20/ago): 242 canjes registrados contra 237 lavados `6to`
     realmente vendidos; la diferencia son esas 5 cortesías. `lealtad_por_persona` lo tapa con
     `greatest(0, …)`, y por eso nunca se vio.
   - ✅ **Confirmado: sus dos refutadores lo atacaron y ninguno pudo tumbarlo** (los dos lo dejaron
     en severidad media). Es real y está medido.

### 🔵 Lo demás, agrupado por consecuencia

- **Rendimiento:** `ventas_purchase_number_idx` está construido sobre la forma de payload que la
  `115` declaró equivocada, así que **no sirve a ninguna consulta viva**: buscar un ticket hace
  Seq Scan sobre 2,862 ventas (156 ms). Y su expresión se evalúa en cada `insert` de `ventas`.
- **La regla de escapar comodines vive en `como_literal()` y sólo 1 de las 3 búsquedas la usa.**
  `buscar_personas('%')` devuelve 25 clientes cualquiera y `buscar_personas('LUIS_G')` devuelve 7:
  la cajera puede tocar al cliente equivocado creyendo que es un resultado bueno.
- **Un titular que no cuadra con su tabla** en "Calidad de la entrega": dice 2 rechazos, la tabla
  de abajo suma 3.
- **`anotar_aviso` no se puede apagar:** el reporte muestra ahora mismo una alerta pidiendo
  autorizar el borrado de 176 fotos huérfanas **que ya se borraron anoche**. El primer aviso del
  sistema que existe ya es falso.
- **El canal de avisos se cableó a 2 de los ~80 `console.error`**, y no al modo de falla que lo
  motivó.
- **Corregir de un carro que ya seca le vuelve a poner la hora a las asignaciones** aunque no se
  toque ningún secador.
- **Quitar el tipo o el color en Corregir responde "ok" y no borra nada.**
- **El desglose del carro presenta como medido un secado que el reporte descarta por ser ficción.**
- **En la caja, buscar por apellido esconde clientes sin decirlo** (82 de 107 en el caso medido), y
  justo debajo de la lista recortada está el botón que crea la ficha duplicada.
- **La lista de tickets se congela en silencio** si el backend falla; tras un 401 no vuelve a
  refrescarse en todo el turno.
- **Con el wifi COLGADO (no caído) el aviso "Sin conexión" nunca sale** en la pantalla del
  supervisor: ve cronómetros corriendo con datos de hace media hora.
- **El RUNBOOK del import se contradice:** el paso que de verdad se ejecuta sigue diciendo que la
  zona horaria sale del PDF, que es justo la fuente que el 21/ago se declaró no confiable.

### ✅ Refutados — NO son hallazgos, y vale saber por qué

- ~~"El webhook sólo entiende el aviso envuelto"~~ — **la premisa es falsa**: el proyecto nunca
  afirmó que Zettle mande el aviso plano *por webhook*. Habría sido una falsa alarma grande.
- ~~"La bitácora del webhook no guarda el cuerpo crudo"~~ — se **bajó el artefacto desplegado** de
  la función viva (v12 ACTIVE) y sí manda el cuerpo. Repo y producción coinciden.
- ~~"Storage se rompe a 173 carros/día"~~ — la aritmética cuadra, pero ya está en esta bandeja dos
  veces y la retención de 60 días se escogió **sabiendo** este escenario.
- ~~"Al chocar la placa se tira también marca y submarca"~~ — es una **decisión deliberada**,
  escrita en el encabezado de la migración `100`: *"la foto entera es sospechosa"*.
- ~~"El CRM vuelve a ir atrás"~~ y ~~"la única devolución cae en el día sin recongelar"~~ —
  refutados por dos vías medidas cada uno.
- ~~"`webhook_descartados_del_rango` no la llama nadie"~~ — cierto, pero **ya estaba en esta
  bandeja** desde el 20/ago. No es nuevo.

### ✅ Comprobado SANO — no volver a auditar

- **0 ventas perdidas: 2,861 tickets consecutivos de Zettle (24503 → 27363), sin un solo hueco.**
- 🔑 **La firma de Zettle SÍ llega y ya se puede deducir:** `x-izettle-signature` (SHA-256, 64 hex)
  presente en **160 de 160** avisos buenos, con el cuerpo crudo guardado. **Esto desbloquea el
  pendiente más viejo del proyecto** — ya no hay que adivinar el esquema.
- `/respaldo` recorrido completo contra la API: **37,260 renglones en 11 tablas**, todas cuadran
  con el manifiesto.
- El borrado de anoche **no se llevó ninguna foto viva**: 2,626 archivos para 2,626 carros con
  foto, 0 huérfanas.
- 33 de 34 reportes congelados salen idénticos a un recálculo fresco (el 19/jul difiere por lo ya
  documentado).
- 0 drift en las columnas generadas sobre 2,821 carros; 0 etapas abiertas en carros entregados;
  0 carros con dos dueños activos en 15,068 visitas; 0 no-express en la línea 1.
- 6 crones activos, **0 corridas fallidas en 7 días**. La retención de `cron.job_run_details`
  funcionó: de 14 MB / 80,913 corridas a 3.3 MB / 19,627; la base de 81 a 71 MB.
- `/cola`, la consulta que se dispara cada 3 s: Index Scan, **0.111 ms**. No es un problema de
  escala.
- La retención de fotos dice **60 en los tres lugares** donde vive el número.
- Los umbrales de rojo y `BORRAR_UMBRAL` coinciden exactamente entre el front y la base.
- Todo lo que se pinta con `innerHTML` en la pantalla del supervisor pasa por `escapar()`.
- 🔑 **`obtenerStream()` de la caja NO cae sola a la cámara del tablet.** La auditoría del 20/ago
  se equivocó ahí, quedó anotado en la skill, y **este pase lo confirma otra vez**.

### 🙋 Lo que necesita tu palabra, no trabajo mío

1. **`Faros` $600 se cobró el 21/ago y nunca apareció en el teléfono del supervisor.** Está en la
   categoría `Extras`, que no crea carro. Las otras 8 ventas sin carro del periodo son mostrador
   legítimo (Pinito, aromas, diferencias de precio). **¿El servicio de faros se hace sobre el carro
   del cliente?** Si sí, hay que sacarlo de `Extras`.
2. **Las fotos pegadas al carro equivocado se cuadruplicaron el 21/ago:** 6 de 97 (6.19%) contra
   14 de 1,071 (1.31%) en las dos semanas previas. Al menos uno **no es error**: dos tickets del
   mismo vehículo con 2 minutos de diferencia (Encerado $800 + Completo $300, la misma GMC Sierra
   blanca) — o sea que el candado también produce falsos positivos cuando la caja parte un
   servicio en dos cobros. **¿Se parten seguido?**


### 🧭 El crítico de completitud — lo que ningún frente miró

Corrió al final, con el inventario de los once frentes enfrente y una sola pregunta: **qué falta.**

> 🔴 **Y de entrada, una corrección al propio crítico.** Su hallazgo principal decía que *"el CRM
> volvió a quedarse atrás 24 horas después de arreglarlo, la misma forma exacta de la falla de
> cinco días"*. **Es falso, y su refutador lo demostró midiendo.** El hueco del 21/ago está escrito
> como esperado en esta misma bandeja (*"falta el 21, el día no había cerrado cuando el dueño mandó
> el export"*): el import es un lote post-cierre, así que un CRM al día **tiene** que mostrar el día
> en curso en cero. Y el mecanismo de los cinco días —la `114` tumbando el bloque entero— sí se
> arregló: `ligar_visitas_de_import()` está viva en producción y `registrar_visita` ya no existe.
> Decir que no cambió invierte el resultado del trabajo del 21/ago.
> **Lo que sí queda en pie de ahí:** sigue sin existir un detector que avise si el import se
> atrasa, y **la caja lleva 4 días en cero** después de que el dueño dijo el 19/ago que sí se iba a
> usar. Eso es seguimiento de una decisión suya, no un hallazgo.

Lo que aportó de verdad:

1. 🟠 **Nadie había corrido el portón de despliegue, y una de sus pruebas no puede fallar.**
   El crítico corrió `bash pruebas/correr.sh` completo: **13 grupos, TODO PASÓ**. Pero el grupo que
   se agregó el 21/ago para cerrar el hallazgo #3 de la auditoría anterior —el dry-run real del
   import— corre sobre `stg_cnt`, que hoy tiene las 240 filas del export **ya importadas**. El dedup
   las descarta todas, así que **el INSERT se ejercita con cero filas** y la aserción es un
   `grep -q DRYRUN` que sale igual con 0 que con 240.
   - Medido: `stg_cnt` tiene 240 filas y `insertaria_el_dryrun = 0`.
   - El `pruebas/README.md` tiene su propia regla para esto: *"una prueba que no puede fallar no
     sirve"*. Lo que sí queda cubierto es el bug de la `114`: `ligar_visitas_de_import()` corre de
     verdad sobre 12,817 visitas sin ligar.

2. 🟠 **El rescate de una venta perdida no sirve si lo perdido fue una DEVOLUCIÓN.**
   `scripts/4-recuperar-venta.ps1` es el camino que el `CLAUDE.md §7` nombra para rescatar una venta
   que no llegó por webhook. Para una venta normal **está sano y se comprobó**. Pero la respuesta de
   `purchase/v2` **no trae `refundsPurchaseUuid`** —trae `refund` y `refunded`—, y **tres funciones
   vivas cuelgan de esa llave exacta**.
   - Consecuencia: se rescata una devolución, `crear_carro_desde_venta` no la reconoce, **no cancela
     el carro original** (se queda en la cola como si el cliente siguiera esperando) y
     `reporte_del_rango` no la cuenta — justo el número que la `120` acaba de poner honesto.
   - El síntoma es silencioso: el monto negativo evita crear un carro nuevo, así que nada truena.
   - Medido contra la venta real del ticket 27363: las 70 llaves de la respuesta REST no incluyen
     `refundsPurchaseUuid`.

3. 🔵 **`.env.example` ya no dice todas las llaves que producción necesita.** Faltan
   `REOLINK_IP/USER/PASS`, y `relectura_token` y `limpieza_token` no aparecen en ningún archivo del
   repo. Quien reconstruya en otra máquina se queda **sin cámara y con el obrero de relectura
   respondiendo 401** — que es exactamente el modo de falla del 17/ago, y ninguno de los dos avisa.

### ⚠️ El límite de esta auditoría, dicho de frente

**Nadie ejecutó una sola pantalla en un navegador.** Tres frentes lo dicen explícitamente. O sea que
**todos los hallazgos de carrera del front** —el supervisor atrapado en Finalizados, el cronómetro
que sigue corriendo, la foto que se borra sola, el aviso de "sin conexión" con el wifi colgado— son
**lectura de código, no comportamiento observado**. El proyecto ya tiene la técnica (el 19/ago se
verificó el front del reporte interceptando `pedirJSON`) y no se usó esta vez. Hay que probarlos
antes de arreglarlos.

Tampoco se revisaron: el relay go2rtc + Tailscale y la cámara Reolink (fuera del repo y de la base),
seis de los siete scripts `.ps1`, y **las pruebas en sí mismas** — la suite está verde, pero que esté
verde por la razón correcta sólo está comprobado en `import-cnt.sql`.

### ✅ Lo que el crítico agregó a comprobado sano

- **La suite completa pasa hoy:** 13 grupos, 11 pruebas SQL contra producción.
- **Lo publicado es byte a byte lo del repo:** md5 idéntico en los 4 archivos de GitHub Pages, y
  `HEAD == origin/main`.
- **La suscripción de Zettle está viva y correcta:** una sola, `ACTIVE`, `PurchaseCreated`, al
  destino correcto — y **el `signingKey` que devuelve Zettle hoy es idéntico al guardado**, o sea
  que no se rotó y la firma sigue siendo implementable.
- **El corte de las 8:30 PM sigue teniendo margen:** 0 carros creados después de las 20:30 en toda
  la historia.
- **El congelado de anoche corrió** pese a que se desplegó con el taller casi cerrado.
- **`anotar_aviso` sí deduplica** (probado y revertido).

### 🙋 Preguntas nuevas del crítico

- **¿"Devoluciones" debe contar sólo los reembolsos de Zettle** (6 en toda la historia) y rotular
  aparte las 25 cancelaciones a mano, o prefieres seguir viendo el total de cancelaciones con otro
  nombre?
- **¿Los avisos del sistema deberían poder marcarse como atendidos**, o basta con que caduquen a los
  7 días?
- **¿Se recongela el 19/jul** con la función de hoy (perdería la deriva histórica de su secado
  promedio, 2130 contra 2191) o se deja como está?
- Dato suelto sin explicar: hay **8 ventas después de las 20:30** en toda la historia contra 0 carros
  creados a esa hora. Podrían ser devoluciones o extras de mostrador; no se abrieron.

---

## ✅ HECHO el 21/ago/2026 — el CRM revivió (migración `118`)

Los **tres puntos rojos** de la auditoría del 20/ago están cerrados. Detalle y razones en
`CLAUDE.md §11.25`; el flujo actualizado, en `scripts/importar-clientnotetracker/RUNBOOK.md §4e`.

- ✅ **El índice de la `114` ya no rompe el import.** El ligado vive en
  `ligar_visitas_de_import()`, una sola función que los tres scripts llaman: respeta el candado
  de "un lavado, un cliente", desempata determinista cuando dos visitas se pelean un lavado, lee
  el `purchaseNumber` con `detalle_venta()` (antes se perdía en silencio el aviso plano), y si
  algo chocara pierde los **enlaces**, nunca las **visitas**. Lo no ligado queda en
  `imp_ligado_conflictos`, no en silencio.
- ✅ **El CRM está al día hasta el 20/ago.** 240 visitas, 36 canjes, 229 ligadas; el cotejo día
  por día cuadra exacto. Falta el 21 (el día no había cerrado cuando el dueño mandó el export).
- ✅ **La suite ya cubre el import.** `pruebas/import-cnt.sql` (8 grupos, reproduce el bug viejo
  antes de comprobar el nuevo) + el dry-run real corriendo dentro de `pruebas/correr.sh`.
- 🔴 **Hallazgo nuevo: el export cambió de zona horaria** (`America/Ciudad_Juarez` en vez de
  `America/Tijuana`, una hora adelante). La zona ahora viaja en `stg_cnt.tz`.

### Lo que quedó para el dueño de esta misma tanda

1. **11 lavados que dos clientes reclaman** (`select * from imp_ligado_conflictos`) — todos de
   julio y principios de agosto, ninguno del export nuevo. Las visitas están intactas; lo único
   que falta es decidir de quién es cada lavado. Es la misma clase de los **164 tickets** que
   siguen abiertos.
2. ~~**11 posibles renombres por esqueleto de consonantes**~~ ✅ **RESUELTO (21/ago): el dueño
   autorizó los 9 limpios y quedan fuera los 3 dudosos.** Ver `CLAUDE.md §11.25`.
   > **Siguen sin resolver, a propósito:** `ARTURO CONTRERAS` → `VICENTE ARTURO CHAVARI
   > CONTRERAS` (falso probable), `JAVIER MEZA` (empata con `JAVIER CHAVEZ MEZA` **y**
   > `JAVIER MONTAÑO MEZA`) y `LUIS VARGAS` (tres candidatos). No se tocan sin evidencia nueva.
3. ~~**Las 1,452 placas "por confirmar"**~~ ✅ **RESUELTO (21/ago): el dueño dijo quitarlas,
   sigue mandando "1000% o nada".** Borradas; quedan **213 confirmadas** (corroboración de 2+
   carros) más las 6 sugeridas que ya existían de antes del import. **El RUNBOOK se corrigió**
   para que el helper de la `086` no se vuelva a correr desde el import — si no, el próximo las
   metía otra vez.
4. ~~**El 20/ago sólo tuvo 28 lavados**~~ ✅ **RESUELTO (21/ago): día nublado, casi no hubo
   trabajo.** No es la app ni la captura. Vale tenerlo presente al leer ese día en el reporte: un
   día de 28 lavados no se compara contra uno de 84, y sus promedios salen de muy poca muestra.

## ✅ DESPLEGADO el 19/ago/2026 (migraciones `109`–`117`)

Se fue completo y verificado en vivo. El detalle y las razones viven en `CLAUDE.md §11.40`; aquí
sólo queda el rastro para no volver a levantarlo:

- **Backend:** `editar_carro` ya no escribe antes de validar (#17), `guardar_datos_de_foto` ya no
  borra lo que no leyó (#18), y `/foto` limpia `placa_en` para que una re-toma sí entre a la cola
  de relectura (#19).
- **Reporte del dueño:** el perfil del trabajador se pagina (134 kB → 19 kB) y se filtra por días
  y por tipo de servicio; los otros cuatro puntos y los cinco menores del archivo.
- **Cuarta tanda (`111`, solo base):** un error creando el carro ya no tumba la VENTA y queda escrito en la bitácora (#24); el índice de `asignaciones` (9.2 ms → 1.6 ms); la caja deja de escribir la placa cruda y respeta el candado de placa repetida; `desenlazar_visita` ya no borra la foto del supervisor ni el cliente de la nota; `cerrar_pendientes` alcanza al carro que entra después del corte.
- **Quinta tanda (`112`–`114`):** un lavado, un cliente. Se resolvieron los 14 lavados reclamados por dos clientes, se quitaron 6 sellos dobles y 440 tickets que no eran tickets, y el candado quedó en la base (`visitas_un_lavado_un_cliente`). Ver `CLAUDE.md §11.35`.
- **Sexta tanda (`115`–`117`):** retención de fotos a 60 días; `ventas_indexar` deja de desarmar el payload a mano (ventas invisibles 1 → 0); las búsquedas del CRM de 898 ms a 59 ms; `sincronizar-jibble` con candado y cada 5 min; `encimados` con ventana de 24 h; y del rechazo de entrega ya hay regreso. Ver `CLAUDE.md §11.30`.
- **La auditoría general quedó como skill** (`.claude/skills/auditoria-general/`): se dispara
  diciendo *"corre la auditoría general"* y arranca cuestionando su propio método.

Verificado contra la API en vivo después de cada tanda: `/cola`, `/reporte`, `/tickets` y
`/personas` en 200, y la suite completa en verde. La última tanda SÍ toca la pantalla del
supervisor (el botón de regreso del rechazo) y se subió con el taller abierto **a pedido expreso
del dueño** — la regla de §2 sigue siendo esperar al corte cuando no lo pide.

### ✅ Las decisiones del dueño, tomadas el 19/ago/2026

- **Retención de fotos → 60 días.** Aplicado en los tres lugares donde vivía el número.
- **Segundo código de acceso → se queda igual** (*"no importa"*). Cerrado por decisión.
- **Los tres días de abandono (6, 10, 11/ago)** → *"solo había un supervisor y estaba en su hora
  de comida"*. No es captura ni entrenamiento: es cobertura. Nada que arreglar.
- **El rechazo de entrega** → *"haré énfasis, pero es raro que se rechace"*. Se arregló el botón
  de todos modos: si el número va a ser cero, que sea porque no hubo rechazos.
- **La caja SÍ se va a usar**, y quiere el CRM bien estructurado — *"incluso se puede usar sin la
  lectura de placas"*. Por eso entraron los índices de búsqueda.

## 🔬 AUDITORÍA GENERAL DEL 20/ago/2026 — 8 frentes con pase adversarial

Corrida con la skill `auditoria-general` orquestada con `Workflow`: **16 agentes, 53 hallazgos,
~42 min**. Novedades del método frente a la del 19/ago: un **octavo frente dedicado al código
escrito ese día** (migraciones 105–117, con instrucción de tratarlo como sospechoso y de no
creerle a los comentarios), un **verificador adversarial** por hallazgo grave, y un **crítico de
completitud** que buscó lo que nadie revisó.

**El pase adversarial no refutó ninguno, pero bajó la severidad de 4 de 8 graves** (dos a `baja`,
dos a `media`). Eso es el pase haciendo su trabajo: sin él, cuatro números inflados habrían
entrado al informe como urgentes.

### ✅ LO QUE HABÍA QUE ATENDER YA — LOS TRES, HECHOS EL 21/ago (migración `118`)

> Detalle y razones en `CLAUDE.md §11.25`; el flujo, en el `RUNBOOK.md §4e`. Resumen: el ligado
> del import vive ahora en una sola función que respeta el candado de la `114`; se importaron las
> 240 visitas del 17 al 20/ago (cotejo día por día exacto); y la suite ya cubre el import con
> `pruebas/import-cnt.sql` más el dry-run real. Salieron dos hallazgos nuevos de paso: el export
> cambió de zona horaria y el ligado leía sólo el aviso envuelto de Zettle.
>
> Lo de abajo se conserva **tal como lo reportó la auditoría**, para no perder el diagnóstico.

1. **El CRM lleva CUATRO DÍAS sin registrar una sola visita.** La última es del **16/ago**; hoy
   es 20. Medido: **248 lavados sin sello** y **35 gratis entregados sin descontar** en esos
   días. Los sellos entran por el import y los canjes se honran en el mostrador, así que
   `disponibles` (240 hoy) sólo sube: es pasivo contra el negocio, creciendo solo. **Lo encontró
   el crítico de completitud, no los frentes** — ninguno tuvo como sujeto los datos de la
   operación.
2. **🔴 El índice único que se puso el 19/ago (migración `114`) rompe el import del
   ClientNoteTracker.** Lo hallaron DOS frentes independientes, el escéptico lo reprodujo contra
   producción y se confirmó a mano: **21 visitas** quedaron con `carro_id` nulo y `caja='import'`,
   el paso 2 del import las vuelve a ligar, choca con `unique_violation`, y como el script es un
   `do $$` sin manejador **se cae el bloque entero: no entra nada**. Es la tubería que carga
   14,804 de las 14,828 visitas. Los dos puntos se juntan: el CRM está muerto y el arreglo para
   revivirlo está bloqueado por el candado que se puso ayer.
   *Arreglo:* que el paso de ligado excluya los carros que ya tienen visita activa y desempate
   cuando dos visitas compiten por el mismo carro — o mejor, que el import llame a
   `enlazar_visita_a_carro`, que ya trae la comprobación (es justo lo que el encabezado de la
   `114` dice que faltaba).
3. **La suite de pruebas no cubre el import.** `bash pruebas/correr.sh` habría dicho TODO PASÓ
   justo antes de romperlo, porque no hay una sola prueba de la tubería que carga el 99.8% de las
   visitas. La suite protege lo ya arreglado, no lo que está por romperse.

### ✅ TODO LO DE ABAJO SE HIZO EL 21/ago (migraciones `119`–`126`)

> Se subió **todo el mismo día, con el taller abierto**, a pedido expreso del dueño. El
> detalle y las razones viven en `CLAUDE.md §11.15` y `§11.20`. Lo que queda abierto son
> sólo las decisiones suyas, listadas al final de esta sección.
>
> Se conserva el diagnóstico original tal como lo reportó la auditoría.

### 🟠 La clase que hay que arreglar como clase, no como seis bugs

Seis hallazgos en cuatro frentes son **el mismo patrón**: un error del backend se pinta como
ausencia de datos (`/cola`, `/entregados`, `/secadores`, el buscador de la caja, el reporte del
dueño, "Ver 50 más"). La migración `105` arregló al **productor** (`json()` marca `ok:false`) y
dejó intactos a **todos los consumidores**, que siguen leyendo `d.algo || []`. Presentado como
seis bugs se arreglan seis líneas y el séptimo consumidor nace igual la semana entrante; se
arregla en el ayudante `pedirJSON` de cada pantalla.

### 🟠 Lo demás, por frente (severidad ya corregida por el escéptico)

- **Base:** `enlazar_visita_a_carro` borra marca/submarca sin la regla "un nulo no borra" que la
  `109` sí le puso a `guardar_datos_de_foto` — misma causa que el de `desenlazar_visita`;
  `importar_personas()` es un arma cargada que nadie llama; la regla de cortesía vive en una sola
  de las dos funciones que registran visitas; **164 tickets siguen reclamados por dos clientes**
  (334 visitas, ~170 sellos de más) — el pendiente que quedó abierto por decisión.
- **API:** `/cola` descarta el error de sus dos consultas secundarias y sale 200 incompleta;
  falta `Access-Control-Max-Age` (la mitad de las invocaciones son preflights); cinco rutas
  muertas, una de ellas reabre la fuga de lealtad que el rediseño del 15/ago cerró.
- **Fondo:** el candado de `sincronizar-jibble` que se puso hoy **es inerte** (lock de
  transacción + llamada asíncrona: nunca puede impedir el solape que dice impedir); si un grupo
  de Jibble se vacía, 3 de 15 personas desaparecen sin un error; la `108` quedó a medias (la
  función que cuenta descartes no la llama nadie); la bitácora guarda la firma pero **no los
  bytes que la firma cubre**, así que el pendiente de la firma de Zettle no se puede cerrar con
  lo que se está guardando.
- **Supervisor:** dos respuestas de `/cola` en vuelo y la vieja pisa a la nueva; "Entregar" y
  "RECHAZAR" no dan señal mientras viaja la petición y tragan los toques; el outbox de fotos se
  rinde a los ~30 min, borra la foto y sólo lo dice en la consola.
- **Caja:** sin corte de tiempo (una petición colgada mata todos los botones); si falla la
  lectura, `captura` conserva la foto y la placa del carro ANTERIOR; la lista de tickets no dice
  el día, así que al abrir se ven los de ayer; `upsert_persona` sólo deduplica por teléfono y
  4,917 de 4,918 personas no tienen.
- **Reporte:** "Devoluciones" cuenta 31 cancelaciones que nunca fueron un reembolso (y la señal
  que el dueño sí pidió —la devolución DESPUÉS de entregar— no existe); la `107` quedó a medio
  desplegar (31 de 32 días congelados sin los campos que la arreglan); Trabajadores no aplica el
  filtro de `tiempo_imposible`.
- **Costos:** Storage es lo primero que se rompe, punto de quiebre ~171 carros/día — **y hay
  1.08 fotos por carro, no 1**: 175 archivos (15 MB) que no apunta nadie, del botón "Tomar foto
  otra vez". `cron.job_run_details` ya es el **21% de toda la base** (16 de 76 MB).

### 🕳️ Lo que el crítico encontró que NADIE revisó

- ~~**No hay respaldo.**~~ ✅ **HECHO el 21/ago.** `/respaldo` baja las 11 tablas del negocio
  (**37,245 renglones**, ~35 MB), paginado, con manifiesto que dice qué trae y **qué no**. La
  prueba `pruebas/respaldo-completo.sh` cachó que PostgREST recorta en 1,000 filas sin avisar:
  `etapas` se respaldaba **al 12% y se veía completa**. Ver `CLAUDE.md §11.20`.
  > Sigue pendiente lo que el respaldo **no** puede cubrir por tamaño: las **fotos de Storage**
  > (~290 MB). Hoy la única red es que caducan a 60 días de todos modos.
- **`carros.placa_dudosa`**: tres funciones la escriben, **cero código la lee**. Hay 14 carros
  marcados y no hay ninguna vía en el producto para revisarlos. La red caza el problema y
  entierra la evidencia.
- **La infraestructura que no es un archivo del repo**: el relay go2rtc+Tailscale, la Reolink, la
  suscripción del webhook, las credenciales de Jibble. Si el relay se cae, `obtenerStream()` cae
  **sin aviso** a la cámara del tablet, que no apunta al carro.
- **El backlog del 3/ago seguía abierto** y predecía exactamente el hallazgo de hoy sobre "el
  tipo sale de la submarca" duplicado. Una auditoría que no arranca leyendo el backlog vuelve a
  encontrar lo mismo con otro nombre.

### ✅ Lo comprobado sano (no re-auditar)

0 drift en las 3 columnas generadas sobre 2,724 carros · las 7 `SECURITY DEFINER` con
`search_path` fijo y `anon` sin alcance a ninguna sensible · 35 tablas con RLS y 5 vistas
`security_invoker` · 0 sobrecargas ambiguas en 118 funciones · las migraciones 112–117 de verdad
aplicadas en la base · la cola de relectura en cero por los tres lados · 0 corridas de cron
fallidas en 7 días · 0 etapas abiertas en carros entregados, 0 negativas, 0 placas sin
normalizar · el webhook con 61 bitácoras 'ok' contra 61 ventas y **0** `trigger_carro_fallo` ·
0 no-express en la línea 1.

### ✅ Las tres decisiones del dueño (21/ago, la misma noche)

1. ~~**176 fotos huérfanas (16 MB)**~~ ✅ **BORRADAS.** *"bórralas"*. Quedó **2,802 → 2,626
   archivos, 267 MB → 252 MB**, cero huérfanas. Comprobado después: los **2,626 carros con foto
   siguen teniendo su archivo**, ninguna foto viva se perdió.
   > El borrado NO es automático: vive tras `?huerfanas=1` en `limpiar-fotos`, y el cron sigue
   > barriendo sólo por EDAD. La lista lleva **gracia de 1 hora** porque `/foto` sube el archivo
   > y *después* escribe `carros.foto_path`: entre esas dos cosas una foto viva se ve huérfana.
2. ~~**164 tickets con dos dueños**~~ → **se ignoran**: van a desaparecer con el borrón y cuenta
   nueva del CNT (abajo).
3. ~~**Los 3 renombres dudosos**~~ → **se ignoran**, por lo mismo.

### 🔵 LO QUE QUEDA ABIERTO

1. 🔑 **BORRÓN Y CUENTA NUEVA DEL CNT, cuando el dueño lance el reporte nuevo.** Instrucción suya
   del 21/ago: *"quiero borrar absolutamente todo y hacer un import de cero del CNT y ligar con
   las fotos que ya tenemos"*, y **completo** — *"no como la vez pasada que por decisión tuya no
   lo hiciste"*. Con eso se van los 164 tickets con dos dueños y los renombres pendientes.
   El procedimiento vive en `RUNBOOK.md` §4 (RESET) y §4e; **releer §3.1 antes: la zona horaria
   del export cambia**. Detalle y límites en la memoria `cnt-borron-y-cuenta-nueva`.
2. **La firma de Zettle ya se puede empezar.** Estaba bloqueada porque la bitácora guardaba la
   firma sin los bytes que cubre; eso se arregló. Con unos días de avisos reales guardados se
   puede deducir el esquema — y hasta entonces **no se implementa adivinando**, porque una firma
   mal calculada rechaza ventas de verdad.

### 📌 Autocrítica del método (para la próxima corrida)

- **Falta un frente de DATOS DE LA OPERACIÓN.** Los 8 fueron 7 superficies de código más costos,
  y por eso los cuatro días de CRM muerto los encontró el crítico y no un frente. **Hay que
  agregarlo a la skill.**
- **Frentes flojos:** supervisor (3,069 líneas, 6 hallazgos, ninguno alto — la densidad más baja
  de todos) y costos (4 de 6 hallazgos son ecos de otros frentes).
- **7 duplicados** entre frentes: el reparto por archivo hace que un bug que cruza dos archivos
  se cuente dos veces y con severidades distintas.
- **El escéptico no refutó nada pero corrigió 4 severidades de 8.** Vale la pena; el siguiente
  paso es que también verifique los `media`, que es donde se acumularon los 53.

---

## 🔬 (ANTERIOR) AUDITORÍA DEL 19/ago/2026 — 46 hallazgos

> ✅ **Los 7 PRIORIZADOS ya están hechos y desplegados** (migración `105`, commit `9904fe3`).
> Ver `CLAUDE.md §11.50`. Lo que sigue abajo con ✅ ya no requiere trabajo; lo que sigue sin marca
> es la deuda que el dueño dejó fuera del alcance de hoy.

Siete revisiones en paralelo sobre todo el código (base, API, las tres pantallas, funciones de fondo,
costos). **Nada se tocó: fue de solo lectura.** Lo marcado ✔ se comprobó a mano contra la base de
producción, no solo se leyó.

> **El patrón de fondo, que es lo que hay que arreglar de verdad.** Los 46 hallazgos son cuatro
> causas repetidas: **regla duplicada que divergió** (6), **error que se responde como éxito** (5),
> **trabajo a medio terminar** (3) y **dato viejo que envenena un cálculo** (2). Ninguna se atrapa
> leyendo mejor el código; las cuatro se atrapan con una **suite de regresión que se corra antes de
> cada despliegue**. Ver el último punto.

### 🔴 Rompen algo hoy

1. ✅ **HECHO 19/ago.** El contador de "encimados" lleva 25 días mintiendo sobre dos personas. La CTE `encimados`
   de `reporte_del_rango` no filtra `cancelado_en`. Los carros **515 y 516** (24/jul, cancelados al
   descontrolarse la cola, `entregado_en` nulo) tienen asignación a **Jorge Luna** y **Jaime
   Gallegos**, y los dejan "ocupados para siempre". Medido el 16/ago: Jorge 7/7 (100%) → **1/10
   (10%)**; Jaime 6/6 → **1/9 (11%)**. Acumulado: **201 de 935 encimados son falsos (21%)**.
   🔴 **Invalida lo escrito en §11.65 y §11.75** sobre esas dos personas ("es posición o forma de
   asignar", "su secado no se puede comparar contra el de nadie", "el mejor dato del fin de semana
   estando siempre saturado"). **No estaban saturados.**
   *Arreglo:* `and c2.cancelado_en is null and not c2.es_prueba`; cerrar 515/516; re-congelar desde
   el 26/jul (solo cambia `encimados`, el secado no).
2. ✅ **HECHO 19/ago (se RECHAZA, decisión del dueño).** La caja podía regalar un lavado y quitarle al cliente el que sí ganó.
   `registrar_visita_con_carro` **no verifica saldo**; la vieja `registrar_visita` **sí** — regla
   duplicada divergente. `lealtad_por_persona` tapa el descubierto con `greatest(0, …)`. Hoy hay
   **26 personas con canjes > ganados** (déficit 31 sellos), todas del import, pero el camino sigue
   abierto. **Decisión del dueño**: ¿se rechaza o pasa y queda anotado?
3. ✅ **HECHO 19/ago.** Un error 500 vaciaba la cola en pantalla y apagaba el aviso. `docs/index.html:1311`
   `carros = d.carros || []` seguido de `avisarError(false)`. El supervisor lee "No hay carros en
   proceso" sin señal de falla, y al volver el servicio los 15 carros vuelven a sonar como nuevos.
4. ✅ **HECHO Y DESPLEGADO 19/ago.** Los errores del backend no llevaban `ok:false` y los tres fronts los leían como éxito.
   401/500/400/405/503. En caja: "listo, siguiente cliente" con la visita sin registrar (la fuga de
   lealtad reintroducida por el **formato** de la respuesta). En supervisor: "Entregado" se cierra
   como si hubiera funcionado. *Arreglo de una línea:* que `json()` agregue `ok:false` cuando
   `status >= 400` — cubre las 33 rutas.
5. ✅ **HECHO 19/ago (migración 106).** El perfil de Trabajadores mostraba minutos fabricados como medidos. `perfil_de_secador` no
   excluye `cerrado_automaticamente` ni secados < 3 min, que el resto del reporte sí excluye.
   Visibles hoy: carro 2164 = **298 min** (Saul Ramirez), 2121 = **180 min** (Jaime Gallegos). Y 99
   carros históricos de < 3 min salen como "0/1/2 min". Es la pantalla donde se evalúa a una persona.

### ⏰ Bombas con fecha

6. ✅ **HECHO 19/ago (cron jobid 7).** El obrero de relectura nunca había corrido. Faltaba desplegar `app`, crear
   `relectura_token` en Vault y agendar el cron. `placa_intentos = 0` en los 2,654 carros. Y
   `/fotos-pendientes` da 404, que el reporte lee como cero: **la alerta no aparecería nunca.**
   👉 Es trabajo mío a medio terminar. Pasos en `scripts/releer-fotos/DESPLIEGUE-104.md`.
7. ✅ **HECHO 19/ago (tope de 1,000 por corrida).** `limpiar-fotos` nunca había borrado nada; su primera corrida real serían ~7,400 archivos. 21
   corridas, 0 archivos (la más vieja tiene 31 días, el umbral 90). Primera real ~**17/oct/2026**:
   ~15 tandas en una invocación contra el límite de tiempo. Si se corta, quedan ligas muertas.
   *Arreglo:* tope por corrida y **probarlo antes de octubre**.
8. ✅ **HECHO 19/ago (60 días, decisión del dueño; migraciones 115 y 117).** Storage es el límite que se rompe primero.** 251 MB hoy, +8.5 MB/día → **765 MB en régimen
   (77% de 1 GB)**. A 150-200 carros/día **no cabe**. Bajar la retención de 90 a 60 días lo deja en
   510 MB — decisión del dueño (¿para qué sirven las fotos viejas?).
9. ✅ **HECHO 19/ago (rechazado en los dos lados).** Un 200 con lista vacía de Jibble marcaba a TODA la plantilla como "fuera". El guard solo
   cubre el fallo duro. Y un `id` nulo desactiva la barrida entera: `'a' <> all(array['b',null])`
   devuelve **NULL**, no true (verificado en la base), así que nadie se marca fuera nunca.

### 🔒 Seguridad

10. ✅ **HECHO 19/ago (el revoke iba a PUBLIC, no a anon).** `anon` ejecutaba 7 funciones `SECURITY DEFINER` y leía las 5 vistas. Entre ellas
    `olvidar_fotos_viejas` (con `p_dias:=0` deja sin foto a todos los carros) y
    `sincronizar_empleados`. Las vistas no son `security_invoker`, así que brincan RLS:
    `historial_placas` (placas+clientes+dinero de 2,641 carros) y `lealtad_por_persona` (4,919
    saldos). **Atenuante: la llave `anon` NO está en el repo.** *Arreglo:* `revoke execute` +
    `security_invoker=on`. No afecta a la app (usa `service_role`).
11. ✅ **CERRADO POR DECISIÓN DEL DUEÑO 19/ago: se queda igual** (*"no importa"*). Un solo código abre las tres apps. El del supervisor alcanza `/respaldo` (todo el
    histórico), `/personas` (4,871 con teléfono), `/tickets` (todas las ventas) y editar clientes.
    Vive en el `localStorage` de un teléfono que rota entre turnos.
12. 🟠 **PARCIAL 19/ago.** Se cerró el descarte en silencio (bitácora, migración 108) y se están guardando las cabeceras de un aviso bueno para aprender el esquema. **La verificación NO se implementó**: no hay documentación pública confiable y adivinarla rechazaría ventas reales. El webhook de Zettle no verifica la firma. La URL se deduce del repo público → se pueden
    **inyectar ventas falsas**. NO puede cancelar carros reales (el `purchase_uuid` nunca sale por
    la API), NO duplica (unique) y NO lee datos. `ZETTLE_SIGNING_KEY` ya está guardada sin usarse.

### 📊 Números que no cuadran (reporte del dueño)

13. ✅ **HECHO 19/ago (migración 107).** En el día en curso el desglose sumaba más que el total. "Vehículos lavados" cuenta entregados;
    "con/sin aspirado" cuenta todos. Hoy: titular **25**, desglose **29**. En días congelados cuadra
    → el error **solo aparece cuando se mira el día en curso**.
14. ✅ **HECHO 19/ago.** El encabezado de sección no cuadraba con su tabla, y el faltante era la señal. El 11/ago:
    encabezado **22 carros**, tabla **15**. Los 7 que faltan son los que nunca se asignaron — el
    peor día de abandono del mes, y la pantalla no lo dice.
15. ✅ **HECHO 19/ago (se parte en dos).** "Secado promedio general" mezclaba express con completos, lo que el resto del reporte prohíbe.
    13/ago 29.8 min (39% express) contra 17/ago 39.8 min (24%): los extremos son la mezcla, no el
    taller.
16. ✅ **HECHO 19/ago (sección propia).** Rechazos, `rechazos_por_secador` y `cancelados` se calculaban y nunca se pintaban. La `083` dice
    textualmente de los cancelados *"que no desaparezcan en silencio"* — y desaparecen.

### 🔧 Backend

17. ✅ **HECHO 19/ago (migración 109).** `editar_carro` escribía antes de validar. El `update` va ANTES de los tres checks de
    secadores, y un `return` en plpgsql **no revierte**: el color se guarda aunque el guardado
    "falle" por dejar 0 secadores.
18. ✅ **HECHO 19/ago (migración 109).** `guardar_datos_de_foto` borraba lo que venía nulo, contradiciendo la "aceptación parcial por
    campo" de §9: una re-toma que no saca marca **borra la marca buena anterior**. Con el botón
    "tomar foto otra vez" (103) esto se dispara solo.
19. ✅ **HECHO 19/ago (desplegado).** `/foto` no limpiaba `placa_en` al subir foto nueva, así que una re-toma **nunca** entra a la
    cola de reintentos (`fotos_por_leer` exige `placa_en is null`). Justo el flujo de las pickups.
20. ✅ **HECHO 19/ago (se dropeó la vieja).** `buscar_tickets` tenía dos sobrecargas y la llamada de 2 argumentos revienta con `42725`.
    La `098` agregó en vez de reemplazar — la lección exacta de la `052`. *Arreglo:* `drop` la vieja.
21. ✅ **HECHO 19/ago.** `trabajadores()` y `perfil_de_secador()` contaban rechazos con `count(*)`; el reporte con
    `count(distinct grupo)`. Un rechazo con 2 motivos dará 2 en un lado y 1 en el otro (bug de la
    `036`, arreglado solo en el reporte).
22. ✅ **HECHO 19/ago (migración 115).** `ventas_indexar` desenvolvía el `payload` a mano y dejaba ventas invisibles para la caja (medido: 1 → 0). Quedan otros sitios con el mismo patrón, ninguno con daño medido. en vez de usar `detalle_venta()`. Ya hay **2 ventas
    invisibles** para `buscar_tickets`, `tickets_recientes` y `ticket_detalle` (su carro sí se creó).
23. ✅ **HECHO 19/ago (migración 108).** El webhook descartaba en silencio por tres caminos (cuerpo ilegible, JSON inválido, sin
    `purchase_uuid`): responde 200 y el único rastro son logs de ~1 día que nadie mira.
24. ✅ **HECHO 19/ago (migración 111).** `crear_carro_desde_venta` no tenía `exception when others`: un error en el trigger **tumba
    la venta completa**. Es la lección de §7 un nivel más abajo.
25. 🟠 **PARCIAL — migración `111`.**
    ✅ Índice en `asignaciones(empleado_id, carro_id)` (9.2 ms → 1.6 ms, Index Only Scan);
    ✅ `enlazar_visita_a_carro` normaliza la placa y respeta el candado de la `100`;
    ✅ `desenlazar_visita` ya no borra la foto del supervisor ni el cliente de la nota;
    ✅ `cerrar_pendientes` alcanza al carro creado después del corte (medido: 0 casos hasta hoy);
    ✅ `Gratis`+`6to Express` (resuelto el 19/ago con la decisión del dueño).
    ✅ Índices trigram para las búsquedas (898 ms → 59 ms, migración `115`);
    ✅ `encimados` ya no escanea toda la historia (ventana de 24 h, migración `116`);
    ✅ `sincronizar-jibble` ya tiene candado (migración `115`);
    ✅ el **unique parcial en `visitas(carro_id)`** (migración `114`).
    **Queda sólo:** `iniciales_de` repite (Jaime Gallegos y Jesús Gil = JG) — medido hoy: **0
    iniciales repetidas** entre los secadores activos, así que no muerde.

### ✅ RESUELTO — los 14 lavados con dos clientes (migraciones `112`–`114`)

Salió al ir por ese unique y ya está cerrado. Ver `CLAUDE.md §11.35`. En corto: se quitó el
**reclamo sobre el lavado**, no la visita, así que nadie perdió un sello; cinco se resolvieron con
evidencia (placa o ticket real), nueve quedaron sin dueño porque no había ninguna pista, y las dos
visitas de prueba del dueño se deshicieron. De paso salieron **6 sellos dobles** (misma persona,
mismo ticket) y **440 visitas con tickets que no eran tickets** (0 al 5). El candado ya está
puesto: `visitas_un_lavado_un_cliente`.

### 📱 Estabilidad del supervisor

26. **Ninguna petición tiene timeout.** Una colgada deja **todos los botones muertos y mudos**; la
    única salida es cerrar y reabrir, y nada lo sugiere. La misma falta mata la cola de fotos toda la
    sesión (el mutex nunca se suelta).
27. **Sin red, la cola congelada se ve viva**: los relojes siguen corriendo y las tarjetas se ponen
    rojas con datos viejos. El aviso solo sale si la cola está vacía.
28. ✔ **El `wakeLock` nunca se vuelve a pedir**: `candado` no se re-inicializa a `null`, así que tras
    el primer minimizado la pantalla se apaga sola el resto del turno.
29. ✔ **`escapar()` divergió**: `index.html:970` es el único de los tres sin la guarda de nulos.
30. ✅ **HECHO 19/ago.** Del rechazo ya hay regreso (botón "No, sí quedó bien"). La fuga de temporizador NO existe (se limpia al abrir y al cerrar, verificado). Queda: re-tomar una foto mientras se sube la anterior. (solo "Cancelar", que cierra todo) — posible causa de que la
    pantalla lleve 25 días sin uso. Fuga de temporizador en el desglose en vivo. Re-tomar una foto
    mientras se sube la anterior puede perder la nueva.

### 💰 Costos (medidos)

31. ✔ **El `CLAUDE.md` documenta mal el gasto de Anthropic por 5.4×.** Medido con `count_tokens`
    sobre una foto real: **3,101 tokens de entrada**, no 1,698. Real: **$17.80 USD/mes**, y
    **$26.70 desde el 1/sep** al terminar el precio de introducción. A 200 carros/día, $61. También
    está mal el peso de la foto: **100 KB**, no 150.
32. 🟠 **PARCIAL 19/ago.** `sincronizar-jibble` pasó a cada 5 min (y con candado). `calentar-webhook` se queda en cada minuto A PROPÓSITO: ahorra $0 y arriesga un 502 en el camino del dinero — ver `CLAUDE.md §11.30`. Los dos crones por minuto eran el mayor desperdicio: 44% del CPU de la base, 24% de las
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

### 🎯 Orden sugerido — los 7 primeros YA ESTÁN HECHOS (19/ago)

1. ✅ `ok:false` automático cuando `status >= 400` (#4) — **una línea, mata la clase entera**.
2. ✅ Encimados + re-congelar desde el 26/jul (#1) — desbloquea la analítica por persona.
3. ✅ Que la cola no mienta (#3, #26, #27).
4. ✅ Terminar el despliegue de la 104 (#6) — hoy la cola está en cero.
5. ✅ Cerrar permisos de `anon` (#10).
6. ✅ Decidir la regla del canje sin saldo (#2) y la del `6to Express` (#25).
7. ✅ Tope al borrado de fotos y probarlo antes de octubre (#7).

### 🧪 Y lo único que evita que esto se repita

✅ **ARRANCADA el 19/ago: `pruebas/correr.sh`.** Ya trae los primeros casos (14 de `marcarError`,
6 grupos del canje sin saldo, y la sintaxis de las tres pantallas), corre en un comando y sale con
código 1 si algo falla. Falta ir sumándole un caso por cada hallazgo de esta lista.

**Una suite de regresión que se corra antes de cada despliegue.** El proyecto ya tenía la técnica
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

# Pendientes por hacer — se trabajan DESPUÉS del cierre (8 PM)

> Este archivo es la bandeja de entrada. Nada de aquí se toca mientras el autolavado esté
> abierto: cualquier despliegue a medio turno le puede tumbar la app al supervisor.
> Cuando algo se hace, se mueve al `CLAUDE.md` con su razón y se borra de aquí.

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

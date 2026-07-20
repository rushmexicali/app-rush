# Pendientes por hacer — se trabajan DESPUÉS del cierre (8 PM)

> Este archivo es la bandeja de entrada. Nada de aquí se toca mientras el autolavado esté
> abierto: cualquier despliegue a medio turno le puede tumbar la app al supervisor.
> Cuando algo se hace, se mueve al `CLAUDE.md` con su razón y se borra de aquí.

---

## Pedidos del dueño — 20/jul/2026

### 1. Borrar el rechazo de prueba de Chuy 🔴 BORRADO DE DATOS

Lo hizo el dueño a propósito para enseñarles a los supervisores cómo funciona.

**Fila exacta, única en la tabla:**

```
rechazos.id = 9
grupo    c5d55924-9e56-4481-924f-e0fd83f22b40
carro    116
secador  Jesús Gil  (empleado 9ae3155a-15c0-468a-bd41-9320a9469084)
motivo   Vidrios
cuándo   2026-07-20 11:02
```

Se borra **sólo esa fila**. El carro 116 no se toca: se lavó de verdad y sus tiempos son
reales. Confirmar el `delete` con el dueño en el momento, mostrando esta fila.

> Con ésta, la tabla `rechazos` queda **vacía**. El primer rechazo real del negocio será el
> siguiente que entre — bueno para la línea base, porque ninguno de los que hay hoy es real.

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

### 8. Cola virtual: el secado no debe contar el tiempo que el carro estuvo formado

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

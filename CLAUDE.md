# RUSH Car Wash — App de Operación (contexto del proyecto)

> Este archivo es la **memoria del proyecto**. Claude Code lo lee solo al inicio de cada
> sesión. Ajústalo con el tiempo: cuando cambie una decisión, edítala aquí — es la fuente de
> la verdad. Marca lo que aún no está decidido en la sección "Decisiones pendientes".

---

## 1. Qué es esto

App para el **supervisor de turno** de RUSH Car Wash (Mexicali). Corre en un teléfono
dedicado que se le entrega al supervisor. Sirve para cronometrar cada carro a lo largo del
proceso de lavado y secado, asignar líneas y secadores, y medir la eficiencia de cada
secador con el tiempo.

## 2. Cómo trabajar en este proyecto (reglas para Claude Code)

Estas reglas aplican en **todas** las sesiones:

- **Avanza sin pedir permiso en lo rutinario.** Editar archivos, correr comandos de lectura,
  desplegar Edge Functions, hacer commits, consultar APIs: hazlo y luego cuenta qué hiciste.
  Explicar sigue siendo obligatorio; pedir permiso ya no.
  *(Actualizado el 19/jul/2026: al inicio la regla era pedir permiso para todo, cuando el
  dueño no sabía qué esperar de Claude Code. Ya trabajando, esa regla costaba más de lo que
  protegía.)*
- **Sí para antes de estas cuatro cosas**, siempre, aunque el resto vaya en automático:
  1. **Borrar datos** (filas, archivos, tablas) — di exactamente qué se va a borrar.
  2. **Cambiar configuración de un servicio externo** — suscripciones de Zettle, webhooks,
     llaves, cualquier cosa que altere la cuenta real.
  3. **Publicar algo nuevo hacia afuera.** El `git push` de rutina al repo `app-rush` ya no
     se pregunta — el dueño creó el token justamente para eso el 19/jul/2026. Sí se pregunta
     antes de publicar en un lugar nuevo, hacer público algo que era privado, o subir
     archivos que no sean código del proyecto.
  4. **Cambios de arquitectura** — cambiar de tecnología, rehacer el modelo de datos,
     reescribir algo que ya funcionaba.
- **Usa Git desde el inicio.** Inicializa el repo, haz commits chicos y descriptivos después
  de cada paso que funcione, para poder deshacer sin perder trabajo.
- **Secretos SIEMPRE en `.env`, nunca en Git.** La API key de Zettle y la `service_role` de
  Supabase mueven pagos: van en un archivo `.env` que debe estar en `.gitignore`. Nunca las
  pongas en código, ni en archivos que se suban al repo, ni en este `CLAUDE.md`. Mantén un
  `.env.example` con los nombres de las variables (sin valores).
- **Una fase a la vez, pero los pasos dentro de una fase van seguidos.** No mezcles
  integraciones distintas (Zettle y Jibble juntas, no). Pero dentro de una fase ya aprobada,
  encadena los pasos y verifica sobre la marcha en vez de detenerte en cada uno. Párate solo
  si algo falla, si aparece una decisión de verdad, o si toca una de las cuatro cosas de
  arriba.
- **Usa Plan Mode al empezar una fase**, no para cada tarea suelta dentro de ella.
- **Verifica desde afuera, no confíes en la pantalla.** Después de cada cosa que construyas,
  compruébala con una llamada real (`curl.exe`, consulta a la base) en vez de suponer que
  quedó bien. Varios errores de la Fase 1 se detectaron así, no viendo el panel.

## 3. Problema que resuelve

Hoy no hay forma de saber cuánto tarda cada carro en cada etapa, ni qué secador es más
rápido, ni dónde se hacen los cuellos de botella. Esta app captura esos tiempos de forma
automática (la entrada) y semi-automática (las transiciones de etapa, con un botón tipo
cronómetro), para después analizar la eficiencia.

## 4. Usuarios y regla de oro del diseño

El usuario es el supervisor de turno. **No son personas jóvenes y pueden batallar con la
tecnología.** Toda decisión de diseño se juzga contra esto:

- Botones **gigantes**, un botón por acción. Nada de menús, pestañas ni gestos (swipe,
  mantener presionado). Solo toques directos.
- El botón dice **qué acción hace**, no algo genérico. Ej.: mientras el carro está en
  prelavado, el botón dice "Terminó prelavado"; al tocarlo cambia a "Salió del túnel".
- **Colores por estado**, no texto que haya que leer: prelavado = azul, túnel = amarillo,
  secando = verde, demora = rojo.
- **Cuándo se pinta de rojo** (calibrado por el dueño el 19/jul/2026 viendo el taller, ya no
  hay números inventados):

  | Etapa | Rojo |
  |---|---|
  | Prelavado | a los 15 min |
  | Túnel | **nunca** — es automático y siempre tarda lo mismo |
  | Falta asignar | **siempre**, desde el primer segundo |
  | Secando | a los 35 min |

  El túnel no cambia de color porque un rojo que aparece sin que haya problema enseña al
  supervisor a ignorar el rojo. "Falta asignar" es rojo siempre porque no es una demora que
  se acumula: es una acción que debe ocurrir en cuanto el carro sale del túnel.

  > Efecto secundario: el morado que tenía "falta asignar" ya no aparece nunca, porque el
  > rojo lo tapa. Queda libre por si se necesita para otro estado.
- **Sonido + vibración** cuando entra un carro nuevo (el supervisor no siempre ve la
  pantalla).
- Botón **"Corregir"** siempre visible por carro, por si tocan la etapa equivocada. Nunca
  hay que buscar cómo deshacer.
- Fuente grande, alto contraste.
- Siempre un **respaldo manual** por si una integración externa (Zettle/Jibble) falla — la
  app nunca se debe quedar bloqueada.
- La foto abre **directo la cámara**, no la galería.
- Toda la UI en **español**.

## 5. Flujo operativo real

```
Pago (Zettle, automático) → Prelavado → Túnel → Asignar línea + secador → Secando → Entregado
```

- **Pago**: no hay botón. Llega solo por el webhook de Zettle y crea el carro en la cola,
  con la hora de inicio.
- **Express → línea 1**: si la venta trae el producto `Express`, el carro se marca con una
  **banderita / identificador gráfico bien visible** en la cola. Los express van directo a
  la **línea 1**, que se dedica exclusivamente a ellos. El supervisor no tiene que leer el
  producto ni acordarse: lo ve de un vistazo.
- **Prelavado / Túnel**: el supervisor toca el botón de etapa (modelo "lap" de cronómetro)
  para marcar cuándo el carro pasa a la siguiente etapa. Se guarda el tiempo de cada una.
- **Asignar**: al salir del túnel se abre pantalla completa: elige línea (1, 2, 3…) y
  secador(es) con botones grandes y foto/inicial de cada persona.
- **Secando**: corre el cronómetro de secado (el dato clave para medir eficiencia).
- **Entregado**: se cierra el carro.

## 6. Arquitectura técnica (plan de trabajo, ajustable)

- **Backend: Supabase** (plan gratis para empezar). Da en un solo lugar:
  - Postgres (base de datos)
  - Edge Functions (endpoint público HTTPS para recibir los webhooks de Zettle/Jibble)
  - Realtime (para que la app muestre carros nuevos sin refrescar)
  - Storage (para las fotos de los carros)
- **App: Flutter.** Elegida por el control total sobre tamaño de botones, colores y
  animaciones — clave para hacerla "a prueba de abuelitos". Un solo código para Android
  (y iOS si algún día se quiere).
- **Asistente de código: Claude Code**, guiado por este documento.

## 7. Integración con Zettle (pagos → entrada del carro)

- Es una **integración privada** (para nuestra propia cuenta), así que se usa el
  **assertion grant** con una **API key**.
- Crear la API key en `https://my.zettle.com/apps/api-keys` con scope **`READ:PURCHASE`**.
  La llave es un JWT; de ahí también se saca el `client_id`.
- Obtener access token (dura **2 horas**, **no hay refresh token** — se vuelve a pedir con
  la misma llave cuando expira):
  `POST https://oauth.zettle.com/token`
  con `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`, `client_id`, `assertion`.
- Suscribir el webhook (**una sola vez**):
  `POST https://pusher.izettle.com/organizations/self/subscriptions`
  con `eventNames: ["PurchaseCreated"]`, `transportName: "WEBHOOK"`, y `destination` = la
  URL pública de la Edge Function. La respuesta trae un `signingKey` (guardarlo para
  verificar firmas más adelante).
- El evento a escuchar es **`PurchaseCreated`** (se dispara al finalizar una venta).
- El endpoint debe responder **200 rápido**; si truena, Zettle marca el destino como
  fallido. Y en Supabase la función se despliega con **`--no-verify-jwt`** (si no, rechaza
  el POST de Zettle por no traer token de Supabase).

### Trampas ya descubiertas (aprendidas a golpes, no repetirlas)

- **La fecha viene como número de milisegundos**, no como texto ISO. Postgres la rechaza con
  el error `22008` y **tumba la fila completa**. Una venta real se perdió por esto antes de
  detectarlo. Regla general: si un dato secundario no se entiende, se guarda en blanco — la
  venta nunca se pierde por un campo que no era esencial.
- **Al suscribir el webhook, Zettle manda un evento `TestMessage`** que no trae venta. Es
  normal, no es error.
- **El `uuid` de la suscripción debe ser versión 1** (los que llevan la hora adentro), no
  versión 4. Si no, Zettle la rechaza.
- **`GET /purchases/v2` sin filtro de fechas devuelve las ventas MÁS VIEJAS primero.** Para
  ver lo reciente hay que mandar `startDate` / `endDate`. Fácil sacar conclusiones falsas.
- El webhook manda `purchaseUUID` con guiones; la API REST llama a ese mismo valor
  `purchaseUUID1`. Usar siempre ese para no duplicar filas.
- Existe `scripts/4-recuperar-venta.ps1` para rescatar una venta que no llegó por webhook.

### Qué trae el pago (útil para fases futuras)

Cada venta incluye producto, variante, categoría, sucursal, cajero, forma de pago y
coordenadas. Todo se guarda completo en la columna `payload`, así que el histórico se está
acumulando desde el día uno aunque todavía no se use.

- **Los productos son paquetes de servicio, no líneas de secado.** Catálogo real: `Express`,
  `Completo`, `Completo Cera`, `Manual`, `Gratis`, más extras (`Lodo Extra`, `Pinito`).
  Por lo tanto **la línea NO viene en el pago** y el supervisor sí tiene que asignarla.
- **Cada paquete trae variante de tamaño**: `Completo` vs `Completo Grande`, `Express` vs
  `Express Grande`. Esto ya distingue carro normal de camioneta grande **sin necesidad de
  capturar marca y modelo**, y sirve para normalizar la analítica de la Fase 5 desde el
  principio.

## 8. Integración con Jibble (empleados activos)

- La Edge Function también se suscribe a los webhooks de Jibble: **clock-in, clock-out,
  break** → actualiza una tabla "empleados activos ahora".
- Al abrir la app cada mañana, además hacer una llamada de **sincronización** al endpoint
  de "gente marcada" de Jibble, por si se perdió algún webhook.
- En la pantalla de asignar secador, la grilla solo muestra a quien está marcado ahora, con
  **foto** (reconocimiento visual, no lectura).
- Si alguien está "en descanso", **no se quita** de la lista: se muestra atenuado/gris.
- Si alguien se ponchó (clock-out) mientras secaba un carro, ese carro se marca visualmente
  para reasignarlo, sin perder quién lo estaba secando.
- Siempre debe existir un botón **"No aparece el empleado / agregar manual"** como
  respaldo.

## 9. Datos del carro (tipo, color, foto)

### La nota de caja los prellena (implementado 19/jul/2026)

La cajera puede escribir una nota en la venta de Zettle. Llega en el webhook dentro de
`products[0].comment` y la app la interpreta sola. Formato acordado:

```
<CODIGO> <COLOR> - <NOMBRE DEL CLIENTE>

PU = pickup       CA = camioneta
AU = automovil    PA = pasajeros (tipo combi, 5 hileras)
```

- `CA NEGRA` → camioneta negra
- `PU NEGRA - LUIS GONZALEZ` → pickup negra, 6to lavado gratis de Luis González

Reglas de interpretación:
- Si el código no se reconoce, **no se adivina nada** — se deja vacío. Un dato inventado es
  peor que uno faltante, porque el supervisor confía en lo que ve.
- **El guion es el separador** entre color y nombre del cliente (instrucción dada a las
  cajeras el 19/jul/2026). Se parte en el primer guion, con espacios o sin ellos, porque una
  cajera con prisa va a escribir `BLANCA-JUAN` de corrido.
  - Costo aceptado: un color con guion (`AZUL-MARINO`) se parte mal. Se prefiere así porque
    perder el nombre duele más — es el registro del 6to lavado gratis — y el color sí lo
    puede corregir el supervisor de un vistazo, mientras que el nombre no lo adivina nadie.
- **Si falta el guion, se usa una lista de colores conocidos** para saber dónde acaba el
  color. Hay dos listas separadas por una razón concreta: *hay nombres de persona que son
  colores*. `PU NEGRA ROSA MARTINEZ` no es un carro negro-rosa, es el carro negro de Rosa
  Martínez.
  - **Colores base** — un carro tiene uno. Al encontrar otro, el color termina ahí.
  - **Modificadores** (`MARINO`, `REY`, `OLIVO`, `OSCURO`…) — solo valen *después* de un
    color base, nunca lo inician. Por eso `AZUL MARINO` se lee completo pero `NEGRA ROSA`
    corta en `NEGRA`.
  - `VINO` y `TINTO` están en ambas listas, para que `VINO TINTO` funcione. `ROSA` está solo
    como color base a propósito: ahí proteger el nombre vale más que el color compuesto.
  - Se ignoran acentos y mayúsculas: `ca café luis` funciona igual.
- Si el color tampoco está en la lista, último respaldo: en ventas **gratis** lo que sigue al
  color es el nombre; en las demás todo es color.
- La columna `carros.datos_de_nota` dice si el dato vino de la nota o lo capturó el
  supervisor. Sirve para medir qué tan seguido se está llenando la nota en caja.

> ⚠️ **Esto depende de un hábito, no del código.** Al 19/jul/2026, de 25 ventas del día solo
> 2 traían nota, y las puso el dueño a propósito. El código está listo; falta que las cajeras
> lo hagan en cada venta. Mientras no pase, el supervisor captura a mano — que es justo el
> respaldo que el diseño ya contempla.

### Captura manual (respaldo)

- Es **opcional** y **no bloquea** el flujo. Aparece como botón (ícono de cámara) en la
  tarjeta de cada carro; el supervisor lo captura cuando tiene un momento libre. Si el carro
  sale sin datos, no pasa nada.
- Captura **sin teclado** hasta donde se pueda:
  - Marca: grilla de botones con las marcas comunes de la zona + "Otra".
  - Modelo: al elegir marca, se muestran solo sus modelos típicos como botones + "Otro".
  - Año: selector con botones +/- (no teclado numérico).
  - Foto: botón que abre la cámara directo, comprime la imagen en el teléfono antes de subir
    (el wifi del taller puede ser flojo), y la guarda en Supabase Storage.
- Beneficio a futuro: con marca/modelo se puede normalizar la eficiencia (una camioneta
  grande tarda más que un sedán, no comparar peras con manzanas).

## 10. Modelo de datos (borrador inicial)

- `carros`: id, purchase_uuid (de Zettle), creado_en, marca, modelo, anio, foto_url,
  estado_actual, linea, secador_id.
- `etapas`: id, carro_id, etapa (prelavado/tunel/secando/…), inicio, fin, segundos.
- `empleados_activos`: id, nombre, foto_url, estado (activo/descanso), actualizado_en.
- `asignaciones`: id, carro_id, linea, secador_id, inicio, fin.
- (La tabla mínima del **primer demo** es solo `ventas`/`carros` con lo que llega de Zettle.)

## 11. Fases de construcción

1. **Primer demo — receptor de Zettle.** Edge Function pública + tabla; una venta real
   aparece sola en la base de datos.
2. **UI de cronómetro + asignación manual.** Cola de carros, botones de etapa, pantalla de
   asignar línea/secador con lista fija de empleados. Probar con el supervisor real.
3. **Jibble.** Automatizar la lista de empleados activos.
4. **Datos del carro + foto.**
5. **Analítica de eficiencia.** Tiempos promedio por línea, por secador, contra un objetivo;
   normalizado por tipo de carro.

> Regla de oro de construcción: **una integración a la vez.** Dejar funcionando y probado
> cada bloque antes de meter el siguiente, para saber exactamente qué pieza falla.

## 12. Estado actual

- Ya existe un **mockup interactivo** de las pantallas (cola de carros, cronómetro/etapas,
  asignar línea+secador con Jibble, datos del carro). Sirve para probar la usabilidad con el
  supervisor antes de programar en serio.
- El primer demo (Fase 1) está definido y listo para construirse.

## 13. Decisiones pendientes (llenar con el tiempo)

- ¿Cuántas líneas de secado hay realmente? (el mockup asume 3)
- ¿Cuántos secadores/personas por línea? ¿Un carro puede tener más de un secador asignado?
- ~~¿Los tiempos "normales" de cada etapa?~~ **RESUELTO (19/jul/2026):** prelavado 15 min,
  túnel nunca, falta asignar siempre, secando 35 min. Detalle en la sección 4.
- ¿Se marca la transición solo con botón manual, o a futuro con sensores (fotocelda/RFID)?
- ~~¿Cómo se configuran en Zettle los productos?~~ **RESUELTO (19/jul/2026):** son paquetes
  de servicio con variante de tamaño, no líneas. La línea se asigna a mano. Detalle en la
  sección 7.
- La **línea 1 es exclusiva de express** (confirmado 19/jul/2026). Falta definir qué pasa si
  no hay express en cola: ¿la línea 1 se queda vacía esperando, o toma carros normales?
- ¿Qué reportes de eficiencia quieres ver exactamente al final?

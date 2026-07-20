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
  | Antes de secar (prelavado + túnel + espera) | a los **19 min** |
  | Secando | a los 35 min |

  Los 19 minutos son los 15 de prelavado más los 4 del túnel. **Cambió el 19/jul/2026**
  junto con el flujo de un solo toque: ahora un solo estado cubre todo lo que pasa antes de
  secar, así que el umbral tuvo que absorber también el túnel.

  > "Túnel" y "falta asignar" ya no existen como estados que el supervisor vea. Sus umbrales
  > siguen en el código solo por los carros que venían en camino cuando cambió el flujo, y se
  > pueden borrar cuando la cola esté limpia de ellos.
- **Sonido + vibración** cuando entra un carro nuevo (el supervisor no siempre ve la
  pantalla).
- Botón **"Corregir"** siempre visible por carro, por si tocan la etapa equivocada. Nunca
  hay que buscar cómo deshacer.
- Fuente grande, alto contraste.
- Siempre un **respaldo manual** por si una integración externa (Zettle/Jibble) falla — la
  app nunca se debe quedar bloqueada.
- La foto abre **directo la cámara**, sin preguntar nada. Al lado hay un segundo botón más
  chico y más apagado para escoger de la **galería**, por si la foto se tomó fuera de la app.
  *(Agregado el 19/jul/2026 a pedido del dueño.)* Son dos botones y no un menú a propósito:
  el caso común sigue siendo un solo toque, y el pulgar cae en la cámara por default.
- Toda la UI en **español**.

## 5. Flujo operativo real

```
Pago (Zettle, automático) → [Asignar unidad] → Secando → [Entregado]
                                  ↑                          ↑
                            un solo toque              el otro toque
```

**Son DOS toques por carro, no cuatro.** Cambió el 19/jul/2026, a pedido del dueño: *"el
supervisor no tiene tiempo de ver cuándo termina el prelavado y cuándo sale del túnel; él
solamente tiene que estar asignando líneas y secadores"*.

- **Pago**: no hay botón. Llega solo por el webhook de Zettle y crea el carro en la cola,
  con la hora de inicio.
- **Express → línea 1**: si es un lavado express, el carro se marca con una **banderita bien
  visible** en la cola y va directo a la **línea 1**, que se dedica exclusivamente a ellos.
  Ver la sección 12.1 para qué cuenta como express (ojo con `Manual`).
- **Asignar unidad**: el único toque antes de secar. Abre pantalla completa: tipo, color,
  marca, línea y secador(es), con botones grandes.
- **Secando**: corre el cronómetro de secado (el dato clave para medir eficiencia).
- **Entregado**: se cierra el carro.

### Cómo se sigue sabiendo cuánto duró el prelavado

Nadie marca el prelavado ni el túnel, pero los tiempos **no se pierden**: se reconstruyen al
asignar, porque el túnel dura lo mismo siempre (es una máquina).

```
corte = max(inicio_prelavado, ahora - 4 min)

prelavado:  inicio → corte    (cerrada)
tunel:      corte  → ahora    (cerrada, fabricada)
secando:    ahora  → abierta
```

Los **4 minutos están medidos**, no supuestos: 29 mediciones reales del flujo viejo dan un
promedio de 242 s = 4.03 min. Viven en `segundos_de_tunel()` por si algún día cambia la
máquina.

> **Lo que se pierde, dicho de frente:** "por asignar" duraba 59 s en promedio, y ese minuto
> ahora se le suma al prelavado calculado. O sea el prelavado sale **~1 min más largo que el
> real**. Es el precio de quitarle dos toques por carro al supervisor.

### Los tres botones de la tarjeta

| Botón | Qué hace |
|---|---|
| **Asignar unidad** / **Entregado** (grande) | El toque principal. **Nunca manda solo: siempre abre una pantalla** |
| **Corregir** | Abre la misma pantalla en modo captura: tipo, color, marca. Sirve en cualquier momento, incluso antes de asignar |
| **Regresar** | Deshace el paso anterior. Apagado en prelavado, no hay a dónde |

### Confirmar o rechazar la entrega (19/jul/2026)

Tocar **Entregado** ya no entrega: abre una pantalla con **Entregar** (verde) y
**Rechazar** (rojo). Salió del uso real — el secador avisa que ya quedó, pero el
supervisor revisa antes de soltar el carro.

Al rechazar se elige **qué faltó** de 8 botones (Tablero, Vidrios, Rines, Interior,
Marcos de puertas, Cajuela, Carrocería mojada, Otro) y queda registrado **a nombre de
cada persona que lo estaba secando**. El objetivo no es castigar: es saber a quién
entrenar y en qué.

- **El carro NO cambia de estado.** Sigue secando, misma línea, mismos secadores, y
  **el cronómetro no se reinicia**. Rehacer algo mal hecho sí cuesta tiempo del taller;
  si el reloj se reiniciara, el promedio de ese equipo escondería el retrabajo.
- **Una fila por secador**, más una columna `grupo` que une las filas de un mismo
  rechazo. Así las dos cuentas salen bien: por persona `count(*)`, por evento
  `count(distinct grupo)`. Sin `grupo`, un rechazo de dos personas se contaría como dos.
- La pantalla **dice quién secó** antes de que el supervisor toque: está a punto de
  registrarle un rechazo a alguien con nombre.
- **Costo aceptado:** esto agrega un toque a cada entrega, incluidas las buenas. Se
  bajó de 4 toques a 2 y esto sube a 3. No hay forma de tener el rechazo sin un punto
  donde decidir.

### Ver los entregados de hoy

Botón **"Ver entregados de hoy"** al final de la cola (no arriba: los carros que
necesitan atención van primero). Abre la lista del día, del más reciente al más viejo,
con un botón **Restaurar** por tarjeta.

**Es un botón y no una pestaña a propósito**, aunque se pidió como pestaña: la regla de
la sección 4 dice "nada de menús ni pestañas". Se usa el mismo patrón de pantalla
completa que ya tiene "Asignar", que el supervisor ya conoce.

Restaurar reusa `regresar_etapa` (`entregado → secando`), que ya existía y ya estaba
probado. No se escribió lógica nueva para deshacer.

**Cada tarjeta tiene además "Corregir"** (agregado 20/jul/2026, a pedido del dueño): abre la
**misma pantalla** que el Corregir de la cola, para arreglar una captura mala *después* de
entregar. Sale más apagado que Restaurar a propósito — los dos son acciones raras, pero
restaurar es la que el supervisor viene buscando cuando entra aquí.

- **No mueve nada del reloj.** `editar_carro` sólo toca tipo/color/marca y no conoce el
  estado; y la línea ni se manda, porque el carro ya no está secando. Medido sobre un carro
  ya entregado: `creado_en`, `entregado_en` y las tres etapas quedaron idénticos al
  microsegundo.
- **No se escribió backend nuevo.** `editar_carro` ya servía para cualquier estado; sólo
  faltaba el botón.
- ⚠️ **Trampa de capas:** `#entregados` tiene `z-index:45` y `#asignar` `40`, así que la
  pantalla de corregir se abriría **por debajo** de la lista. Hay que esconder `#entregados`
  al abrirla y volver a mostrarla al cerrar (recargada, para que el dato salga ya corregido).
  Se regresa a los entregados y no a la cola: el supervisor estaba revisando esa lista.
- `/entregados` ahora manda `estado` explícito. Antes funcionaba **por accidente**
  (`undefined` nunca es `"secando"`), y el primero que agregara lógica sobre el estado lo
  habría roto sin verlo.

⚠️ **"Corregir" cambió de significado el 19/jul/2026.** Antes era el deshacer; ahora eso es
"Regresar". En el API la ruta de deshacer se sigue llamando `/corregir` para no romper nada.

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
- **Sí se le puede asignar un carro a alguien en descanso**, con una confirmación que avisa
  que lo está y desde hace cuánto. *(Regla del dueño, 19/jul/2026.)* La razón es económica:
  el descanso es de una hora, pero **muchos regresan antes porque ganan bien de propina y les
  conviene trabajar más**. Bloquearlos sería trabajar en contra de ellos y del negocio. La
  confirmación existe para que nunca sea por accidente, no para desalentarlo.
- **Si un secador se poncha con un carro asignado**, la tarjeta del carro muestra un aviso
  rojo con el nombre de quien se fue. No se reasigna solo ni se borra el registro: quién secó
  ese carro es dato de eficiencia, y además puede que otro ya lo haya tomado. El supervisor
  decide.
- Si alguien se ponchó (clock-out) mientras secaba un carro, ese carro se marca visualmente
  para reasignarlo, sin perder quién lo estaba secando.
- Siempre debe existir un botón **"No aparece el empleado / agregar manual"** como
  respaldo.

### No solo los secadores secan (corregido 20/jul/2026)

La sincronización traía **únicamente** el grupo `Secador` de Jibble, y el código decía
*"no tiene caso traer supervisores, tuneleros ni cajeras"*. **Falso.** El dueño lo corrigió:
cuando hay mucho trabajo, el tunelero y los supervisores se ponen a secar.

Ahora se traen tres grupos, con su rol: `Secador` (13), `Tunelero` (1), `Supervisor` (2).
La **cajera se queda fuera** a propósito — no seca, y sólo alargaría la lista que el
supervisor recorre con el pulgar.

- El rol **no limita nada**: cualquiera de ellos puede secar. Sólo sirve para **agrupar en
  pantalla**. Los secadores salen arriba (el caso común) y el resto en una sección aparte,
  **"También pueden secar"**, que se esconde sola si no hay nadie.
- Si alguien está en dos grupos, gana el primero de la lista (secador), porque ahí es donde
  el supervisor lo busca.

### "Manual" significaba dos cosas opuestas

El botón "No aparece" crea un empleado con `manual = true`, y la sincronización los exceptúa
(`where not manual`) para que Jibble no los tumbe. Efecto secundario que nadie vio:
**se quedaban `activo` para siempre** y no había forma de quitarlos desde la app. El
20/jul/2026 ya había uno (`eri`) que iba a salir en la grilla todos los días del resto del año.

Pero ese mismo mecanismo es el que necesita **Guillermo Lara**, el gerente: no está en Jibble
(se buscó en las 38 personas y no aparece), no tiene horario, y siempre debe poder asignarse.

Por eso se partieron en dos:

| | Qué es | Qué le pasa |
|---|---|---|
| `manual` + `permanente = false` | Parche de un turno | **Caduca** al terminar el día en que se agregó |
| `manual` + `permanente = true` | De planta, fuera de Jibble | **Nunca** caduca. Hoy: Guillermo Lara |

**Por qué caducan solos y no hay botón de "quitar":** el supervisor agrega a alguien a mano
justo en el momento en que trae más prisa. Pedirle que se acuerde de limpiarlo después es
pedirle algo que no va a pasar. Caducar no necesita que nadie se acuerde. Si algún día se
quiere el botón, la columna `permanente` ya distingue a quién sí se puede quitar.

⚠️ **Caducar NO borra a nadie.** Sólo lo saca de la lista de disponibles. Quién secó qué
carro es dato de eficiencia y no se toca nunca.

Se comprobó con el bloque `do $$ ... raise` (base real, todo revertido): un manual de ayer
pasó a `fuera`, uno de hoy siguió `activo`, y Guillermo siguió `activo`.

## 9. Datos del carro (tipo, color, foto)

### La nota de caja los prellena (implementado 19/jul/2026)

La cajera puede escribir una nota en la venta de Zettle y la app la interpreta sola.
Formato acordado:

```
<CODIGO> <COLOR> - <NOMBRE DEL CLIENTE>

PU = pickup       CA = camioneta
AU = automovil    PA = pasajeros (tipo combi, 5 hileras)
```

- `CA NEGRA` → camioneta negra
- `PU NEGRA - LUIS GONZALEZ` → pickup negra, 6to lavado gratis de Luis González

**La nota viene en uno de DOS lugares** (aprendido a golpes el 19/jul/2026):
1. `products[0].comment` — el lugar acordado, donde llega la mayoría.
2. `discounts[].name` — el nombre del descuento. Pasa en los **6to lavado gratis**, porque
   ese se cobra aplicando un descuento del 100% y hay cajeras que escriben ahí el nombre
   del cliente en vez de en el comentario.

No es "los gratis van por descuento": de los dos lavados gratis que había, uno traía la nota
en el comentario y el otro en el descuento. Depende de cada cajera, así que se leen los dos.
Un descuento solo se toma como nota si empieza con código conocido (PU/CA/AU/PA) — así
"Descuento empleado" o "Promo martes" se ignoran solos y nunca acaban en la ficha del carro.

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

### La placa se lee sola de la foto (implementado 19/jul/2026)

Cuando el supervisor sube la foto, la Edge Function `app` se la manda a **Claude Sonnet 5**
y guarda la placa en `carros.placa`. La placa aparece en la tarjeta con su propio recuadro,
antes de tipo/color/marca: es el único identificador que no se repite.

#### En Mexicali circulan TRES tipos de placa (corregido 19/jul/2026)

El prompt decía *"son placas mexicanas, en su mayoría de Baja California"*, y eso tiraba
lecturas buenas. Ahora nombra los tres tipos y dice que ninguno se rechaza por su formato:

1. **Oficial mexicana** (BC u otro estado).
2. **De Estados Unidos** — Mexicali es frontera. El nombre del estado, el lema
   (`Grand Canyon State`, `dmv.ca.gov`) y las calcomanías de mes/año **no** son parte de
   la placa.
3. **De asociación civil**, para autos de procedencia extranjera no nacionalizados:
   ONAPPAFA, ANAPROMEX, AMLOPAFA, CONDEFA, CODEFA, APROFAM, APROFA, UCD. Llevan el nombre
   de la organización y un número de afiliación. **No tienen formato oficial y eso está
   bien.**

> ⚠️ **A propósito NO se le enseñaron los formatos de cada organización.** Se buscó y no
> hay una nomenclatura publicada confiable — lo único concreto es una nota suelta de que
> ANAPROMEX usa 2 letras y 5 números. Darle formatos sería darle una **plantilla que
> rellenar**, que es exactamente lo que rompe la regla de "nunca inventa". Se le enseña que
> **existen**, no cómo son.

**Cómo se encontró, que es la parte que vale:** un Mustang rojo subió foto y no guardó
placa. Midiendo contra la API real resultó que el modelo **sí leía** el número (`72973`)
pero devolvía `legible=false`, y el código descarta todo lo que no venga marcado legible.
La lectura estaba bien; el filtro la tiraba. Leyendo el código no se veía.

El **marco del portaplacas** tampoco es parte de la placa: en esa foto decía
`FORD / Go Further` encima del número, y además **tapaba el nombre de la organización** —
no se pudo leer ni ampliando la imagen 14 veces. Por eso `placa_organizacion` (migración
`033`) se espera que quede NULL seguido, y **la placa nunca depende de ella**.

Va en columna aparte y no pegado dentro de `placa` porque `"ONAPPAFA 72973"` y `"72973"`
son el mismo carro; juntos, el historial lo contaría como dos vehículos y
`normalizar_placa()` no puede arreglarlo (no sabe que el nombre es prefijo).

**Cómo se verificó (el patrón a repetir):** se bajaron las 10 fotos reales del día y se
corrió el prompt viejo y el nuevo contra las mismas imágenes. Las 9 que ya se leían salieron
idénticas, guiones incluidos, y el Mustang pasó de vacío a `72973`. Como el prompt se
**aflojó**, se repitió la prueba anti-invención: tapando el `297` de en medio y dejando
visible `7…3`, devolvió vacío 3 de 3 veces teniendo el formato y la mitad de los dígitos
para adivinar.

> **Pendiente de verificar:** el camino de las placas de Estados Unidos está escrito pero
> **no probado contra una placa gringa real** — no hay ninguna todavía en la base. La
> primera que entre es la prueba.

- **No hubo que subir la resolución.** El `CLAUDE.md` decía que a 1280px la placa quedaría
  con ~130px y habría que subir a 2000px. Se midió con una foto real: la placa medía ~170px
  y se lee perfecto. Incluso a la **cuarta parte** de resolución (placa de ~42px) seguía
  leyéndola. La foto sigue pesando ~150 KB en vez de ~450 KB — importante con el wifi flojo
  del taller.
- **Sonnet 5 y no Opus:** tiene visión de alta resolución (lo que hacía falta) y cuesta un
  tercio. Va con `thinking` apagado y esfuerzo bajo porque esto es OCR, no razonamiento.
  Si algún día las lecturas salen flojas, ahí es donde hay que subirle.
- **Costo medido:** 1,698 tokens por foto → **~$3.20 USD/mes** con ~30 carros al día
  (~$4.90 cuando termine el precio de introducción de Sonnet 5 en agosto/2026).
- **Nunca inventa.** Se probó tapando los dígitos centrales de una placa real y dejando
  visibles solo las letras de los extremos: devolvió vacío las tres veces, teniendo toda la
  información para "completarla". Es la misma regla de oro de la nota de caja.
- **Nunca bloquea.** La placa se lee *después* de que la foto ya quedó guardada, con corte a
  los 25 segundos. Si Anthropic se cae o tarda, la foto se guarda igual y el carro sigue.
- **Dos columnas, y la diferencia importa:** `placa_en` nula = no se ha intentado;
  `placa_en` con fecha y `placa` vacía = **sí se intentó y no se pudo**. Ese segundo caso es
  dato, no error: sirve para medir qué tan seguido salen fotos ilegibles.

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
5. **Analítica de eficiencia.** Reporte diario con corte a las 10 PM, histórico perpetuo, e
   historial de visitas por placa. Ver sección 12.1.

> Regla de oro de construcción: **una integración a la vez.** Dejar funcionando y probado
> cada bloque antes de meter el siguiente, para saber exactamente qué pieza falla.

## 12. Estado actual — al 19/jul/2026 (fin del día)

**Las 5 fases están en producción y los supervisores ya trabajan con la app.** Ese día
entraron ~55 carros reales. Todo lo de abajo se construyó y se publicó en un solo día, así
que **hay mucho código nuevo con muy poco kilometraje**.

> ⚠️ **Lo más importante para quien siga:** este proyecto se construyó *encima* de una
> operación en marcha. Varios de los bugs más serios del día los introdujo el propio trabajo
> del día y se encontraron **midiendo, no leyendo el código**. Antes de agregar nada, vale más
> revisar cómo se está comportando lo que ya está que construir lo siguiente.

### Lo que ya funciona

| Fase | Estado |
|---|---|
| 1 · Ventas de Zettle | ✅ Webhook activo. Toda venta entra sola en ~1.8s |
| 2 · Interfaz del supervisor | ✅ Publicada. Cola, etapas, corregir, asignar |
| 3 · Jibble | ✅ Sincroniza cada minuto. 13 secadores reales |
| 4 · Foto del carro | ✅ Opcional, cámara directa, bucket privado |
| 5 · Analítica | ✅ Construida (19/jul/2026) — **pero con un solo día de datos** |

> ⚠️ **La Fase 5 está construida, no validada.** Se armó el mismo día que arrancó la
> operación, así que los primeros números salen de un día y encima sucio (13 carros
> `es_prueba`). La maquinaria está verificada; los números todavía no significan nada del
> negocio. Revisar de nuevo cuando haya una semana limpia.

### Dónde vive cada cosa

- **App del supervisor:** `https://rushmexicali.github.io/app-rush/` (GitHub Pages, carpeta
  `docs/`). Requiere código de acceso — está en el `.env` como `CODIGO_ACCESO`.
- **Reporte del dueño:** `https://rushmexicali.github.io/app-rush/reporte.html` — mismo
  código, **página aparte a propósito**. El reporte es para el dueño y la app para el
  supervisor; meterlos juntos le agregaría al supervisor un botón que no le sirve.
- **Repo:** `github.com/rushmexicali/app-rush` (público — por eso existe el código de acceso).
- **Supabase:** proyecto `rwoyfvddhlabmmuvkpjx`, región West US.
- **Edge Functions:** `zettle-webhook` (recibe ventas), `app` (API de la pantalla),
  `sincronizar-jibble` (cron cada minuto).
- **CLI de Supabase:** en `herramientas/` (ignorado por Git). Se despliega con
  `supabase functions deploy <nombre> --no-verify-jwt`.
- **SQL:** se corre por la API de administración, no pegando en el panel. Ver los scripts.

## 12.1 El reporte diario (Fase 5, 19/jul/2026)

Corte automático a las **8:30 PM hora de Mexicali**, guardado para siempre.
*(Era 10 PM; el dueño lo movió el 20/jul/2026.)*

> **Se comprobó antes de moverlo, no después:** el único día con datos reales (19/jul) tuvo
> la última venta a las 19:36 y la última entrega a las 20:14. Cero actividad después de
> 20:30. ⚠️ Pero el margen se achicó: un carro entregado después de las 8:30 **no entra** en
> la fila congelada de ese día — en pantalla sí se ve, porque el día de hoy siempre se
> recalcula al vuelo, pero el histórico queda corto. Si algún día se alarga el turno, hay que
> mover esto.

**Qué trae:** vehículos lavados, autos y tiempo promedio de secado por equipo, espera
promedio por carro, desglose con/sin aspirado, y cuántas placas se alcanzaron a leer.

### Lo que quedó abierto se cierra solo (20/jul/2026)

El autolavado cierra a las 8 PM. A las **8:30**, justo antes de congelar, `cerrar_pendientes()`
entrega todo lo que siga abierto para que la cola amanezca limpia.

- **8:30 y no 8:00**, aunque cierren a las 8: a las 8:00 en punto todavía hay carros
  legítimamente secándose (el 19/jul la última entrega real fue a las 20:14). Cerrarlos ahí
  les cortaría el cronómetro a la mitad. Media hora de gracia.
- **Va dentro de `congelar_reporte`, antes de congelar — no en un cron aparte.** Con dos
  crones, si el de cerrar se retrasa, el reporte se congela con carros sin terminar y ese
  número queda mal para siempre. Así el orden es correcto por construcción.
- **No usa `avanzar_etapa`**, que rechaza los carros en prelavado ("primero asígnale línea y
  secador"). Justo esos son los que se quedan atorados para siempre.

⚠️ **Los tiempos de un cierre automático son ficción, y por eso no se miden.** Un carro que
nadie cerró no tiene hora real de entrega. Si esos tiempos entraran a los promedios, un solo
carro olvidado desde las 3 PM metería 5 horas de "secado" y hundiría al equipo que lo secó —
se verían pésimo por un descuido del supervisor. Es el mismo problema que la migración `008`
(`es_prueba`): mediciones que **parecen** datos.

Así que: se marcan con `cerrado_automaticamente`, **sus tiempos quedan fuera de los promedios**
(secado y espera, generales y por equipo), pero **sí cuentan como vehículo lavado** — la venta
existió y el carro vino.

**Y el reporte dice cuántos fueron.** Eso no es adorno: `vehiculos_sin_terminar` era lo que
delataba dónde se traba la operación, y al cerrar todo automáticamente ese número sería
**siempre 0** y la señal se perdería en silencio. `cerrados_automaticamente` la reemplaza. Si
un día salen ocho, el supervisor no está cerrando carros y hay que ir a ver por qué.

Probado con el bloque `do $$ ... raise`: dos carros de prueba (uno secando desde hacía 5 h,
otro nunca asignado) pasaron a entregados, las asignaciones se cerraron, `sin_terminar` bajó de
2 a 0, `cerrados_automaticamente` subió a 2 — y el secado promedio **no se movió ni un segundo**
pese a los 17,100 s fabricados del primero.

**Decisiones que hay que respetar si esto se toca:**

- **Un "equipo" se arma solo.** Es el conjunto de quienes secaron *ese* carro juntos.
  Una persona sola es un equipo de uno. No hay lista de equipos que mantener.
- **Los equipos se miden por SEPARADO según el tipo de servicio** (20/jul/2026). El dueño:
  *"no vale la pena comparar equipos que secaron completos con los que secaron express, es
  como comparar peras con manzanas"*. Tres secciones, y el orden importa:

  | Sección | Qué es | El 19/jul |
  |---|---|---|
  | **Paquetes completos** (con aspirado) | La mayoría. Lo que de verdad hay que medir. Va primero | 32 carros · 36.6 min |
  | **Express** (sin aspirado) | Menos trabajo por carro | 7 carros · 9.7 min |
  | **Encerado manual y superbrillo** | Tardan más por naturaleza | 1 carro · 42.4 min |

  **Un express tarda ~4× menos que un completo**, así que juntarlos no era un detalle
  estético. Ejemplo real del 19/jul: *Walter Rodríguez* salía como un solo renglón de
  **6 carros a 516 s** y parecía por mucho el más rápido del taller. Separado se ve la
  verdad: **5 express a 619 s y 1 completo**. No era más rápido; estaba haciendo otro
  trabajo. Un mismo equipo puede salir en varias secciones.

- **`tipo_de_servicio()` se monta sobre `lleva_aspirado()`, NO sobre `es_lavado_express()`.**
  Se probó con un producto inventado y ahí se vio por qué: `es_lavado_express` es un OR
  simple y devuelve **`false`** para lo que no conoce, mientras que `lleva_aspirado` tiene la
  lista blanca y devuelve **NULL**. Preguntándole a la primera, cualquier paquete nuevo dado
  de alta en Zettle se colaba solo y en silencio a la sección de completos — justo el
  promedio que toda la separación existe para mantener limpio. Lo no reconocido sale en
  **"Sin clasificar"**, visible.

### El catálogo real (recibido 20/jul/2026 — antes se adivinaba)

Hasta ese día todo lo que se sabía del catálogo salía de **un** día de ventas. El dueño mandó
el export de Zettle y cambió varias suposiciones.

| Categoría | Productos | ¿Crea carro? | Sección del reporte |
|---|---|---|---|
| `Paquetes` | Completo, Completo Cera, Express, Manual, Pasajeros, Solo Interior, TriCera Servidor Público | Sí | según express |
| `Paquetes Especial` | **Encerado Manual** ($600-900), **Super Brillo** ($800-1300), Detallado | Sí | **encerado** |
| `Descuento` | Instagram, Passie Completo, Completo Arrendatarios | Sí | con aspirado |
| `Promo` | Gratis (6to Lavado, OXXO, Admin, Cortesía…) | Sí | con aspirado |
| `Aroma`, `Extras`, `Insumos` | Pinito, Tapetes, Trapos… | **No** — mostrador | — |

🔴 **Bug grave que esto destapó: seis servicios NUNCA creaban carro.** La migración `020`
limitó la creación a `Paquetes` y `Promo` para matar el carro fantasma del Pinito — correcto
entonces, pero dejó fuera `Descuento` y `Paquetes Especial`, que ese día no se habían vendido.
Un **Super Brillo de $1,300**, el servicio más caro, se cobraba y **nunca aparecía en el
teléfono del supervisor**. Arreglado en la `041`, que ahora lista las categorías que **no**
crean carro en vez de las que sí: una categoría nueva cae del lado de "sí crea carro", que es
el error barato. El caro es el servicio invisible, y es el que acababa de pasar.

- **La categoría de Zettle es la que agrupa**, no el nombre del producto. El dueño ya separó
  lo que tarda más en `Paquetes Especial`; usar su taxonomía significa que un producto nuevo
  ahí cae solo en la sección correcta sin tocar código.
- **`Manual` NO es el encerado.** Se había supuesto que sí. `Manual` (Paquetes, $400-500) es
  lavado a mano; el encerado es `Encerado Manual` (Especial, $600-900). Y sigue viva la trampa:
  `Manual` + variante `Express` es un **express**.
- **`Instagram` y `Passie` son Completo Cera** con descuento de publicidad — el dueño los tiene
  aparte para medir si la publicidad sirve. Para medir secado son completos. La columna
  `carros.categoria` conserva `Descuento`, así que medir la efectividad sigue siendo una
  consulta.
- **`Pasajeros`** (combis) tiene variantes `Tunel Express` / `Manual Express` — ésas son
  express. `es_lavado_express` ya las reconoce.
- **Precio 0 = monto libre en caja** (`Detallado`, `Faros`).

> El relleno hacia atrás de `carros.categoria` fue posible porque desde el día uno se guarda
> el aviso completo de Zettle en `ventas.payload`, aunque entonces no se usara. Esa decisión
> es la que permitió reconstruir sin volver a pedirle nada a Zettle.

> ⚠️ **Nota histórica:** el nombre del superbrillo no estaba verificado antes de recibir el
> export; se adivinaba por patrón `%brillo%`. Resultó ser `Super Brillo` (dos palabras) y el
> patrón sí lo atrapaba, pero fue suerte. Ahora manda la categoría, y el patrón por nombre
> quedó sólo como respaldo para carros viejos sin `categoria` guardada.
>
> Y de paso: **el catálogo de Zettle no se puede leer por API** — la llave tiene sólo
> `READ:PURCHASE`, a propósito. Por eso el catálogo llegó como export de Excel. Si vuelve a
> hacer falta, se pide así; no se adivina.
- **"Espera" es de que paga a que se lo entregan** — el tiempo completo del cliente,
  no el tiempo muerto.
- **Express y aspirado son la MISMA regla, no dos.** El dueño lo dijo así: los express no
  llevan aspirado *y* son los que van a la línea 1. Por eso hay **una sola** función,
  `es_lavado_express(producto, variante)`, y `lleva_aspirado` se define como *"todos los
  paquetes menos los express"*. Tenerlas separadas es exactamente como se desfasan.

  **Un lavado es express si:** el producto empieza con `Express`, **o** es `Manual` con
  variante `Express` / `Express Grande`.

  La trampa es `Manual`: el mismo producto cae de los dos lados según su variante. Un
  producto desconocido devuelve NULL y se cuenta como "sin clasificar" — nunca se adivina.

  > Corregido el 19/jul/2026. `es_express` se calculaba solo del nombre del producto, así
  > que un `Manual`+`Express` entraba sin banderita y **la base le rechazaba la línea 1**
  > ("La linea 1 es solo para express"). Nunca tronó porque no había entrado ninguno.
- **El día es de 00:00 a 23:59 hora de Mexicali**, no UTC. `pg_cron` corre en UTC y Mexicali
  cambia de horario, así que el corte se agenda a **dos** horas UTC y la función solo escribe
  si la hora local es la correcta. Exactamente una de las dos pega cada día.
  Hoy: cron `30 3,4 * * *` UTC, la función exige hora local `20`.
  (Verano `03:30 UTC = 20:30`; invierno `04:30 UTC = 20:30`.)
- **Un total que no cuadra con su propio desglose casi siempre es un join que multiplica.**
  El 20/jul/2026 el reporte decía que un secador tenía 4 rechazos y el desglose de motivos
  sumaba 2. Era un `join lateral` ya agrupado que se unía *antes* del `group by`, así que
  cada rechazo se multiplicaba por los motivos distintos de esa persona. **Nunca se había
  visto porque con un solo motivo el número sale bien.** Arreglado en la migración `036`.
- **El día de hoy siempre se calcula al vuelo**, aunque ya exista fila congelada. Un día en
  curso todavía cambia.

**Dos trampas del modelo de datos** que cualquier consulta nueva tiene que respetar:

1. **`asignaciones.fin` casi siempre es NULL.** Solo `regresar_etapa` lo llena; la entrega
   normal nunca cierra la asignación. El tiempo de secado sale de la **etapa** del carro.
2. **Un carro puede tener varias filas de la misma etapa.** "Corregir" borra la etapa abierta
   y reabre la anterior. Hay que usar `sum(segundos)`, no suponer una fila.

**El historial por placa es un PISO, no un total.** La placa sale de la foto y la foto es
opcional; un carro sin foto no cuenta como visita. La pantalla lo dice explícitamente porque
si no, "vino 3 veces" se lee como total y lleva a conclusiones falsas.

> ⚠️ **Pero también puede SOBRECONTAR, y eso no estaba previsto (20/jul/2026).** Se creía
> que el error solo iba hacia abajo. No: si el supervisor le toma la foto al carro
> equivocado, esa placa suma una visita que nunca existió.
>
> Pasó de verdad. Los carros 69 y 71 quedaron los dos con la placa `BVJ-113-A`. Mirando las
> fotos, las dos eran del mismo Accord negro. La línea de tiempo lo explica: el 69 se entregó
> a las 18:44, y a las 18:53 — en un apuro donde despachó el 70 y el 71 en dos minutos — el
> supervisor fotografió otra vez ese Accord, que seguía físicamente en el patio, y la foto se
> le pegó al 71. El historial decía **2 visitas y $520** de un carro que vino una vez y pagó
> $260.
>
> **Cómo se supo cuál era el bueno, que es lo que hay que repetir:** no por la foto. La
> **nota de caja** del 71 decía `AU GRIS`, y la escribió la cajera al cobrar, viendo el carro
> del cliente. Es un testigo independiente del supervisor. Cuando la foto y la nota no
> coinciden, **gana la nota**: el supervisor tiene 200 carros y prisa, la cajera tiene el
> carro enfrente. Además, un `Completo` de $260 "entregado" 2 minutos después de entrar es
> imposible y delata el apuro.
>
> Se arregló quitándole al 71 la foto y la placa ajenas (conservó su color GRIS). **El
> archivo en Storage NO se borró**, solo se despuntó el registro, por si algún día se quiere
> revisar.
>
> Esto no tiene arreglo en código todavía: nada impide fotografiar el carro equivocado. Lo
> barato sería avisar cuando dos carros del mismo día comparten placa — es una señal casi
> segura de foto mal pegada.

**Solo los Paquetes crean carro** (arreglado el 19/jul/2026). Una venta de puro `Pinito`
(categoría `Aroma`) creaba un carro fantasma en la cola e inflaba el conteo. Ahora se busca en
todos los renglones del ticket, no solo en el primero — eso arregló de paso que un ticket con
el aroma primero se guardara como "Pinito".

> ⚠️ **PENDIENTE, del mismo tipo: los reembolsos también crean carro.** El 19/jul/2026 el
> carro 72 entró con `monto = -270` (una devolución de un Completo Cera) y el supervisor lo
> procesó como si fuera un lavado. Infla "vehículos lavados" en uno. El arreglo probablemente
> sea ignorar los montos negativos en `producto_del_vehiculo`, pero **falta confirmar con el
> dueño** que un monto negativo siempre es devolución y nunca un lavado real.

### Cómo trabajar aquí

- **Desplegar función:** CLI de Supabase con el token del `.env`.
- **Correr SQL:** `POST api.supabase.com/v1/projects/<ref>/database/query` con
  `SUPABASE_ACCESS_TOKEN`.
- **Publicar la app:** commit + `git push` con `GITHUB_TOKEN`. Pages republica en ~1 min.
- **Verificar:** siempre con `curl.exe` contra la API real, nunca asumiendo.

### Lo siguiente (en este orden)

1. **VIGILAR, no construir.** Los supervisores empezaron a usarla el 19/jul/2026 por la
   tarde. Lo primero de la siguiente sesión es ver cómo se portó, con consultas reales:
   - ¿Cuántas fotos se están tomando? ¿De cuántas se leyó la placa?
     `select count(*) filter (where foto_path is not null), count(*) filter (where placa is not null) from carros where creado_en::date = current_date`
   - ¿Hay rechazos? ¿De quién y por qué? (tabla `rechazos`)
   - ¿El corte de las 10 PM se congeló solo? (`select * from reportes_diarios`)
   - ¿Cuántos carros quedaron sin entregar al cierre? Eso delata dónde se traba.
2. **Preguntarle al dueño cómo le fue al supervisor.** El Paso 7 (darle el teléfono sin
   explicar nada y anotar dónde se traba) por fin está ocurriendo de verdad.
3. **Cuando haya una semana limpia, revisar la analítica.** Hoy los números salen de un día
   sucio y no significan nada del negocio. Ver `es_prueba`, `cancelado_en` y `etapas_medibles`.

### Lo que se construyó el 19/jul/2026 (para orientarse rápido)

Migraciones 018 a 032, todas de ese día. En orden de qué tan importante es entenderlas:

| Migración | Qué resuelve |
|---|---|
| `024` | **Un solo toque antes de secar.** Reescribe la máquina de etapas. La más delicada |
| `029` | Devoluciones: no crean carro y cancelan el original (`cancelado_en`) |
| `030` | **Rendimiento** para 150-200 carros: cierra asignaciones al entregar, índices |
| `032` | La URL firmada de la foto deja de cambiar en cada consulta |
| `026` | Rechazos de entrega, una fila por secador + `grupo` para contar eventos |
| `021`, `027`, `031` | El reporte diario (la 031 es la versión viva) |
| `020` | Solo los Paquetes crean carro (el carro fantasma del Pinito) |
| `018` | La nota de caja también puede venir en el nombre del descuento |

**Cómo se probó lo delicado, y cómo conviene seguir haciéndolo:** con un bloque `do $$ ... $$`
que arma el escenario completo y termina con `raise exception` para que **todo se revierta**.
Así se prueba sobre la base real sin ensuciar la cola del supervisor. Ver el historial de
git; el patrón vale más que cualquiera de las pruebas sueltas.

## 13. Decisiones pendientes (llenar con el tiempo)

**Abiertas al 19/jul/2026, en orden de urgencia:**

- **¿Un carro entregado y luego devuelto cuenta como lavado?** Hoy SÍ cuenta (el carro se
  lavó y ocupó gente; devolver el dinero no deshace el trabajo). Solo se cancela si la
  devolución llega mientras el carro sigue en la cola. **Decisión mía, no confirmada.**
- **¿Cuántos rechazos son "muchos"?** El reporte los cuenta pero no hay meta. Se decide
  viendo datos reales, no inventando un número.
- **El histórico de placas es un piso, no un total** — la foto es opcional. Si se quiere que
  sea confiable, habría que hacer la foto obligatoria, y eso choca con la regla de que nunca
  bloquee al supervisor en día pesado.
- **El respaldo mensual es manual.** El botón "Descargar respaldo" baja un `.json`. Nadie lo
  ha hecho todavía; si pasan meses sin bajarlo, el punto de tenerlo se pierde.

---

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

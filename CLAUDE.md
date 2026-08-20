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
- **Cambios de UX del app en vivo: front y back se despliegan JUNTOS, de preferencia en el
  corte de turno.** Aprendido el 24/jul/2026: se desplegó el backend solo (para probar
  `/foto`), lo que dejó un estado medio-desplegado y **forzó** subir el front a media operación,
  con el supervisor y 11 carros en la cola. Un cambio de pantalla a mitad del turno choca con la
  regla de "a prueba de abuelitos" (cero sorpresas). Si un cambio toca la UI que el supervisor
  ve, se termina TODO, se prueba, y se sube front+back de corrido y en el momento de menos
  operación — no el backend por su cuenta.

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
  | Antes de secar (prelavado + túnel + espera), **si NO es a mano** | a los **20 min** |
  | Antes de secar, **lavado a mano** | nunca (tarda más de por sí) |
  | Secando | a los 35 min |

  El 19/jul/2026 el umbral de antes-de-secar era **19 min** (15 de prelavado + 4 del túnel),
  cuando el flujo pasó a un solo toque y el estado tuvo que absorber el túnel.

  **Cambió a 20 min el 20/jul/2026**, y se le agregó la excepción del lavado a mano. Motivo: un
  lavado normal que pasa de 20 min sin asignarse casi seguro es que el supervisor lo **olvidó**
  (pasó con una `CAMIONETA BLANCO ACURA` que acumuló **38 min** de prelavado antes de que se le
  asignara). Pero un lavado **a mano** tarda más ahí de forma legítima —se lava a mano, no pasa
  por túnel—, así que a ésos no se les pinta rojo por el tiempo de prelavado. El umbral vive en
  `DEMORA_SEG.prelavado` (1200 s) y la excepción en el cálculo de `limite` por carro en `/cola`
  (`a_mano && prelavado → limite = 0`). Cuando el carro se asigna, pasa a secando y manda el
  umbral de 35 min.

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
- La foto abre **directo la cámara**, sin preguntar nada.
  - **El botón de galería se quitó el 20/jul/2026:** no se usaba. El caso "la foto se tomó
    fuera de la app" que lo justificaba (agregado el 19/jul) no ocurrió en la operación real.
    Queda un solo botón, que además es la regla de un-toque de esta sección.
  - **La cámara se habilita solo cuando el carro ya tiene carril y secador** (20/jul/2026).
    Antes de eso se ve **apagada** (no desaparece: un botón que aparece solo confunde al
    supervisor de la tercera edad). Un carro recién pagado y sin asignar puede no estar
    identificable todavía, y ahí es cuando una foto se pegó al carro equivocado el 19/jul;
    esto angosta esa ventana. Se mide con `carros.linea` y `carros.secadores`.
  - **Al lado va el botón de info (la ⓘ), donde estaba la galería** (20/jul/2026). Abre el
    desglose de tiempos del carro (ver sección 5). Es un botón y **no** un toque a la tarjeta
    a propósito, a pedido del dueño: evita abrir el desglose por accidente.
- **El botón "atrás" del teléfono cierra la pantalla de encima, no sale de la app**
  (20/jul/2026). En una app de pantalla completa el back salía de la app. Ahora cada pantalla
  que se abre (Asignar, Entrega, Finalizados, Detalle) empuja un estado al historial y el back
  —o los botones de Volver/Cancelar— cierra la de encima y regresa a la anterior. Regla para
  no desincronizar: **todo** cierre pasa por `cerrarPantalla()` → `history.back()` → `popstate`,
  el único que ejecuta el cierre real (abrir empuja uno, cerrar consume uno).
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
- **Servicio especial → banderita morada** (20/jul/2026). Los servicios que **no** son un
  lavado normal se anuncian con su propio nombre: `ENCERADO MANUAL`, `SUPER BRILLO`,
  `DETALLADO`, `LAVADO A MANO`.

  **Por qué existe, textual del dueño:** *"nos pasa mucho que los gerentes y secadores no leen
  los tickets y asumen que es un lavado, creando quejas de los clientes al no seguir las
  instrucciones"*. No es adorno: un encerado de $900 tratado como un lavado de $260 es un
  cliente molesto y trabajo que hay que rehacer.

  - **Morado (`#a371f7`) y no amarillo.** El amarillo ya es del express y significa *"va a la
    línea 1"*. Esto significa otra cosa — *"el trabajo es distinto"* — y confundirlos sería
    peor que no marcarlo. El morado estaba libre (era del estado `por_asignar`, que ya no
    existe).
  - **Son TRES preguntas independientes**, y un carro puede necesitar las tres banderitas:

    | Pregunta | Función | Banderita |
    |---|---|---|
    | ¿A qué línea va? | `es_lavado_express` | ⚑ EXPRESS (amarilla) |
    | ¿Qué trabajo es? | `aviso_de_servicio` | ⚠ SUPER BRILLO / ENCERADO MANUAL (morada) · DETALLADO (naranja) |
    | ¿Cómo se lava? | `es_lavado_a_mano` | ⚠ LAVADO A MANO (cian) |

  > ⚠️ **Lo dice la VARIANTE, no el nombre del producto.** Este error se cometió el
  > 20/jul/2026 y sólo se encontró porque el dueño hizo cuatro ventas reales a propósito:
  >
  > ```
  > Encerado Manual / Normal  → el producto dice "Manual" y NO es a mano
  > Super Brillo    / Manual  → el producto no dice "Manual" y SÍ lo es
  > ```
  >
  > El nombre engaña **en las dos direcciones**: "Manual" en `Encerado Manual` describe el
  > encerado (se encera a mano), no el lavado. Es la misma trampa que ya estaba documentada
  > con `Manual`+`Express`, y se volvió a caer en ella. Quien decide es la variante:
  > `Manual…` = a mano, `Normal`/`Grande` = túnel.
  >
  > La causa de fondo fue meter dos preguntas en una sola función: el aviso de servicio
  > **tapaba** al de lavado a mano. Separadas, las dos salen.
  - **El texto sale del nombre del producto**, no de una etiqueta inventada: si el dueño da de
    alta `Encerado Cerámico` en `Paquetes Especial`, la tarjeta lo anuncia sola.
  - **Se repite en la pantalla de asignar**, aunque ya salga en la tarjeta: ahí es donde se
    decide *quién* lo seca. Repetirlo cuesta un renglón; no repetirlo cuesta una queja.
  - Vive en `carros.aviso`, **columna generada** sobre `aviso_de_servicio()`. Se hizo columna
    y no cálculo en la Edge Function justamente para no tener dos reglas para la misma
    pregunta — el error que este proyecto ya cometió tres veces. Además se puede consultar:
    `select count(*) from carros where aviso = 'LAVADO A MANO'`.
  - 🔴 **Y el error se había cometido OTRA VEZ, adentro.** Hasta el 22/jul/2026,
    `aviso_de_servicio()` y `tipo_de_servicio()` llevaban la **misma condición copiada palabra
    por palabra** (`categoría = 'Paquetes Especial'` o el nombre empieza con
    `encerado`/`detallado` o contiene `brillo`), cada una devolviendo algo distinto con ella:
    la primera el texto de la banderita, la segunda la sección del reporte. Nunca falló porque
    nadie había dado de alta un servicio nuevo — el día que pasara, una se enteraba y la otra
    no, **en silencio**. La migración `055` la dejó en un solo lugar,
    `es_servicio_especial(producto, categoría)`, y las dos le preguntan a ella. **Si la regla
    cambia, se cambia ahí y nada más.**
- **Asignar unidad**: el único toque antes de secar. Abre pantalla completa con **solo línea y
  secador(es)**, con botones grandes (24/jul/2026). Tipo y color ya vienen de la nota de la
  cajera; marca/submarca/tipo salen de la foto. Antes esta pantalla también capturaba
  tipo/color/marca — se quitaron (ver §9 "La marca, submarca y tipo salen de la foto").
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
| **Asignar unidad** / **Entregado** (grande) | El toque principal. **Nunca manda solo: siempre abre una pantalla.** Lleva **guiones rojos girando** por la orilla (ver abajo) |
| **Corregir** | Abre la misma pantalla en modo captura: tipo, color — **y si el carro ya seca, también los secadores** (ver abajo). La marca ya no se edita (sale de la foto, 24/jul/2026). Sirve en cualquier momento, incluso antes de asignar |
| **Regresar** | Deshace el paso anterior. Apagado en prelavado, no hay a dónde |

**El botón de Asignar lleva guiones rojos girando por la orilla** (`- - - -`, marching ants),
solo ése (20/jul/2026). El supervisor le picaba al ícono redondo de "Prelavado + Túnel" por ser
del mismo azul; el movimiento marca cuál es el botón que sí se toca. En "Entregado" (verde) no
va. Primero fue un *glow* pulsante; el dueño lo cambió a guiones. Son cuatro tiras animando
`background-position` (no se rota nada: rotar un botón tan ancho proyectaba los rayos por toda
la pantalla).

**Corregir sí cambia los secadores** (20/jul/2026, corrige la regla vieja de "para eso está
Regresar"). Al abrir Corregir de un carro secando, los secadores actuales salen
**preseleccionados** y se editan libremente, igual que el tipo y el color (la **marca ya no**:
sale de la foto desde el 24/jul/2026). Uno que ya checó
salida sale en gris con "ya no aparece", para verlo y poder quitarlo. Al guardar,
`editar_carro` (migración `052`) reconcilia las asignaciones **sin tocar las etapas**, así que
el cronómetro de secado **no se reinicia** — esa es la diferencia con Regresar, que sí lo
reinicia. Regla: un carro secando no puede quedarse sin ningún secador (borraría todas sus
asignaciones), y el botón Guardar lo impide.

### "Borrar unidad" — sacar de la cola la información basura (29/jul/2026)

Arriba del contador de tiempo, en la esquina de cada tarjeta, hay un botón rojo **"Borrar
unidad"**. Saca de la cola un carro que el supervisor ya no va a trabajar (se fue el cliente,
se canceló, o de plano lo olvidó). Existe porque esos carros olvidados ensucian los promedios
y el conteo — es basura que entra por el lado del supervisor.

**Qué hace, textual del dueño:** *"se borra de la lista y no se consideran los tiempos de
secado. Toda la demás información se debe grabar... solo la hora de entrada, mas no la de
salida."*

- **No borra la fila.** Reusa `cancelado_en` —el MISMO campo que ya saca un carro de `/cola` y
  del reporte (filtro `cancelado_en is null`, ya probado)— así que **no se crea una segunda
  regla de exclusión** (el error que este proyecto ya cometió varias veces). Conserva
  producto, monto, nota, foto, hora de entrada; **`entregado_en` nunca se toca** (sin hora de
  salida); las etapas y asignaciones quedan intactas (quién lo secaba sigue registrado). Es
  **reversible** (`cancelado_en = null`).
- **Se separa de las devoluciones** con `carros.cancelado_motivo = 'borrado_supervisor'`
  (columna nueva, migración `083`). El reporte agrega el campo **`borrados`** (subconjunto de
  `cancelados`) y la página del dueño lo muestra cuando no es cero. Verificado byte a byte: el
  resto del reporte quedó idéntico en 6 días.

**Cuándo aparece y cuándo se habilita** — pensado para que el supervisor (de la tercera edad)
no borre por accidente una unidad que iba bien:

  | Estado del carro | El botón aparece | Se habilita a los |
  |---|---|---|
  | **Sin asignar** (prelavado) | sí | **30 min** sin asignar |
  | **Secando** | sí | **2 h** secando (un carro 2 h "secando" es un olvido, nadie tarda eso) |
  | Cualquier otro | no | — |

  Antes de cumplir el tiempo el botón **se ve apagado, no desaparece** (mismo patrón que la
  cámara: un botón que aparece solo confunde). El umbral vive en `BORRAR_UMBRAL` (front) y se
  aplica por estado. Como la firma de `pintar()` no incluye el tiempo, quien prende el botón al
  cruzar el umbral es `actualizarRelojes()` (cada segundo), no un rebuild.

- **Los candados de verdad viven en la base** (`borrar_unidad`, migraciones `083`+`084`): solo
  `prelavado` con 30+ min, o `secando` con 2h+ desde el inicio de la etapa de secado abierta.
  Así una llamada suelta no puede borrar un carro bueno aunque el front falle. El "2 h secando"
  se mide desde la etapa `secando` con `fin is null` — el mismo dato que cuenta el reloj.
- **Confirma antes de borrar** (es una acción que quita el carro de la lista). Es idempotente:
  borrarlo dos veces no truena.

Probado con `do $$ ... raise` (secando 3h borra, 1h rechaza, prelavado 40min borra, recién
entrado rechaza; `entregado_en`/etapas/`creado_en` intactos) y contra la API real
(no destructivo). El front se verificó por **geometría** en el navegador: el botón queda
arriba del reloj sin encimarlo, y una tarjeta sin botón se ve idéntica a antes.

**Los secadores asignados salen en la tarjeta** (20/jul/2026), debajo del servicio y del mismo
tamaño, para que el dueño los vea sin abrir el carro. Vienen de la cola (`/cola` ya los daba).

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

**Se llama "Finalizados"** (20/jul/2026), no "Ver entregados de hoy": ya no es sólo de hoy.

- **Selector de día** junto a "Volver a la cola". Es un `<select>` **nativo** y no un menú
  propio: la sección 4 prohíbe menús, pero el selector del teléfono es un toque y lo dibuja
  el sistema con letra grande. Escribir un desplegable a mano sería *más* menú, no menos.
  `entregados_del_dia` ya aceptaba la fecha desde la migración `028`; el endpoint la tenía
  fija en `null`.
- **Tocar los datos de un carro abre su desglose:** prelavado, túnel, secado, total y quiénes
  lo secaron. Se toca la zona de **datos**, no la tarjeta entera — si fuera toda, un dedo que
  falla el botón de Restaurar abriría el desglose y parecería que el botón no sirve.
- El desglose **avisa cuando el tiempo no es real** (cerrado automático, tiempo imposible).
  Ahí un número se lee como si fuera medido.
- `detalle_del_carro` devuelve los segundos **ya sumados** por etapa: un carro puede tener
  varias filas de la misma etapa porque "Corregir" reabre la anterior. El total es de **pago a
  entrega**, no la suma de etapas — entre etapas hay huecos y el cliente los vive igual.

**El mismo desglose, pero EN VIVO, para un carro que aún se trabaja** (punto 5 del dueño,
20/jul/2026): el botón de info (la ⓘ) de la tarjeta abre esta misma pantalla, con el
**cronómetro de secado corriendo** (mm:ss, en verde, "· en curso"), el total contando desde
que pagó, y los secadores ("Secando ahora"). Prelavado y túnel salen estáticos (ya cerrados).

- Mientras el carro no se entrega, `secando_seg` y `total_seg` salen **nulos**: la etapa de
  secado está abierta y la columna generada `segundos` es nula sin `fin`. La migración `053`
  agregó `abierta_etapa` + `abierta_inicio` a `detalle_del_carro` para que la app cuente en
  vivo desde el inicio de la etapa abierta. `/carro` no cambió (pasa el resultado tal cual).
- El desglose de Finalizados (carro entregado) queda **igual**: estático, en minutos, "Lo
  secaron". La ruta se ramifica con un flag `enVivo` que solo manda el botón de info. El
  cronómetro se apaga al cerrar la pantalla.

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
- **Sólo se sincroniza de 6 AM a 10 PM, hora de Mexicali** (22/jul/2026, migración `060`).
  Antes corría cada minuto **24/7**: 1,440 invocaciones diarias y ~7,200 llamadas a la API de
  Jibble, muchas preguntando "quién está checado" a un taller cerrado de madrugada. Ahora son
  ~960 y ~4,800 (-33%). La ventana lleva margen a propósito —dos horas antes de abrir y dos
  después de cerrar— por si un turno se alarga.

  ⚠️ **La guardia va en la FUNCIÓN (`sincronizar_jibble_si_toca`), no en el horario del cron.**
  `pg_cron` corre en UTC, y escribir "13-5 * * *" sería clavar el desfase a mano: Mexicali
  cambia de horario dos veces al año, y si algún día cambia la ley —como ya pasó en México en
  2022— la ventana queda mal para siempre sin que nadie se entere. Así, el cron dispara cada
  minuto (cuesta nada: es un `select` que ni sale de la base) y **quien decide es Postgres
  preguntándole a `America/Tijuana`**. Mismo patrón que `congelar_reporte` (migración `035`).

  Se verificó hora por hora sobre **un año completo (8,760 horas)**: 0 corridas fuera de la
  ventana local, y los 364 días completos dan exactamente 16 horas. El cron con horario UTC
  fijo habría estado mal **254 horas al año** (ej.: el 30/nov a las 21:00 local no habría
  corrido, y el 1/dic a las 5:00 AM sí).
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
  rojo: **"⚠ \<nombre(s)> marcó salida. Asigna a otro secador"** (texto del 20/jul/2026), y el
  botón **Corregir se pinta con los guiones rojos girando** para llevar al supervisor justo
  ahí — que es donde ahora se reasigna (Corregir edita secadores). No se reasigna solo ni se
  borra el registro: quién secó ese carro es dato de eficiencia, y además puede que otro ya lo
  haya tomado. El supervisor decide. Los guiones solo salen en ese caso (usan la clase genérica
  `.girando`, la misma del botón de Asignar).
  - **Si la tarjeta ya está demorada (pasó los 35 min, toda roja), el aviso y los guiones se
    vuelven VERDES** (20/jul/2026): en rojo sobre rojo se perdían. El color del guion sale de
    la variable `--guion` (rojo por defecto, verde en `.carro.demorado`), y el mensaje usa
    `.demorado .ausente`. Aplica a cualquier `.girando` dentro de una tarjeta roja, así que un
    botón de Asignar demorado también trae los guiones verdes — mismo principio de contraste.
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

  > 🔴 **Medía al revés hasta el 20/jul/2026, y se corrigió (migración `051`).** La bandera se
  > apagaba en cuanto `editar_carro` recibía un tipo o color no nulo, **sin fijarse si el valor
  > cambiaba**. La pantalla de asignar viene prellenada con lo que puso la nota; el supervisor
  > confirma sin tocar y `/asignar` reenvía esos mismos valores → la bandera se apagaba. El
  > 20/jul la columna decía **1** cuando en realidad **25 de 25** ventas traían nota, y sobre
  > ese 1 se reportó (falsamente) que las cajeras no llenaban la nota. Arreglo: solo se apaga
  > si el valor es **distinto** al guardado (`is distinct from`). Aplica a Asignar y a Corregir.
  > **Se encontró midiendo, no leyendo el código**, y el dueño lo cachó porque él sabía que sí
  > había notas. Lección: si una métrica contradice lo que el dueño ve en el taller, el
  > sospechoso es la métrica — reconstruirla desde el dato crudo (aquí, releer `carros.nota`).

> ⚠️ **Actualización 20/jul/2026: el hábito ya arrancó.** El 19/jul solo 2 de 25 ventas traían
> nota (las puso el dueño). El 20/jul fueron **25 de 25** — las cajeras ya la están llenando y
> la app la interpreta bien (24 de 25; la única falla fue `A GUINDA` por `AU GUINDA`, código
> `A` que no existe). El respaldo de captura manual sigue ahí por si acaso.

### La marca, submarca y tipo salen de la foto — el supervisor ya no captura marca (24/jul/2026)

Hasta el 24/jul la **marca** solo la ponía el supervisor a mano al asignar (la nota de la
cajera da tipo, color y cliente, nunca marca). Una prueba sobre **59 fotos reales de archivo**
mostró que la misma foto que ya se usa para la placa saca **marca y modelo (submarca) con ~98%
de precisión** cuando la IA se compromete, y que hasta **cacha errores de captura del
supervisor** (en 59 carros: BYD→Buick, Lexus→Kia K5, SEAT→Suzuki). El costo marginal es casi
cero: la imagen ya se manda a Sonnet 5; solo se le piden más campos en la **misma** llamada
(`leerFoto`, antes `leerPlaca`).

Decisión del dueño: **quitarle al supervisor la captura de marca por completo.** Marca,
submarca y tipo de carrocería pasan a venir de la foto. Reglas:

- **Cualquier confianza se acepta (alta/media/baja). Solo `null` no se guarda.** El costo es
  que a veces entra una marca equivocada (1 de 54 en la prueba: un Dodge Attitude→Honda por
  rebadge); es dato descriptivo, no afecta reportes ni la línea 1, y se asume a cambio de cero
  fricción.
- **Aceptación parcial POR CAMPO:** si se lee la placa pero no la marca, se guarda la placa; un
  campo `null` **nunca** tumba a los demás. La placa sigue siendo estricta (`placa_legible`);
  marca/submarca/tipo se aceptan con la mejor identificación.
- **Si se lee la submarca pero no la marca, la IA deduce la marca** (Corolla→Toyota). Vive en
  el prompt.
- **Cuando la foto reconoce el MODELO (submarca), corrige el tipo de la cajera.** Una cajera que
  puso "camioneta" a un Corolla queda "automovil" (la IA sabe que un Corolla es sedán). ⚠️ **Solo
  cuando hay submarca** (migración `063`): sin submarca el tipo de la foto es puro ojo (falló 9 de
  57 en la prueba — un Wrangler salió "pickup"), así que **no pisa a la cajera**, solo rellena si
  venía vacío. En pantalla, cuando hay submarca el tipo genérico se **reemplaza** por el modelo:
  "AUTO BLANCO" → "TOYOTA COROLLA BLANCO" (se deja la marca para que modelos ambiguos —"MAZDA
  MAZDA3", "CHRYSLER 300"— no queden huérfanos).

Mecánica: `carros.submarca` (columna nueva, migración `061`). La foto se guarda con la RPC
**`guardar_datos_de_foto`**. ⚠️ **La foto es autoritativa, pero POR CAMPO** (migración `109`,
que angosta la `063`, que a su vez corrigió el `coalesce` original de la `061`). Dos reglas:

1. **Un campo se escribe cuando la lectura nueva trajo algo. Un nulo NO borra.** La `063` había
   dejado que el nulo se escribiera igual que el valor, así que una lectura que no alcanzó a ver
   la marca **borraba la marca que otra lectura sí vio**. Desde que existe el botón "Tomar foto
   otra vez" (`103`, para las pickups grandes) ese caso se dispara a diario.
2. **Excepción: si la placa leída es DISTINTA a la guardada, se reemplaza el juego completo**,
   nulos incluidos. Dos placas distintas son dos carros distintos: lo guardado era de otro carro
   y no hay nada que conservar. Ahí es donde la `063` tenía razón — re-tomar una foto buena
   **limpia** el dato de un carro fotografiado por error, y ésa es la única vía de corrección que
   hay, porque marca/submarca no se editan a mano.

> Lo que **no** cubre, dicho de frente: un carro con datos de otro cuya foto nueva tampoco
> alcanza a leer la placa se queda como estaba. Se prefiere así porque el otro extremo —borrar
> en cada lectura muda— estaba costando datos todos los días.

Y solo se escribe cuando **de verdad hubo lectura**: si Anthropic hace timeout o falla,
`leerFoto` devuelve `null` y `/foto` **no toca nada**. `placa_en` se pone
siempre; **no toca `datos_de_nota`** (esa mide si la cajera llenó la nota — mismo cuidado que la
`051`). El `detalle_del_carro` también devuelve submarca (`062`). Probado end-to-end: un carro de
prueba con tipo `camioneta` + foto de un Corolla quedó `marca=TOYOTA, submarca=COROLLA,
tipo_unidad=automovil, placa=A83-NVV-8`; y una segunda subida con datos basura los sobrescribió.

**En la app:** la pantalla de **Asignar** se redujo a **solo línea + secador** (se quitaron las
grillas de tipo/color/marca). **Corregir** conserva tipo y color (por si la nota viene mal)
pero **ya no la marca**. `/asignar` dejó de mandar tipo/color/marca; `/editar` dejó de mandar
marca. La grilla de marcas (`MARCAS_RAPIDAS`/`MARCAS_EXTRA`) y su andamiaje se borraron del
front.

### La placa se lee sola de la foto (implementado 19/jul/2026)

Cuando el supervisor sube la foto, la Edge Function `app` se la manda a **Claude Sonnet 5**
y guarda la placa en `carros.placa`. La placa aparece en la tarjeta con su propio recuadro,
antes de tipo/color/marca: es el único identificador que no se repite.
La lectura ahora la hace `leerFoto` (misma llamada que saca marca/submarca/tipo, ver arriba).

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

> ✅ **Verificado el 17/ago/2026:** el camino de las placas de Estados Unidos estaba escrito
> pero **no probado contra una placa gringa real**. Ya lo está: el carro 2649 (Honda CR-V rojo)
> traía placa de **California** `9VYE404` y se leyó correcta y completa, sin confundir el nombre
> del estado ni el marco del portaplacas con la placa. Salió de la prueba de la cámara fija de
> caja, ver §11.60.

- **No hubo que subir la resolución.** El `CLAUDE.md` decía que a 1280px la placa quedaría
  con ~130px y habría que subir a 2000px. Se midió con una foto real: la placa medía ~170px
  y se lee perfecto. Incluso a la **cuarta parte** de resolución (placa de ~42px) seguía
  leyéndola. La foto pesa ~100 KB de promedio (medido sobre el bucket completo el 19/ago;
  antes aquí decía ~150 KB) en vez de ~450 KB — importante con el wifi flojo
  del taller.
- **Sonnet 5 y no Opus:** tiene visión de alta resolución (lo que hacía falta) y cuesta un
  tercio. Va con `thinking` apagado y esfuerzo bajo porque esto es OCR, no razonamiento.
  Si algún día las lecturas salen flojas, ahí es donde hay que subirle.
- **Costo medido (corregido el 19/ago/2026):** **3,101 tokens de entrada por foto** — 1,488 del prompt (crecio al fusionar placa+marca+submarca el 24/jul) y ~1,613 de la imagen. Son **~$17.80 USD/mes** con ~86 lecturas al día, y **~$26.70 desde el 1/sep**
  al terminar el precio de introducción de Sonnet 5. El desglose vive en la memoria
  `costo-lectura-de-placa-anthropic`; lo que decía antes esta sección (1,698 tokens,
  $3.20/mes) contaba **sólo la imagen** y se quedaba corto por más del doble.
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
  - ~~Marca: grilla de botones~~ **La marca ya no se captura a mano (24/jul/2026):** sale de la
    foto, junto con la submarca y el tipo. La grilla de marcas se borró. Ver "La marca, submarca
    y tipo salen de la foto".
  - Color: grilla con los comunes (BLANCO, GRIS, NEGRO, ROJO, AZUL, VERDE) + botón **"Otro…"**
    para escribir uno raro (20/jul/2026). El campo se ve **siempre en MAYÚSCULAS** aunque el
    teclado esté en minúsculas: se sube en el `input`, no solo con CSS (con CSS solo se pinta y
    se guardaría en minúsculas, rompiendo el formato uniforme con la nota de caja).
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

## 11.40 Tercera tanda: lo que escribía antes de validar, y el reporte del dueño (19/ago/2026, migraciones `109`–`110`)

Cierra los tres del backend que quedaban de la auditoría y los cinco puntos del reporte que el
dueño había pedido seguir en otra sesión. Desplegado el mismo día, con el taller abierto, a
petición suya.

### Dos escrituras que ocurrían antes de saber si debían ocurrir (`109`)

- 🔴 **`editar_carro` escribía antes de validar.** El `update` de tipo/color/marca/línea iba
  **antes** de los tres checks de secadores, y en plpgsql **un `return` no revierte** (no abre
  subtransacción; solo un `exception` lo haría). El caso real: el supervisor abre Corregir de un
  carro secando, cambia el color, quita todos los secadores y guarda. La pantalla le dice *"Deja
  al menos un secador"* y él cree que no guardó nada — **pero el color ya quedó cambiado**, y las
  asignaciones ya se habían apuntado a la línea nueva. Es de las peores formas de fallar: la
  pantalla dice una cosa y la base guarda otra, sin que nadie pueda notarlo desde afuera. El
  arreglo no cambia ninguna regla: son las mismas validaciones y las mismas escrituras,
  reordenadas, con la frontera marcada en el código (`VALIDAR` / `ESCRIBIR`).

  > **La prueba reprodujo el bug contra producción antes de tocar el código**, y ése es el orden
  > que vale la pena repetir: primero se demuestra que el error existe, después se arregla. Si la
  > prueba hubiera pasado desde el principio, habría estado midiendo otra cosa.

- 🔴 **`guardar_datos_de_foto` borraba lo que no leyó.** Ver §9: ahora la foto es autoritativa
  **por campo**, y una placa distinta a la guardada sigue reemplazando el juego completo.

- **`/foto` no limpiaba `placa_en`.** `fotos_por_leer` exige `placa_en is null`, así que una
  re-toma **nunca** entraba a la cola de reintentos: si la lectura de esa foto se caía, se quedaba
  sin leer para siempre. Y es justo el flujo de las pickups grandes (`103`), donde el supervisor
  re-toma **porque** la primera lectura no vio la placa — o sea el caso donde `placa_en` siempre
  viene estampado. La gracia de 3 minutos de la vista impide que el obrero de fondo le gane a la
  lectura que `/foto` está haciendo en ese momento.

### El perfil del trabajador se pagina y se filtra (`110`)

Bajaba el historial **completo** en una sola respuesta: 351 carros = **134 kB**, creciendo lineal
para siempre. Ahora son **19 kB** (50 por página, con "Ver 50 más" y "Ver todos"), más filtro por
rango de días y por tipo de servicio.

- **El filtro no es comodidad: es la regla de peras con manzanas** (§12.1). Un promedio mental de
  esa tabla mezclando express con completos no significa nada, y era la única forma de leerla.
- **Los contadores de arriba respetan el filtro.** Un titular que diga 351 sobre una tabla de una
  semana es la misma contradicción que la `107` acababa de quitar del reporte del día.
- **`p_limite = 0` trae todo**, a propósito: así esto no se vuelve un tope silencioso.
- Cambió la firma, así que la migración **dropea la vieja primero** — un parámetro nuevo crea una
  **sobrecarga**, no un reemplazo (lección de la `052` y de la `098`).
- ⚠️ **Comprobado contra línea base:** sin filtro, la salida quedó **idéntica al byte** en los 16
  secadores (lavados, rechazos e historial completo). El paginado no cambió ningún número.

### Los cinco puntos del reporte, y sus menores

| Qué pasaba | Qué pasa ahora |
|---|---|
| Un rango de **un solo día** salía rotulado *"Día en curso — todavía puede cambiar"* | El modo lo dice **quien llama**, no se deduce de `dias > 1`. Las fechas del rango además salen formateadas, no crudas |
| *"N visitas"* se lee como total donde de verdad se lee | La nota de **piso, no un total** pasa al perfil de la placa y a los resultados de búsqueda, incondicional y en **una sola función** (`notaPiso`) |
| *"Historial por placa"* se pinta debajo del día y con su mismo `<h2>` | Subtítulo: es de siempre y **no cambia al escoger otro día** |
| El buscador de placas no tenía rebote ni guardia | 250 ms y verificación de respuesta vieja, como los otros dos del mismo archivo |
| Menores | El error del backend **se escapa**; un 401 en `cargarPlacas` deja de pintarse como *"no hay placas leídas"*; con un rango, *"este día"* dice *"en este periodo"*; en Últimos lavados la columna *"Última vez"* pasa a *"Día"* (el rótulo venía copiado de otra tabla donde sí significaba otra cosa) |

**Cómo se verificó el front:** en el navegador, con datos falsos y `pedirJSON` interceptado, no
mirando la pantalla. Se comprobaron las URLs que arma cada filtro, que el estado sobreviva al
re-render, que teclear 7 caracteres sea **1** consulta, y que una respuesta lenta de `"BV"` ya no
se pinte encima de la de `"BVJ113A"`.

### El ensayo de una migración completa, sin aplicarla

Las dos migraciones se corrieron **contra producción sin aplicarse**: se concatena el archivo de
la migración con el de su prueba y se mandan juntos, porque el endpoint de administración los
ejecuta en **una sola transacción implícita** y el `raise` final revierte también el
`create or replace function`. Después se confirma con `pg_get_functiondef` que la función viva
quedó sin tocar. La ventaja sobre envolver el DDL en `execute`: se ensaya **el mismo archivo** que
después se aplica, byte por byte. Para comparar contra el comportamiento viejo se antepone un
tercer archivo que guarde la línea base en una `temp table` — dentro de esa transacción la función
vieja todavía existe.

### Y la auditoría general quedó como skill

`.claude/skills/auditoria-general/`. Se dispara diciendo **"corre la auditoría general"**. Además
de reproducir los siete frentes, **obliga a cuestionar su propio método antes de correr**: si los
agentes siguen siendo los correctos, si salió algo nuevo, o si hay una forma más exhaustiva —
encargo del dueño el 19/ago. El argumento está escrito ahí: la auditoría anterior no tuvo pase
adversarial, y por eso alcanzó a producir un juicio por escrito sobre dos personas con nombre que
resultó falso.

## 11.45 Segunda tanda de la auditoría: el crítico, los tres que muerden solos y los números del reporte (19/ago/2026, migraciones `106`–`108`)

Después de los 7 priorizados (§11.50), esta tanda cierra el hallazgo crítico que había quedado
fuera, las tres cosas que pueden morder sin que nadie las provoque, y los cuatro números del
reporte que se contradecían.

### El perfil del trabajador dejaba de aplicar las dos reglas que todo el resto respeta

Es la pantalla donde se evalúa a **una persona con nombre**, y era la única vista del proyecto que
imprimía crudos los dos casos que el reporte excluye de sus promedios por ser ficción:

| Lo que se veía | Lo que era |
|---|---|
| **298 minutos** a nombre de Saul Ramirez (carro 2164) | Nadie lo entregó; lo cerró el corte de las 8:30 |
| **180 minutos** a nombre de Jaime Gallegos (carro 2121) | Igual |
| **99 carros históricos** con "0" o "1 minuto" | Olvidos entregados de golpe, no trabajo |

Ahora `perfil_de_secador` devuelve `cerrado_solo` y `secado_corto`, y la pantalla los dice como lo
que son (*"298 · cerrado solo"*, *"1 · olvido"*, con la explicación al pasar el cursor). **El número
no se esconde**: esconderlo sería la otra forma de mentir.

### Y de paso, los rechazos se contaban de dos formas distintas

`trabajadores()` y `perfil_de_secador()` usaban `count(*)` sobre `rechazos`, que tiene **una fila
por (persona × motivo)**: un rechazo con dos motivos le contaba **dos** a la misma persona. El
reporte del dueño ya usaba `count(distinct grupo)` con el comentario que explica por qué —es la
trampa del join que multiplica, migración `036`— pero el arreglo nunca llegó a estas dos. Tampoco
se unían a `carros`, así que un carro **de prueba** le anotaba rechazos a una persona real.

> El hash de `trabajadores()` quedó **idéntico** antes y después: hoy no cambia ningún número
> porque los 3 rechazos históricos tienen un solo motivo cada uno. La mina queda desactivada sin
> mover nada, que es la mejor forma de arreglar algo.

### Jibble ya no puede vaciar la grilla del supervisor

`sincronizar_empleados` marca `fuera` a todo el que no venga en la lista. El Edge Function sólo se
protegía del fallo duro (`!rGente.ok`); un **200 con lista vacía** —por ejemplo si se reorganizan
los grupos, cuyos identificadores están escritos a mano en el código— pasaba de largo y dejaba al
supervisor sin nadie a quien asignar, con el taller lleno de gente. Ahora se rechaza en los dos
lados: el Edge Function devuelve 502 y **la base también se niega**, porque es la última línea.

> ⚠️ **Dos tropiezos en este arreglo, los dos míos.** Primero escribí `sincronizar_empleados` **de
> memoria** y salió completamente equivocada: otras columnas, otra lógica de colores, y sin el
> bloque de caducidad de los manuales. Aplicarla habría roto la sincronización. La saqué de la base
> y le hice los dos cambios quirúrgicos. **Después la prueba encontró un bug en ese arreglo**:
> filtraba los nulos de la lista de vistos pero el `insert` seguía reventando por el not-null de
> `empleados.id`, o sea que un miembro sin id tumbaba la sincronización entera en vez de saltarse a
> esa persona. Ahora se filtra **una sola vez, arriba**, y esa lista limpia alimenta las dos cosas.

### El service worker servía la foto del carro anterior

`sw.js` sólo exceptuaba a Supabase del caché. El cuadro de la cámara de la caja se pide **con una
URL idéntica en cada foto**, así que entraba al caché — y si el relay se caía, el `catch` devolvía
el **JPEG guardado del carro anterior** con `r.ok` en `true`. La caja leía esa placa y se la pegaba
al cliente presente; la cajera veía el congelado con el spinner encima y no tenía forma de saberlo.

Ahora sólo se cachea lo del **mismo origen**. Se compara contra el origen en vez de listar hosts a
propósito: una cámara nueva o un relay nuevo quedan protegidos solos, sin que nadie se acuerde.

### Los cuatro números del reporte

La migración `107` **sólo agrega campos** — ningún valor viejo cambia, así que los reportes ya
congelados siguen siendo válidos y la página cae de pie si no los trae. Verificado día por día: el
único valor distinto en toda la historia es el secado del 19/jul, deriva de una versión vieja de la
función que ya existía y que se dejó fuera del re-congelado a propósito.

| Qué decía | Qué pasa ahora |
|---|---|
| En el día en curso el desglose sumaba **más** que el total (hoy: 32 arriba, 39 abajo) | Las dos tarjetas dicen *"incluye los que todavía no se entregan"* |
| El encabezado de sección no cuadraba con su tabla | Sale una alerta con **cuántos carros no tuvieron secador**. El 11/ago el título decía 22 y la tabla 15: el campo nuevo confirma los **7 exactos**, que eran el peor día de abandono del mes |
| **"Secado promedio general"** mezclaba express con completos | Se parte en dos. Hoy: completos **33.9 min** contra express **15.4**, que el promedio único de 27.4 escondía |
| **Rechazos y devoluciones** se calculaban y nunca se pintaban | Sección propia con el desglose por persona, y sólo aparece cuando no es cero |

### El webhook deja de descartar en silencio, y la firma NO se adivina

Tres caminos respondían 200 sin guardar nada (cuerpo ilegible, JSON inválido, aviso sin
`purchaseUUID`). Responder 200 es **correcto** —reintentar un aviso roto da el mismo aviso roto— y
está bien argumentado en el propio archivo; el problema era que el único rastro es un
`console.error` en logs que duran un día y que nadie mira. Si Zettle cambiara el nombre de un
campo, cada venta caería ahí, Zettle quedaría contento y **la cola amanecería vacía sin una sola
alerta**. Ahora queda en `webhook_bitacora`.

**Sobre la firma, dicho de frente: no la implementé.** `ZETTLE_SIGNING_KEY` está guardada desde el
día uno "para verificar firmas más adelante" y ninguna función la lee. Busqué el esquema y **no hay
documentación pública confiable** de cómo firma Zettle. Adivinarlo en el camino por donde entra el
dinero es la peor opción posible: una firma mal calculada **rechaza ventas reales**. Se guardan las
cabeceras de un aviso bueno para aprender el esquema del tráfico real, y con eso se implementa la
verificación de verdad.

> ⚠️ **La bitácora NUNCA puede tumbar una venta.** Va en `try/catch` y su fallo se traga a
> propósito. Es la lección de la fecha en milisegundos (§7) aplicada al revés: allá una venta se
> perdió por un campo secundario; aquí un campo secundario no puede perder una venta.
>
> ⏳ El registro de los avisos **buenos** es temporal y está marcado como tal en el código. Se quita
> en cuanto la firma esté implementada.

## 11.50 Los 7 puntos de la auditoría, hechos y desplegados (19/ago/2026, migración `105`)

La auditoría de siete frentes encontró 46 hallazgos (ver §11.52). El dueño escogió los **7
priorizados** y pidió subirlos el mismo día, con el taller abierto. Todo se probó contra la base
real antes, y se verificó contra la API en vivo después. **Ninguna ruta se cayó y la lealtad no se
movió** (el hash de las 4,918 personas quedó idéntico antes y después).

### 1. Un error del backend ahora SE VE como error

Las tres pantallas preguntan lo mismo —`if (d.ok === false)`— y **57 respuestas de error salían
sin ese campo**, así que pasaban como buenas: la caja decía *"listo, siguiente cliente"* con la
visita sin registrar, y al supervisor se le cerraba "Entregado" con el carro intacto.

Se arregla en el ayudante `json()`, no ruta por ruta: **si depende de que quien escriba la ruta 58
se acuerde, la clase vuelve.** Antes de tocar se verificó que ninguna respuesta manda `ok:true` con
código de error, así que marcar no puede contradecir a nadie.

`marcarError` se escribió **sin azúcar moderna a propósito**, para que la prueba pueda extraerla del
archivo y correr esa misma función en vez de una copia. Ver `pruebas/README.md`.

### 2. El contador de "encimados" dejaba de contar los carros CANCELADOS

🔴 **El hallazgo más caro de la auditoría, porque ya había producido un juicio por escrito sobre
dos personas con nombre.**

Un carro cancelado conserva `entregado_en` nulo **para siempre** —así lo deja "Borrar unidad" y así
lo deja una devolución—, de modo que sin filtrarlo deja a su secador marcado como ocupado el resto
de la historia. Los carros **515 y 516** (24/jul, cancelados esa noche al descontrolarse la cola)
tenían asignación a **Jorge Luna** y **Jaime Gallegos**.

| 16/ago, completos | Decía | Es |
|---|---|---|
| Jaime Gallegos | 6 de 6 — **100 %** | 6 de 6 — **0 %** |
| Jorge Luna | 7 de 7 — **100 %** | 1 de 7 — **14 %** |

**Se re-congelaron 25 días** (25/jul – 18/ago) conservando `congelado_en`. La saturación total del
periodo bajó de **935 a 734**: las 201 marcas falsas que la auditoría había calculado, exactas.

> ⚠️ **Cómo se comprobó que el cambio era quirúrgico, que es lo que hay que repetir.** Se eligió el
> **16/ago, un día sin ningún carro `6to Express`**, y se comparó equipo por equipo: **ningún
> promedio de secado ni conteo de carros se movió** (lista vacía), y la saturación cambió
> **únicamente** en esas dos personas. Los totales del día —105 lavados, 2004 s de secado, 2638 s
> de espera— quedaron idénticos al segundo.
>
> Los días **19–24/jul se dejaron FUERA** a propósito: su único diff contra el recálculo son campos
> que entonces no existían (`borrados`) y, en el 19/jul, la deriva de una versión vieja de la
> función. Re-congelarlos habría horneado cambios que **no** son de esta corrección.

**Lo que esto invalida:** en §11.65 y §11.75 quedó escrito que lo de esos dos *"ya no es
casualidad: es posición o forma de asignar"* y que *"su secado no se puede comparar contra el de
nadie"*. Las dos conclusiones salen del número falso. Sus tiempos se comparan como los de
cualquiera, y Jaime resulta **rápido y sin saturación**, no saturado.

### 3. La cola del supervisor deja de mentir

Cuatro cosas, todas en `docs/index.html`:

- **Una respuesta que no sea una lista de carros ya no vacía la cola.** Era
  `carros = d.carros || []` seguido de `avisarError(false)`: con 15 carros lavándose, un 500 de la
  base hacía que la pantalla dijera *"No hay carros en proceso"* **y apagara el aviso de falla**.
  Ahora se exige que venga un arreglo; si no, **no se toca la cola** —más vale vieja que falsa— y se
  enciende el aviso.
- **El aviso escala.** Antes sólo salía con la cola vacía, así que un corte de red con carros en
  pantalla no producía **ninguna** señal: los cronómetros seguían corriendo y las tarjetas se
  seguían poniendo rojas con datos de hace media hora. Ahora, a los ~12 s de silencio, el banner
  sale aunque haya carros y dice **de cuándo es lo que se está viendo**.
- **Toda petición corta a los 20 s.** No había un solo `AbortController` en el archivo: una
  petición colgada con el wifi flojo dejaba `ocupado` puesto y **todos los botones de la cola
  dejaban de responder**, sin alerta y sin cambio de color. Para el supervisor la app se trababa y
  la única salida era cerrarla.
- **El candado de pantalla se vuelve a pedir.** `candado` nunca volvía a `null`, así que tras el
  primer minimizado la pantalla se apagaba sola el resto del turno — justo lo que el comentario del
  propio código decía que evitaba.

Y `escapar()` deja de divergir: era el único de los tres HTML sin la guarda de nulos, y por eso
podía pintar el texto `null` en un botón de secador.

### 4. El obrero de relectura por fin corre

La migración `104` quedó a medio desplegar y **nunca había tomado un lote** (`placa_intentos` en
cero en los 2,654 carros). Faltaban tres cosas: desplegar la función, crear `relectura_token` en
Vault y agendar el cron (ahora `jobid 7`, cada 5 min).

**Probado de extremo a extremo sobre un carro real**, apuntando antes sus valores: se le borró la
lectura al carro 2644 y el obrero la recuperó completa —placa `57378`, display `57-378`,
organización `ANAPROMEX`, marca, tipo— y dejó la cola en cero.

### 5. La llave pública deja de poder borrar y de poder leer el CRM

> 🔴 **El primer intento no sirvió de nada, y se descubrió midiendo.** Se revocó `execute` a `anon`
> y las 7 funciones **seguían alcanzables**: Postgres concede EXECUTE a **PUBLIC** por omisión (se ve
> como `=X/postgres` al principio del ACL), así que quitárselo a `anon` no cambia nada — el permiso
> le sigue llegando por el otro lado. Hay que revocarle a **PUBLIC**.
>
> `service_role` no se ve afectado porque tiene concesión **explícita** (`service_role=X/postgres`),
> que sobrevive al revoke. Es la llave que usan las Edge Functions, o sea toda la app.

Quedan alcanzables sólo `crear_carro_desde_venta` y `rls_auto_enable`, que devuelven
`trigger`/`event_trigger` y PostgREST ni expone. **A propósito no se les tocaron los permisos:** la
primera es el camino por donde entra el dinero, y moverlos por un riesgo que no existe es un mal
trato. Las cinco vistas pasaron a `security_invoker`, así que vuelven a chocar con el RLS de las
tablas que consultan.

### 6. Un canje sin saldo se rechaza, y el 6to Express es express

Dos decisiones del dueño, tomadas este día.

- **Canje sin saldo → se rechaza.** La regla vivía en **dos lugares y habían divergido**:
  `registrar_visita` (la vieja) degradaba el canje en silencio y `registrar_visita_con_carro` (la
  que usa la caja) ni preguntaba. Ahora las dos le preguntan a **`saldo_de_gratis()`**, en un solo
  lugar. La caja además **pinta en rojo cualquier ticket que no se pueda usar antes de que la
  cajera lo toque**, con el motivo escrito, en vez de dejarla recibir un error después.
  > ⚠️ **Consecuencia aceptada:** al rechazar, esa visita no queda registrada, así que ese lavado no
  > aparecerá en el historial del cliente. El momento real de atajarlo es antes, en la caja — por
  > eso el rojo preventivo importa más que el rechazo.
- **`Gratis` + `6to Express` es express.** Llevaba 10 casos contándose como completo, ensuciando el
  promedio de los completos con secados de express, y yendo a la línea equivocada.
  > ⚠️ **`carros.tiempo_imposible` es una columna GENERADA** sobre
  > `tiempo_minimo_seg(tipo_de_servicio(...))`, que cuelga de `lleva_aspirado`, que cuelga de
  > `es_lavado_express`. Reemplazar la función **no recalcula lo ya guardado**: hay que forzarlo con
  > `update carros set producto = producto`. Y `es_express` es columna **normal**, escrita por el
  > trigger al crear el carro, así que los 10 históricos también se rellenaron. Sin las dos cosas
  > quedaban tres verdades conviviendo.

### 7. El borrado de fotos, con tope y honesto

Tope de **1,000 por corrida** (el camino nunca se había ejecutado: 21 corridas, 0 archivos, y su
primera vez real en octubre serían ~7,400 de golpe). Y el apuntador se limpia **sólo de lo que de
verdad se borró**: antes se limpiaba por fecha, sin mirar los fallos, mientras el comentario
afirmaba exactamente lo contrario.

### De paso

Se quitó la sobrecarga vieja de `buscar_tickets`, que reventaba con `42725` al llamarla con dos
argumentos (la `098` agregó en vez de reemplazar — la lección de la `052`, otra vez). Y en la caja,
el mensaje de error de la foto dejó de mandar a la cajera al botón de captura manual, que se quitó
el 15/ago.

### Lo que las pruebas atraparon

`pruebas/canje-sin-saldo.sql` (6 grupos, patrón `do $$ … raise` que revierte todo) falló **dos
veces por errores míos de la prueba, no del código**: la segunda vez porque reusé un ticket ya
registrado y el candado de *"ese ticket ya se registró"* lo atajaba antes, así que estaba midiendo
otra cosa. Es justo para lo que sirve una prueba.

## 11.55 La lectura de la foto se reintenta sola (19/ago/2026, migración `104`)

Después de la caída del 17/ago —100 minutos en los que 17 carros subieron foto y la lectura
nunca corrió— el dueño pidió algo más que un aviso: *"me gustaría que se arreglara solo en el
background y el reporte y ligas de placas y tickets se haga cuando haya internet de nuevo"*.

Eso es lo que hace la `104`. Tres decisiones cargan con todo el diseño:

### 1. La cola YA EXISTÍA; no se creó ninguna tabla

Un carro con foto guardada y `placa_en` **nulo** *es* un pendiente de leer. Ésa es exactamente la
semántica que el proyecto ya documenta (§9: *"nulo = nunca se intentó; con fecha y placa vacía =
se intentó y no se pudo"*). Inventar una lista aparte habría sido tener **dos verdades para la
misma pregunta**, que es el error que este proyecto ya cometió varias veces.

La regla de quién es elegible vive en **una sola vista**, `fotos_por_leer`, que consultan el
obrero y el disparador. Al principio el `where` estaba **copiado** en las dos funciones; se
descubrió porque la prueba falló, no leyendo el código.

### 2. El reintento va en el SERVIDOR, no en el teléfono

La cola durable del front (3/ago) reintenta la **subida**, y trae un candado a propósito: *"si el
servidor ya tiene la foto, se descarta sin subir; así jamás se re-lee en Claude una foto ya
guardada"*. Está bien que sea así. Y en la caída del 17 el teléfono **sí tenía internet**: la foto
subió perfecto. Lo que se cayó fue el tramo servidor→Anthropic. Ahí es donde tiene que vivir el
reintento.

### 3. El obrero es una RUTA de la función `app`, no una función nueva

`leerFoto` y el prompt viven en `supabase/functions/app/index.ts`. Una Edge Function aparte
habría obligado a **copiar el prompt** — una segunda regla para la misma pregunta. La ruta
`/releer-pendientes` va **antes** del candado del código del supervisor, con su propio token
(`RELECTURA_TOKEN` + `relectura_token` en Vault), porque no la dispara una persona sino `pg_cron`.
Así el código que abre toda la app no tiene que quedar guardado en un cron.

### Cómo se comporta

```
cron cada 5 min → releer_fotos_si_toca()
                    ├─ cola vacía (lo normal) → un count sobre el índice parcial. NI SIQUIERA
                    │                           sale de la base. No hay llamada HTTP.
                    └─ hay pendientes → POST /app/releer-pendientes
                                          ├─ toma hasta 10 (y marca el intento al entregarlos)
                                          ├─ baja la foto, leerFoto, guardar_datos_de_foto
                                          └─ recongelar_placas_del_dia por cada día tocado
```

- **Gracia de 3 minutos.** Un carro no entra a la cola hasta que su foto tiene 3 min. Sin eso, el
  obrero pagaría una segunda lectura de algo que la ruta `/foto` todavía está leyendo (corta a los
  25 s, más la subida).
- **Espera creciente CON TOPE:** 2, 4, 8, 15, 15… minutos. El tope importa: el punto es que se
  arregle solo *en cuanto vuelva el servicio*, y un backoff sin techo dejaría un carro esperando
  horas después de que ya se podía leer. 20 intentos cubren ~4.5 h de caída.
- **El tope de intentos existe por una sola razón:** una foto corrupta en Storage se reintentaría
  para siempre, cobrando cada vez. Una foto **ilegible** no llega ahí — ésa sí tuvo lectura, el
  modelo dijo "no veo placa", y `placa_en` la saca de la cola. Son casos distintos.
- **Foto nueva, cuenta nueva:** `/foto` reinicia `placa_intentos`. Si no, una re-toma después de
  una caída larga nunca entraría a la cola.
- **Las ligas de placa salen gratis.** `guardar_datos_de_foto` ya liga la placa al cliente y aplica
  el candado de placa repetida del día. Una lectura tardía las hace solas; no hubo que escribir
  nada para eso.

### El reporte congelado se corrige SOLO en el bloque `placas`

`recongelar_placas_del_dia` hace `jsonb_set(datos, '{placas}', …)`, no recalcula el reporte
entero, y **no toca `congelado_en`**. Recalcularlo todo haría que "congelado" dejara de significar
congelado: cualquier otro cambio posterior —una corrección de captura, por ejemplo— se colaría sin
que nadie lo pidiera. Lo que una lectura tardía cambia es cuántas placas se alcanzaron a leer, y
nada más.

### El hueco de la caja, que este trabajo destapó

`registrar_visita_con_carro` llamaba a `guardar_datos_de_foto` con sólo mirar si había foto. Como
esa RPC estampa `placa_en` **siempre**, una lectura que nunca corrió quedaba registrada como *"se
intentó y no se pudo"* — y el carro **nunca habría entrado a esta cola**. Pasó de verdad: el carro
2643 del 17/ago.

Ahora `/leer-placa` devuelve **`leida`** (hubo lectura o no), `caja.html` lo pasa, y la RPC recibe
`p_hubo_lectura`. Sin lectura, la foto se pega al carro igual —el supervisor la ve— pero `placa_en`
se queda nulo, que es la verdad. **Para la cajera no cambia nada**: los dos casos se ven igual en
pantalla, como manda la regla de que la caja nunca regaña (§11.70).

⚠️ Agregar el parámetro **cambió la firma**, así que la migración hace `drop function` de la vieja
antes de crear la nueva: un parámetro nuevo crea una **sobrecarga**, no un reemplazo, y dos
funciones con el mismo nombre vuelven ambigua la llamada (lección de la `052`).

### Se ve, pero no es una alarma

El reporte del dueño muestra **"N fotos sin leer todavía"** sólo cuando no es cero, y aparte
**"N fotos se quedaron sin leer"** cuando alguna agotó los intentos. Va aparte del reporte
congelado (`/fotos-pendientes` + `fotos_pendientes_del_rango`), mismo patrón que la alerta de
placas repetidas de la `095`. La diferencia con una alarma es el sentido: si el obrero está
trabajando el número **baja solo**; si se queda pegado, algo se rompió de verdad.

### Cómo se probó

Bloque `do $$ … raise` con 7 casos sobre la base real, todo revertido: entra el de 40 min y **no**
el de 1 min (la gracia), no entra el que agotó intentos, el intento se cuenta, el backoff lo saca
y lo devuelve, el conteo separa `esperando` de `se_rindieron`, el disparador ve el trabajo, la caja
**sin** lectura deja `placa_en` nulo y el carro entra a la cola, la caja **con** lectura sigue
estampando como siempre, y el recongelado es idempotente. Línea base antes y después: los hashes de
lealtad (4,918 personas) y de los reportes diarios quedaron **idénticos**.

## 11.60 Cierre del 17–18/ago/2026 — dos días limpios, y la lectura de placa se cayó 100 minutos

**146 lavados** en lunes y martes, todos entregados, **0 rechazos, 0 devoluciones, 0 cerrados
automáticamente, 0 placas repetidas, 0 no-express en la línea 1**. Operativamente es el cierre
más limpio del proyecto. El hallazgo del periodo no está en los tiempos: es una **caída de la
lectura de placa** que no avisó a nadie.

**Volumen y tiempos:**

| Día | | Lavados | Espera | Secado | Encimados | Afectados por olvido |
|---|---|---|---|---|---|---|
| 17/ago | Lunes | **84** | 51.2 | 39.8 | 40 (48%) | 6 (7%) |
| 18/ago | Martes | 62 | 45.8 | 33.2 | 20 (32%) | 5 (8%) |

Quitando los olvidos: 17/ago **50.8 / 38.7** y 18/ago **44.7 / 32.1**. La distorsión por captura
es de 0.4–1.1 min — la más chica registrada. **Los tiempos son taller, no captura.**

El lunes 17 sale con una espera alta (51.2 min) para un volumen mediano — al nivel del sábado
15/ago, que tuvo 115 carros. La causa se ve en el reloj: **13 carros entraron entre 17:00 y
17:59**, el pico más cerrado del periodo, contra 2 a 10 por hora el resto del día.

### 🔴 El hallazgo: la lectura de placa se cayó de 16:40 a 18:20 del 17/ago

**17 carros seguidos (2626–2641 y 2645) subieron foto y NUNCA se intentó leerla.** No es que la
foto saliera mala: `placa_en` quedó **nulo**, que es justo la señal de *"nunca se intentó"* — con
placa, marca y submarca en nulo las tres. Antes de las 16:40 y después de las 18:22 todo leyó
normal.

```
16:24  carro 2625  leyó (y el candado de placa repetida lo atajó, ver abajo)
16:40  carro 2626  foto subida, sin intento   ← empieza
...    17 carros
18:20  carro 2645  foto subida, sin intento   ← termina
18:22  carro 2644  leyó MAZDA 6
18:23  carro 2642  leyó JETTA
```

- **Era la razón completa del mal día de datos del 17:** placa 58/84 (**69%**, el peor del
  proyecto), marca 77%, submarca 64%. Sacando los 17 de la caída, los 67 restantes daban **87% de
  placa, 97% de marca y 81% de submarca** — o sea, un día normal. El 18/ago, sin caída, quedó en
  85% / 100% / 90%. ✅ **Ya se recuperó** (ver abajo): el 17/ago quedó en **88% de placa, 98% de
  marca y 85% de submarca**.
- **No es un patrón, es un evento.** Se midió `foto sin intento de lectura` día por día en todo
  agosto: **0 todos los días menos el 17, que tiene 17.** No hay que arreglar un bug; hay que
  enterarse cuando pase.
- **También se llevó a la caja.** El carro 2643 (prueba de la cámara, 18:06) subió una foto
  perfectamente legible de un Nissan Note y tampoco sacó nada; el 2649, ya recuperado el
  servicio a las 18:57, leyó `9VYE404` sin problema.
- 🔴 **Nadie se enteró, y ése es el problema real.** El diseño dice que la placa "nunca bloquea":
  si Anthropic se cae o tarda, la foto se guarda y el carro sigue. Correcto para el supervisor —
  pero **hacia afuera la caída es muda**: no hay aviso y no hay reintento. Lo que salva el dato
  es que la foto sí quedó guardada; **falta la alarma**, que es lo único pendiente de esto.
- **Causa raíz: no se sabe.** Los logs de Edge Functions ya no cubren el 17/ago. Las hipótesis
  son caída/límite de la API de Anthropic o un error de la función; nada en la base lo distingue.
  Lo accionable no es la causa, es la **falta de alarma**.

### ✅ Las lecturas perdidas se recuperaron (19/ago/2026)

Se volvió a leer la foto de **24 carros** (los 17 de la caída, más 7 sueltos de otros días que
arrastraban lo mismo desde el 29/jul) y se guardó con `guardar_datos_de_foto`, la misma RPC del
supervisor. **21 de 24 sacaron placa**; los 3 que no, tampoco la tenían en la imagen.

| Día | Placa antes | Placa ahora |
|---|---|---|
| 29/jul | 76/88 | **79** |
| 3/ago | 76/95 | **77** |
| 4/ago | 47/50 | **48** |
| **17/ago** | **58/84 (69%)** | **74/84 (88%)** |

Hoy **`foto sin intento de lectura` es 0 en toda la base**.

**Cómo se hizo, que es lo que importa si vuelve a pasar:**

- **El prompt NO se copió: se extrae del propio `supabase/functions/app/index.ts`** en tiempo de
  corrida (`awk` sobre el template literal `INSTRUCCION_FOTO`), junto con el mismo modelo
  (`claude-sonnet-5`), el mismo `json_schema`, el mismo `effort: low` y el mismo corte de 25 s.
  Una copia del prompt sería una segunda regla para la misma pregunta — el error que este
  proyecto ya cometió varias veces.
- **Las reglas de aceptación las aplica Postgres sobre la respuesta cruda**, no un parser nuevo:
  la placa solo si `placa_legible`, la organización solo si hubo placa, el tipo solo si es uno de
  los cuatro válidos. Idéntico a lo que hace el `.ts`.
- **Se validó contra dos carros de control** cuya lectura ya existía (2644 → `57-378` /
  ANAPROMEX / Mazda6; 2649 → `9VYE404` / Honda / CR-V). Las dos salieron iguales antes de tocar
  nada.
- **0 placas repetidas nuevas.** Se corrió `placas_repetidas_del_rango` sobre los cuatro días
  después de escribir; los dos grupos que salen del 29/jul ya existían y no involucran a ningún
  carro recuperado.
- **Se re-congelaron los cuatro reportes**, con `congelado_en` intacto (la hora del corte es un
  hecho; lo que cambió es el dato de placa). Antes se sacó el diff campo por campo: **lo único
  distinto es el bloque `placas`** — lavados, tiempos y equipos quedaron idénticos.

> 🇺🇸 **Y salió la segunda placa gringa verificada:** el carro 2629 traía placa de **Arizona**
> (`ROA 11T`, Toyota Highlander blanco) y se leyó completa, ignorando "ARIZONA" y "GRAND CANYON
> STATE" como manda el prompt. Con la de California del 2649, el camino de las placas de EU ya
> está probado en los dos estados que más entran a Mexicali.

### ✅ Higiene operativa

- **0 rechazos, 0 devoluciones, 0 cancelados que no sean borrado de supervisor, 0 cerrados
  automáticamente** los dos días. El olvido de fin de turno del 16/ago (4 carros sueltos entre
  19:15 y 19:45) **no se repitió**: el supervisor cerró la cola solo las dos noches.
- **Línea 1 impecable:** 41 express, **41 en la línea 1**, 0 no-express adentro.
- **0 placas repetidas** (`placas_repetidas_del_rango`), tercer periodo seguido en cero.
- **El candado de placa duplicada trabajó una vez:** el carro 2625 (16:23, `CA BLANCA`) quedó en
  `placa_dudosa = PCA-6715-C`, que era la del carro 2624 (una Grand Caravan de 20 minutos antes).
  Foto pegada al carro equivocado, atajada antes de escribirse.
- **6 borrados de supervisor** (2 el lunes, 4 el martes), todos nunca asignados. Es lo que el
  botón existe para hacer.
- **Nota de caja 100% el lunes** (84/84) y 98% el martes.

### 🟠 Lo que sigue igual

- **La caja nueva sigue sin usarse.** Las **únicas** dos visitas por `caja='principal'` de estos
  dos días son las de la prueba de la cámara Reolink, y quedaron descartadas. Se vendieron **22
  lavados gratis** (15 el lunes, 7 el martes) y **ninguno** se registró como canje en el CRM. Es
  el tercer periodo seguido con el mismo resultado.
- **`6to Express` va por la séptima vez.** Dos casos nuevos: carro **2607** (17/ago) y **2694**
  (18/ago), los dos `Gratis` + `6to Express`, clasificados como **completo con aspirado** y
  mandados a la **línea 2**. Con el 2590 del mismo 17/ago ya son 7 en total. Sigue esperando la
  palabra del dueño antes de tocar `es_lavado_express`.

### Analítica por persona — los dos días juntos

Completos (con aspirado), una persona:

| Persona | Carros | Secado | Encimados |
|---|---|---|---|
| Jesús Gil | 21 | 38.6 | 7 (33%) |
| Luis Luna | 16 | **53.9** | 5 (31%) |
| Pablo Cruz | 14 | 44.3 | 6 (43%) |
| Edgar Reyes | 12 | 41.0 | 6 (50%) |
| José Cruz | 11 | 50.8 | 5 (45%) |
| Jaime Gallegos | 9 | 48.6 | 9 (**100%**) |
| Mario Hernández | 7 | **37.8** | 1 (**14%**) |
| Jorge Luna | 6 | **34.6** | 6 (**100%**) |

Express: **Walter Rodríguez 10 a 19.6 min**, **Saul Ramirez 8 a 22.8**, **Pablo Cruz 7 a 14.8**.

**Cómo leerla:**
- 🔴 **Luis Luna, cuarto periodo seguido de lo mismo:** el secado más alto (53.9 min) con apenas
  31% de encimados. Ya no es ruido — es el caso más consistente del proyecto y el que más vale
  preguntar en el taller.
- **Mario Hernández es el mejor dato limpio del periodo:** 37.8 min con **14%** de encimados, el
  porcentaje más bajo de cualquiera con volumen.
- 🔴 ~~**Jaime Gallegos y Jorge Luna siguen al 100% de encimados**, ya 15 días seguidos. Jorge
  además sale con 34.6 min estando siempre saturado, el mejor tiempo del periodo. Su número no se
  puede comparar contra el de nadie.~~ **FALSO — el número estaba envenenado (ver §11.50).** Dos
  carros cancelados del 24/jul los dejaban marcados como ocupados para siempre. Ninguno de los dos
  estaba saturado, y sus tiempos se comparan como los de cualquiera.
- **Luis Chávez casi no aparece** (1 completo en dos días), así que la señal del fin de semana
  pasado —46.6 min sin saturación— sigue sin poderse confirmar ni descartar.

### La prueba de la cámara Reolink, y lo que dejó (19/ago/2026)

El 17/ago se probó la cámara fija de caja registrando dos visitas **a nombre del cliente
`Guillermo Lara Torres`** (persona 35333). Eso le pegó a él dos tickets de clientes reales, le
sumó dos sellos y le ligó la placa `9VYE404` como confirmada. Se deshizo el 19/ago.

- **Se conservaron las fotos y la placa del carro**, porque se verificaron **contra la imagen**:
  el carro 2643 es un Nissan Note plateado y su nota decía `AU PLATEADO`; el 2649 es un Honda
  CR-V rojo con placa de California `9VYE404` y su nota decía `CA ROJA`. **La cámara sacó el
  carro correcto las dos veces.** Lo único equivocado era el cliente.
- **Se quitó:** el renglón de `persona_placas` (9VYE404 → Guillermo) y las dos visitas, que
  pasaron a `estado='descartada'` + `es_prueba=true` (la fila se conserva, no se borra). Los dos
  carros volvieron a `cliente = null`, que es lo que da su nota. Guillermo quedó en 0 lavados
  pagados, 0 sellos, 1 visita (su cortesía real del 15/ago).
- ⚠️ **La placa `9VYE404` es de un cliente recurrente de verdad**, no de Guillermo: aparece en
  los carros 282 (21/jul), 1323 (1/ago) y 2649 (17/ago). Si se hubiera quedado ligada, el CRM le
  habría dado a Guillermo el historial de otra persona.
- ✅ **De paso, esto cierra el pendiente de §9:** *"el camino de las placas de Estados Unidos
  está escrito pero no probado contra una placa gringa real"*. Ya está probado — `9VYE404`,
  placa de California, leída correcta y completa.

## 11.65 Cierre del 15–16/ago/2026 — fin de semana grande y limpio; la caja nueva no se ha usado

**220 lavados en dos días**, los dos entregados completos y sin devoluciones. Operativamente es
uno de los cierres más limpios del proyecto. Lo que hay que leer no son los tiempos: es que **la
app de la caja que se desplegó el 15/ago no se está usando**, y que el olvido de fin de turno
sigue vivo.

**Volumen y tiempos:**

| Día | | Lavados | Espera | Secado | Encimados | Afectados por olvido |
|---|---|---|---|---|---|---|
| 15/ago | Sábado | **115** | 51.1 | 38.9 | 72 (63%) | 14 (12%) |
| 16/ago | Domingo | 105 | 44.0 | 33.4 | 54 (51%) | 11 (10%) |

Quitando los olvidos, el 15 queda en **49.8 / 36.4** y el 16 en **42.5 / 31.1** — o sea que la
distorsión por captura es de 1.3–2.5 min, chica. Los tiempos son taller, no captura.

**Los encimados vuelven a ser la mitad del día** (63% el sábado). Un secado individual alto en
estos dos días es cola, no lentitud.

### ✅ Higiene operativa

- **0 rechazos, 0 devoluciones, 0 tiempos imposibles el 16, 0 placas repetidas** en los dos días.
- **La prevención de placa duplicada (migración `100`) está trabajando:** bloqueó **5 escrituras**
  (3 el 15, 2 el 16) que quedaron en `placa_dudosa` en vez de pegarse al carro equivocado. Ésa es
  la razón por la que `placas_repetidas_del_rango` devolvió **cero**: no es que no haya pasado, es
  que se atajó. Los 5 son candidatos a foto mal pegada y se pueden revisar por ese campo.
- **Línea 1 impecable:** 74 express, 73 en la línea 1, **0 no-express adentro** (el que falta es
  uno que nunca se asignó y se cerró solo).
- Solo **2 borrados de supervisor** (los dos el 15, nunca asignados) y **0 cancelados** el 16.

### Calidad de datos

| Día | Nota de caja | Foto | Placa leída | Marca | Submarca |
|---|---|---|---|---|---|
| 15/ago | 117/119 (98%) | 117/119 (98%) | 108 (**91%**) | 112 (94%) | 107 (90%) |
| 16/ago | 101/105 (96%) | 103/105 (98%) | 87 (**83%**) | 99 (94%) | 96 (91%) |

🟠 **El 83% de placa del 16 es el peor del mes** (el rango 4–14/ago fue 88–93%). Son **16 carros
con foto y sin placa**, repartidos por todo el día, no en un bache. De ésos, 2 salieron por el
candado de placa dudosa; los otros 14 son lectura fallida de verdad. La mitad sí sacó marca y
submarca de la misma foto, así que la foto era buena y lo que no se dejó leer fue la placa —
consistente con lo que dijo el dueño de las pickups grandes.

### 🔴 El hallazgo del cierre: la caja nueva no se está usando

La app de la caja se desplegó el **15/ago** (§11.70) y desde entonces:

- **1 sola visita** entró por `caja = 'principal'` (el 15/ago). **0 el 16, 0 el 17.**
- **0 fotos vienen de la caja.** Se midió por el retraso entre el pago y la foto: en los 220
  carros del fin de semana, la foto llega **6 a 25 min después** del cobro (promedio 12.6),
  o sea que la toma el supervisor al asignar. Una foto de caja llegaría en segundos. En 7 días
  (10–16/ago) hay exactamente **2 fotos** con menos de 2 min.
- Se vendieron **22 lavados `6to Lavado`** en esos dos días y **ninguno** quedó registrado como
  canje en el CRM.

👉 **Consecuencia directa:** la lealtad (**248 gratis por honrar en 248 personas**) sigue
dependiendo por completo del ClientNoteTracker y de que alguien corra el import. La simplificación
del flujo no movió la aguja porque nadie la está tocando. **Es pregunta para el dueño, no consulta:
si las cajeras no la abren, ¿es entrenamiento, es el teléfono, o es que el flujo de CNT sigue
siendo el oficial?**

### 🟠 El olvido de fin de turno, otra vez

Los **4 cerrados automáticamente del 16/ago** son los carros 2563, 2565, 2566 y 2567, entrados
entre **19:15 y 19:45**. Dos de ellos ni siquiera se asignaron. Es el mismo patrón del 11/ago:
la app se suelta en la última media hora. El 15/ago no tuvo ninguno.

### 🟡 `6to Express` va por la quinta vez, y hoy volvió a pasar

El hallazgo #1 de §11.75 no está arreglado y sigue apareciendo: el carro **2590 de hoy
(17/ago, 11:56)** es un `Gratis` + `6to Express`, se clasificó como **completo con aspirado** y
se mandó a la **línea 2**. Ya van 5 casos (1547, 2208, 2211, 2290, 2590). Sigue **pendiente de
confirmar con el dueño** si un 6to gratis de express es express antes de tocar
`es_lavado_express`.

### Analítica por persona — los dos días juntos

Completos (con aspirado), una persona:

| Persona | Carros | Secado | Encimados |
|---|---|---|---|
| Jesús Gil | 21 | 42.9 | 11 (52%) |
| Walter Rodríguez | 21 | 45.3 | 14 (67%) |
| Mario Hernández | 18 | 47.7 | 10 (56%) |
| Pablo Cruz | 18 | 42.7 | 14 (78%) |
| Luis Luna | 14 | **60.9** | 7 (50%) |
| Jaime Gallegos | 11 | **33.3** | 11 (**100%**) |
| Luis Chávez | 7 | 46.6 | **0 (0%)** |
| Jorge Luna | 7 | 53.2 | 7 (100%) |
| Edgar Reyes | 7 | **36.0** | 2 (29%) |

Express: **Saul Ramirez 24 carros a 13.6 min** — este fin de semana la línea 1 fue suya, no de
Walter (que se movió a completos).

**Cómo leerla:**
- 🔴 ~~**Jaime Gallegos y Jorge Luna siguen al 100% de encimados**, igual que en los 11 días
  previos. Ya es estructural: es posición o forma de asignar. Jaime además bajó a 33.3 min *estando
  siempre saturado*, que es el mejor dato del fin de semana.~~ **FALSO — ver §11.50.** El contador
  no descartaba dos carros cancelados del 24/jul asignados a ellos. Medido el 16/ago con el filtro
  corregido: Jaime **0%** de encimados, Jorge **14%**. Jaime no bajó a 33.3 min "estando saturado";
  bajó a secas, que es mejor noticia y otra conversación.
- 🔴 **Luis Chávez es la señal nueva y hay que verla:** 7 completos a **46.6 min con 0% de
  encimados**. En los 11 días anteriores era el **más rápido** del taller (32.8 min). Sin
  saturación que lo explique, subió 14 min. Vale preguntar qué cambió.
- **Luis Luna repite el patrón de lento sin saturación** (60.9 min con 50%), tercer periodo
  seguido. Es el caso más consistente del proyecto.
- **Edgar Reyes vuelve a ser el mejor dato limpio** (36.0 con 29% de encimados).

**Horas:** el sábado sí tuvo pico (12–14 h, 16–17 carros/hora); el domingo fue plano (6–13/hora,
sin pico claro). El día de la semana sigue mandando sobre la hora.

## 11.70 La app de la caja, simplificada (15/ago/2026)

El dueño pidió *"hacer el flujo mucho más simple"*. La caja pasó de **4 pasos con dos
pantallas** a **3 pasos en una sola**. Migraciones `101`–`102`, `docs/caja.html`, `sw.js` v8.

**El flujo nuevo, completo:**

```
1. Escribir el nombre en la barra de arriba  →  tocar al cliente
2. Cobrar en Zettle  →  su ticket aparece solo  →  tocarlo
3. Registrar visita
```

- **La barra buscadora va hasta arriba de la primera pantalla**, y los resultados **caen debajo
  de ella** sin cambiar de pantalla (2+ letras, con la misma espera de 300 ms del buscador viejo
  para no consultar por cada tecla). Hasta abajo de esa lista está siempre **"+ Registrar cliente
  nuevo"**, con lo ya tecleado: si no aparece, se da de alta sin ir a buscar otro botón.
- **La cámara se queda debajo**, para reconocer al cliente por su placa. Es opcional.
- **Se quitó "Capturar placa manualmente".** El respaldo no desapareció, se movió a quien tiene
  el carro enfrente — ver abajo.
- **Los últimos 5 tickets de Zettle salen solos**, refrescándose cada 2 s, con **número, monto,
  contenido y hora exacta**. Se excluyen los ya asignados a otro cliente.
- **"Registrar visita" nace apagado** y se prende al elegir un ticket.
- **Desapareció la pantalla "¿A qué lavado corresponde?".** Registrar y enlazar son ahora **una
  sola operación atómica** (`registrar_visita_con_carro`). Eso mata la **fuga de lealtad** que
  estaba documentada: ya no existe el momento en que una visita cuenta sin lavado al cual
  pertenecer, así que tampoco hacen falta "No hubo venta / cancelar" ni "Listo".

### Las tres reglas que hay que respetar si esto se toca

1. **🔑 EL TICKET MANDA sobre el switch de la cajera.** Si el ticket es un `6to`, la visita se
   registra como canje **aunque se le haya olvidado prender "Utilizar Lavado GRATIS"**. Si no
   fuera así, un lavado regalado le sumaría un sello y el cliente cobraría el mismo premio dos
   veces. El switch sólo sirve para avisar **antes**: si está prendido y el ticket no es un 6to,
   el ticket se pinta **rojo** con la leyenda *"Selecciona un ticket con lavado gratis"* y el
   botón no deja registrar. La misma condición prende el rojo y el candado — una sola regla.

2. **Una CORTESÍA no es un canje.** `Gratis` + variante `Cortesia`/`Mango`/`Remake`/`Tony`/
   `SushiRoll`/`Uribe`/`Admin` es un regalo del negocio: **ni suma sello ni consume gratis**,
   pero **sí queda en el historial** (el cliente sí vino). Es el tercer estado que faltaba:
   columna `visitas.es_cortesia`, y `lealtad_por_persona` las excluye de `lavados_pagados` y de
   `canjes` —pero no de `visitas_totales`—.
   - **Quien decide es `clase_de_gratis(producto, variante)`, una sola función**, por **prefijo
     `6to%`** y no por lista blanca de cortesías. Los nombres de cortesía los inventa el dueño en
     Zettle (ya van 7 distintos) y una lista se queda vieja **en silencio**; con el prefijo, lo
     que no es 6to cae solo del lado de cortesía, que es el error barato.
   - ⚠️ En PL/pgSQL va con `is not distinct from`, no con `=`: para un lavado normal la función
     devuelve NULL y `null = 'canje'` es NULL, no false. Con `=` la columna salía nula y reventaba
     el not-null (lo cachó la prueba, no la lectura).

3. **La lista de tickets NO se reconstruye si no cambió.** Se compara una firma antes de armar
   los botones. Sin eso, el refresco de cada 2 s movería los botones justo cuando la cajera va a
   tocar uno — es la misma lección del reloj de la cola del supervisor (20/jul/2026).

### La placa que no se puede leer: la caja no regaña, el supervisor reintenta (migración `103`)

Textual del dueño (15/ago/2026): *"los carros de Mexicali tienden a llegar muchas pickup muy
grandes como las Tundra, lo cual hace que no se aprecie bien la placa… no le avises a la cajera
que hay que retomar foto, ya que es imposible decirle al cliente que se haga para adelante: ya
no estaría a la altura de la ventana de la caja para poder cobrar. Al momento de asignar a fila
y secador, ahí se le pedirá de nuevo la foto al supervisor"*.

- **La caja nunca se traba ni avisa.** Si la lectura no saca placa, el mensaje es neutro
  (*"Foto tomada. Busca al cliente por su nombre arriba"*) y el registro sigue normal. La foto
  **sí se guarda** y se le pega al carro, así que el supervisor la ve en la cola.
- **🔑 El requisito de foto al asignar se cumple con la PLACA, no con la foto.** Éste era un
  hueco **que ya existía en producción**: `fotoLista` miraba `!!c.foto`, así que en cuanto había
  una foto —aunque no se hubiera leído nada— el requisito se daba por cumplido y **nadie volvía a
  intentar**. Medido del 4 al 14/ago: **65 carros con foto y sin placa, ~6 por día (9%)**. Ahora,
  si hay foto pero no hay placa, el bloque dice **"— no se leyó la placa"** y el botón
  **"Tomar foto otra vez"**; el carro está en el patio, donde sí se deja fotografiar.
- **No se puede quedar atorado:** al tomar la foto nueva el requisito se cumple **aunque esa
  tampoco llegue a leer la placa**. La lectura ocurre después y en segundo plano; detenerlo ahí
  lo dejaría trabado con un carro que de plano no se deja fotografiar.
- **`placa_en` distingue los dos casos** y por eso importa: nulo = *nunca se intentó*; con fecha
  y `placa` vacía = *se intentó y no se pudo*. La caja lo estampa sólo cuando de verdad hubo foto.
- **La lectura de la caja se guarda con `guardar_datos_de_foto`, la misma del supervisor**, no
  con una copia: ahí viven el candado de la **placa repetida del día** (migración `100`) y el
  ligado placa→cliente. Verificado en la prueba: un segundo carro del mismo día con la misma
  placa sale `placa_dudosa` y **no** se escribe.

**Cómo se probó:** la base con un bloque `do $$ … raise` de 5 casos (lavado normal, cortesía
neutra, switch de gratis con ticket que no es 6to, ticket 6to con el switch apagado, y el mismo
ticket con otro cliente) más el camino "ticket sin lavado"; y la vista de lealtad contra una
**línea base de las 4,871 personas** — 0 cambiaron, que era la condición para no romper saldos.
El front, en el navegador con datos falsos: el autocompletado con una sola consulta por palabra,
el orden de la pantalla, el rojo y el candado en los 5 casos, y que la lista no se reconstruye
sola pero sí cuando entra un ticket nuevo (conservando lo ya seleccionado).

---

## 11.75 Cierre del 4–14/ago/2026 — 11 días: el dato ya es bueno, el problema es el olvido

**750 lavados en 11 días.** La calidad de datos llegó a su mejor nivel del proyecto y el bug de
la foto mal pegada desapareció. Lo que quedó al descubierto —porque ya no lo tapa el ruido— es
que **la app se abandona por rachas**, y esas rachas son las que ensucian el día.

**Volumen y tiempos (todos los días congelados correctamente):**

| Día | | Lavados | Espera | Secado | Encimados | Afectados por olvido |
|---|---|---|---|---|---|---|
| 4/ago | Martes | 50 | 43.0 | 30.1 | 12 (24%) | 4 (8%) |
| 5/ago | Miércoles | 44 | 35.5 | 26.0 | 8 (18%) | 1 (2%) |
| **6/ago** | **Jueves** | **85** | **55.7** | **42.8** | 40 (47%) | **26 (29%)** |
| 7/ago | Viernes | 89 | 39.6 | 28.3 | 31 (35%) | 2 (2%) |
| 8/ago | Sábado | **117** | 44.5 | 33.0 | 58 (50%) | 4 (3%) |
| 9/ago | Domingo | 78 | 43.8 | 32.3 | 39 (50%) | 6 (8%) |
| **10/ago** | **Lunes** | 60 | 46.1 | 33.6 | 31 (52%) | **14 (21%)** |
| **11/ago** | **Martes** | **31** | 36.6 | 24.4 | 6 (19%) | **18 (46%)** |
| 12/ago | Miércoles | 36 | 50.6 | 34.3 | 11 (31%) | 4 (11%) |
| 13/ago | Jueves | 56 | 42.3 | 29.8 | 17 (30%) | 3 (5%) |
| 14/ago | Viernes | 104 | 46.2 | 35.3 | 54 (52%) | 5 (5%) |

"Afectados por olvido" = secado < 3 min, o secado > 75 min, o nunca asignado y borrado, o
cerrado automáticamente. **No es volumen:** el sábado 8 con 117 carros tuvo 3% de afectados; el
martes 11 con 31 carros tuvo 46%.

### 🔴 Lo importante: tres días donde la app se abandonó

- **11/ago (el peor): 16 de 39 carros nunca se asignaron (41%).** Dos ventanas muertas:
  11:03–12:08 (7 carros, borrados en ráfaga a las 12:42) y **17:14 hasta el cierre (9 carros,
  todos cerrados automáticamente a las 20:30)**. La última entrega real del día fue a las 17:15
  — de ahí en adelante nadie tocó el teléfono. La foto cayó a 74% ese día por la misma razón.
- **6/ago: 26 de 90 afectados.** El patrón se ve en el reloj: siete carros (1687, 1692–1697)
  entregados **todos entre 16:03:50 y 16:04:31**, con "secado" de 88 a 140 min; y cuatro más
  (1703, 1708, 1710, 1711) asignados **y** entregados en el mismo momento, con secado de 0.1 a
  2.1 min. Es un carro olvidado y una puesta al día a manotazos. Más 4 carros de 15:08–15:35
  que nunca se asignaron y se borraron.
- **10/ago: 14 de 66** (8 secados de segundos + 4 nunca asignados).

**Cuánto distorsiona:** el 6/ago el reporte dice espera 55.7 y secado 42.8 min; quitando los
olvidos son **49.4 y 33.3**. O sea que el día "más lento del periodo" es en su mayoría captura,
no taller. Los demás días la diferencia es menor a 1.5 min.

👉 **La pregunta que hay que hacerle al dueño, porque el dato no la contesta: quién estaba de
supervisor el 6, el 10 y el 11 de agosto.** La app no guarda quién la opera. Si es la misma
persona, es entrenamiento; si son distintas, es proceso.

### ✅ Lo que mejoró y hay que reconocer

- **0 placas repetidas en 11 días** (verificado con `placas_repetidas_del_rango` y a mano con
  `normalizar_placa`). Los 3 días anteriores tuvieron 4. El bug de la foto pegada al carro
  equivocado no apareció ni una vez.
- **Nota de caja 99%** (748 de 750) y **foto 96–100%** todos los días menos el 11 (74%, por el
  abandono). El outbox del 3/ago sostuvo la cobertura.
- **Placa leída 88–93%**, marca 95%, submarca 92%.
- **Línea 1 impecable:** 254 express, todos en la línea 1, 0 no-express adentro.
- **0 devoluciones después de entregar** en todo el periodo.

### 🟠 Hallazgos nuevos

1. **`Gratis` + variante `6to Express` se cuenta como COMPLETO.** Es la trampa de la variante,
   otra vez: `es_lavado_express` sólo mira `express%`, `manual%`+express y `pasajeros%`+express,
   así que un 6to lavado gratis de un **express** cae en `lleva_aspirado = true`. 3 casos
   (carros 2208, 2211 el 13/ago; 2290 el 14/ago), y los dos del 13 se mandaron a la **línea 3**
   en vez de la 1. Ensucia el promedio de completos con secados de express. Arreglo de una
   línea en `es_lavado_express`; **falta confirmarlo con el dueño** (¿un 6to gratis de express
   es express?) antes de tocar la regla.
2. **El catálogo cambió y el `CLAUDE.md` estaba viejo.** `Completo Cera` desapareció el
   28/jul y lo reemplazó **`Completo RUSH`** (633 carros, el producto principal hoy), con
   variantes `Chico`/`Grande` en vez de `Completo`/`Completo Grande`. Se verificó que
   `lleva_aspirado` lo clasifica bien —cae en el patrón `'completo%'`—, no por accidente.
3. **El rechazo de entrega está muerto: 0 usos desde el 21/jul** (25 días, ~1,900 carros). La
   tabla `rechazos` tiene 3 filas históricas en total. O la calidad es perfecta, o los
   supervisores no usan la pantalla. Lo segundo es más probable y hay que preguntarlo.
4. **La app de la cajera tampoco se usa.** De 14,040 visitas, sólo **15** entraron por
   `caja = 'principal'` (10 el 26/jul, 4 el 27, 1 el 5/ago). El resto es `import`. La lealtad
   depende **por completo** del ClientNoteTracker y de que alguien corra la importación.
5. **`A GRIS` (carro 2183, 13/ago)** — segunda vez del código `A` por `AU`. Ya son dos casos en
   3½ semanas. Sigue sin decidirse si se acepta `A` = automóvil.
6. **Días chicos sin explicar (preguntar, no consultar):** el 11/ago sólo hubo 39 ventas y el
   12/ago 38, **con la última venta a las 15:32** — el negocio cerró temprano, no fue la app
   (las ventas de Zettle también se detienen ahí).

### Analítica por persona — 11 días, ya con base suficiente

Completos (con aspirado), una persona, 5+ carros:

| Persona | Carros | Secado | Encimados |
|---|---|---|---|
| Mario Hernández | 67 | 43.8 | 25 (37%) |
| Jesús Gil | 62 | 36.5 | 21 (34%) |
| Pablo Cruz | 62 | 37.9 | 21 (34%) |
| Jorge Luna | 53 | 44.6 | **53 (100%)** |
| Edgar Reyes | 40 | **39.0** | 9 (23%) |
| Saul Ramirez | 39 | 45.4 | 15 (38%) |
| José Cruz | 36 | 46.6 | 11 (31%) |
| Jaime Gallegos | 36 | 38.8 | **36 (100%)** |
| Luis Luna | 33 | 51.3 | 10 (30%) |
| Luis Chávez | 18 | 32.8 | 4 (22%) |

Express: **Walter Rodríguez 101 carros a 15.3 min** — la línea 1 es suya.

**Cómo leerla:**
- 🔴 ~~**Jorge Luna y Jaime Gallegos traen 100% de encimados**, 11 días seguidos. Eso ya no es
  casualidad: *cada* carro que les entra los agarra ocupados. Es posición o forma de asignar,
  no lentitud — su secado (44.6 y 38.8) no se puede comparar contra el de nadie.~~
  **FALSO — ver §11.50.** "Cada carro los agarra ocupados" era literalmente cierto en el número y
  literalmente falso en el taller: los dejaba ocupados un carro cancelado del 24/jul que nunca se
  entregó. **Sus 44.6 y 38.8 min sí se comparan** contra los de los demás.
- **La señal limpia de "sí es más lento" son Luis Luna (51.3 min con 30% encimados) y José
  Cruz (46.6 con 31%)**: tiempos altos **sin** saturación que los explique. Ahí sí vale
  preguntar qué pasa.
- **Edgar Reyes es el mejor dato limpio del periodo**: 40 carros a 39.0 min con sólo 23% de
  encimados. Y **Luis Chávez el más rápido** (32.8), aunque con menos volumen.

**Horas pico (para acomodar personal):** el día es más plano de lo que parece — 6 a 7.5 carros
por hora de 9 AM a 6 PM, con el pico en 12–13 h (7.5). Lo que mueve la carga es el **día de la
semana**, no la hora: viernes y sábado 104–117, martes y miércoles 31–50.

---

## 11.80 Cierre del 1–3/ago/2026 — fin de semana de alto volumen, y la foto arreglada

Tres días seguidos limpios en lo operativo: **0 rechazos, 0 cancelados, 0 borrados, 0
devoluciones**, y solo 1 tiempo imposible descartado (el lunes). Lo que hay que leer es la
**carga** y la **calidad de datos**, no la maquinaria.

**Volumen (patrón de fin de semana):**

| Día | | Lavados | Con aspirado | Express/sin | Encerado |
|---|---|---|---|---|---|
| 1/ago | Sábado | **127** | 86 | 40 | 1 |
| 2/ago | Domingo | 81 | 60 | 20 | 1 |
| 3/ago | Lunes | ~95 | 60 | 35 | 0 |

El **sábado 1 es el día más grande registrado** (127, contra el récord previo de ~90).

**Tiempos, y la lectura correcta (saturación, no lentitud):**

| Día | Espera (pago→entrega) | Secado (mezcla) | Encimados | % de completos |
|---|---|---|---|---|
| 1/ago | 52.4 min | 39.6 min | 65 | **76%** |
| 2/ago | 46.6 min | 34.6 min | 38 | 63% |
| 3/ago | 46.3 min | 34.9 min | 44 | 73% |

Tres de cada cuatro completos arrancan con el secador **ya ocupado**. Los secados individuales
altos son cola, no lentitud (el contexto que la migración `065` existe para dar). Ejemplo del
sábado: Saul Ramirez sale con 67 min (el más alto), pero con 7 de 10 encimados. El dato limpio
es **Edgar Reyes**: 8 completos a 35 min con solo 2 encimados. **Jorge Luna trae 100% de
encimados los dos días** (8/8 el sábado, 10/10 el lunes): revisar su posición o cómo se le
asigna. Express: **Walter Rodríguez** sostiene la línea 1 (16 a 14.6 min el sábado, 19 a 13.5 el
lunes).

**Calidad de datos — la nota aguanta, la FOTO se cayó el lunes:**

| Día | Nota de caja | Foto | Placa leída |
|---|---|---|---|
| 1/ago | 125/127 (98%) | 123/127 (**97%**) | 117 (92%) |
| 2/ago | 79/81 (98%) | 78/81 (96%) | 72 (89%) |
| 3/ago | 92/96 (96%) | 85/96 (**88%**) | 76 (79%) |

El lunes la foto cayó a 88% (11 sin foto), el peor de los tres. Dos de esos 11 son los carros
1539 y 1540, cuya subida se cayó por wifi. **Ese hueco se cerró el mismo 3/ago** con la cola
durable de subida (outbox en IndexedDB), commit `3995f0d` — ver la memoria
`foto-al-asignar-gate-solo-del-front`. Advertencia honesta: los 11 sin foto están repartidos por
todo el día, no solo en un bache de wifi; el outbox rescata a los que **sí se tomaron y no
subieron**, no a los que nunca se tomaron (el 1548 de las 19:48 entró sin nota, sin foto y con
tipo/color en null). Parte de la cobertura del lunes es hábito, no bug.

**Placas repetidas (foto mal pegada) — la alerta `095` ya las está cachando:** 4 casos en el
rango (2 el sábado, 2 el domingo, **0 el lunes**). El más claro es `AZF-710-A`: una camioneta
blanca (carro 1356) y un Sentra rojo (1357) con la misma placa — imposible en dos carros reales,
así que a uno se le pegó la foto del otro. Como el color viene de la nota y la placa de la foto,
el desfase se ve solo. Seguirá hasta que la cámara fija trasera lo ataque de raíz.

**Los olvidos, patrón que sigue vivo:**

| Día | Secados descartados (<3 min, olvido entregado de golpe) | Cerrado automático |
|---|---|---|
| 1/ago | 0 | 1 |
| 2/ago | 1 | 0 |
| 3/ago | **5** | 0 |

El lunes tuvo 5 secados de segundos (mismo patrón del 21/22 jul). No distorsionan los promedios
(la `064` los excluye del secado), pero 5 en un día indican que el supervisor pierde la huella
del carro tras asignar — el mismo hilo que motiva la cámara fija. Se relaciona con la foto
faltante: carro olvidado = carro sin foto.

**Qué atender (por valor):** (1) foto del lunes al 88% — confirmar con el supervisor si el bache
es wifi o descuido, sobre todo el 1548 sin nada; (2) los 5 olvidos del lunes; ~~(3) Jorge Luna,
100% de encimados los dos días~~ 🔴 **el (3) era el contador envenenado, no Jorge — ver §11.50.**
Nada urgente en rechazos/cancelados/devoluciones.

## 11.85 Cierre del 24/jul/2026 — marca/modelo de la foto, review adversarial, y analítica calibrada

Sesión grande. Todo shippeado, verificado y en producción (migraciones `061`–`065`). El estado
canónico vive en las secciones de siempre; esto es el índice del día.

**1. Marca, submarca y tipo salen de la foto (el supervisor ya no captura marca).** Ver §9. La
misma llamada que lee la placa saca marca/modelo/tipo (`leerFoto`). Asignar quedó en **solo línea
+ secador**; Corregir conserva tipo/color pero **ya no marca**. Migraciones `061` (columna
`submarca` + RPC) y `062` (detalle con submarca). Probado sobre 59 fotos reales (~98% en marca).

**2. Review adversarial + sus arreglos.** El dueño pidió "poke holes". De los huecos que salieron:
- **La foto es AUTORITATIVA (`063`)**: sobrescribe placa/marca/submarca (antes `coalesce`), lo que
  recupera el caso de la foto pegada al carro equivocado — re-tomar una foto buena limpia el dato
  ajeno, y es la vía de corrección que faltaba. Pero `/foto` **no escribe si no hubo lectura**
  (timeout/error → `leerFoto` da `null`), para no borrar datos buenos en una re-subida.
- **El tipo solo corrige a la cajera si hay submarca (`063`)** — sin modelo, el tipo es puro ojo y
  no debe pisar. Ver §9.
- **Lectura de placa re-verificada**: el prompt fusionado no la degradó (57/59 placas idénticas al
  prompt viejo; las 2 que difieren son un carácter ambiguo en placas borrosas).
- **Regla de despliegue** (§2): cambios de UX en vivo se suben front+back juntos, en el corte.
- **Se mató la bitácora dedicada**: era una tercera fuente que se iba a desincronizar con esto y
  con `memory/`. El cierre del día vive aquí, en el `CLAUDE.md`, como esta misma sección.

**3. Analítica por persona por fin calibrada** (era el punto #1 del proyecto y estaba distorsionado):
- **Secado < 3 min fuera del promedio (`064`)** — olvidos entregados tarde (6 seg de "secado") que
  hacían ver rápido a alguien. Cuentan como lavado; su secado no promedia. Su espera SÍ (fue real).
  Ver §12 "Lo siguiente" punto 1.
- **Contexto de "encimados" (`065`, opción B del dueño)** — el reporte muestra cuántos carros le
  entraron a cada persona **mientras ya estaba ocupada**, sin tocar ningún promedio y sin un toque
  más del supervisor. Deja de castigar al que más carga. Ver §12 "Lo siguiente" punto 2.

**4. Operación del día.** La cola se descontroló al cierre (problema con un supervisor); se sacaron
por completo (cancelados, reversible) los 4 carros atorados. Y se **re-congeló el 20–24 jul** con la
analítica nueva (secado limpio + encimados), conservando su `congelado_en` original. El 19/jul se
dejó intacto (día sucio conocido).

## 11.9 Cierre del 22/jul/2026 — tercer día limpio, y limpieza del backend

**87 carros**, todos entregados, la cola quedó vacía sola (0 cerrados automáticamente). Espera
promedio **39.2 min** — cuarto día seguido bajando (46.8 → 43.3 → 41.2 → 39.2) con el volumen
ya estable en ~87-90. Secado 27.4 min. **0 rechazos, 0 placas duplicadas, 0 cancelados, 0
pruebas, 0 tiempos imposibles, 0 devoluciones.** Línea 1 impecable por tercer día (26 express
dentro, 0 fuera).

**Lo que se aflojó:** nota de caja 80/87 (92%, contra 98% el 20) — 5 de los 7 sin nota son de
la mañana temprano, se ve como un turno que arrancó sin el hábito. Y **foto 77/87 (89%)**, con
un hueco perfecto de **13:00 a 13:59: 4 carros, 0 fotos**.

**El hallazgo del día: tres carros con 6 segundos de "secado"** (369, 370, 291), con prelavados
de 60, 38 y 43 min. Es el mismo evento visto de los dos lados: el supervisor olvidó el carro y,
al acordarse, lo asignó y lo entregó de un jalón. Dos consecuencias:

- **Los únicos 3 prelavados largos del día son exactamente esos 3 carros** — o sea el 100% de
  los "prelavado > 20 min" son error de captura, no lentitud del taller.
- **El filtro de `tiempo_imposible` no los atrapa**, porque mira el total de pago a entrega
  (64, 42 y 47 min, normales). Lo imposible es el *secado*, no el total.

Sacarlos sube el secado promedio de 27.4 a 28.4 min (completos: 33.1 → 34.8). Poco en el
agregado, letal en el número individual: Jose Manuel aparece con "1 completo a 0.1 min". Y es
un patrón **nuevo**: 0 casos el 20/jul, **5 el 21**, 3 el 22. 👉 **Falta decidir el umbral**
(sugerido: <3 min de secado no entra a los promedios, igual que `cerrado_automaticamente`).

**Punto 8 (cola virtual), dato del 22:** 19 de 61 completos (31%) arrancaron con su secador
ocupado; cola promedio 19.2 min. Infla el secado de completos **5.9 min** (33.1 pared → 27.2
efectivo). Y **cambia el ranking**: Jesús Gil 30.1→24.4, Pablo Cruz 29.7→25.7, Saul Ramirez
41.3→30.7, Mario Hernández 37.7→31.0. Sin corregir, Saul se ve 39% más lento que Pablo con el
mismo volumen; corregido, 19%.

> **Del 21/jul:** los "2 eventos de rechazo" son **el mismo carro (211) rechazado dos veces con
> un minuto de diferencia** (12:17 Luis Luna por Tablero, 12:18 Luis Luna + Jorge Luna por
> Vidrios). El reporte lo dice bien (`carros: 1`), pero a Luis Luna se le cuentan 2 rechazos
> por un solo carro. Y hay **una placa duplicada el 21/jul** (carros 269 y 272, `WBZ919B`) —
> el patrón de la foto pegada al carro equivocado, otra vez.

### La limpieza del backend (migraciones 055–060)

Auditoría completa del backend leyendo **lo que vive en la base** (`pg_proc`, `pg_indexes`,
`cron.job`), no las migraciones históricas — cada migración reemplaza a la anterior, así que el
archivo miente y sólo la base dice la verdad. Se encontraron y arreglaron cinco cosas.

**El método, que es lo que hay que repetir:** antes de tocar nada se capturó una **línea base**
de 32 KB con la salida real del sistema (reportes de los 4 días, clasificación de todo el
catálogo, columnas generadas de los 324 carros, desgloses, grilla de secadores, historial de
placas, interpretación de las 331 notas). Después de **cada** migración se volvió a capturar y
se comparó. Todo cambio no intencional era un bug hasta demostrar lo contrario.

| Migración | Qué resuelve |
|---|---|
| `055` | **Una sola regla de "servicio especial"** (`es_servicio_especial`). `aviso_de_servicio` y `tipo_de_servicio` tenían la MISMA condición copiada. Se borró `tipo_de_servicio(text,text)` |
| `056` | **Un solo sistema de colores.** Había DOS y producían 4 pares de secadores con color idéntico. Y "Saul de Anda" ya no sale "Saul de" |
| `057` | Se borra lo muerto: `orden_etapas`, vista `etapas_medibles`, columna `empleados.iniciales`, índice degenerado. Índice nuevo para `/cola` |
| `058` | El reporte **deja de escanear toda la historia** para leer un día. Y el orden de `equipos` se vuelve determinista |
| `059` | El trigger de venta deja de reparsear el mismo JSON 6 veces |
| `060` | **Jibble sólo de 6 AM a 10 PM**, hora de Mexicali |

**Detalles que importan si esto se toca:**

- ⚠️ **`carros.aviso`, `carros.a_mano` y `carros.tiempo_imposible` son columnas GENERADAS sobre
  funciones.** Reemplazar la función **NO recalcula lo ya guardado** — quedarían dos verdades
  conviviendo. Hay que forzarlo con `update carros set producto = producto`. (No se puede con
  `set id = id`: `id` es `generated always as identity`.) La 055 lo hace y lo comprueba.
- 🔴 **Los dos sistemas de colores, medido, no supuesto:** `sincronizar_empleados` usaba
  `color_de(id)` (hash sobre 12 colores) y `agregar_secador_manual` usaba
  `asignar_colores_libres()` (índice sobre 16) — **y el segundo repintaba a todos los que
  vinieran de Jibble**. Resultado: Luis Chávez/Jose Manuel, Saul de Anda/Jaime Gallegos,
  Fermin Cortez/Saul Ramirez y Carlos Alonso/Luis Luna con el color **exactamente igual** en la
  grilla donde el supervisor escoge sin leer. Además `coalesce(min(n), 1)` mandaba a **todos**
  al color 1 cuando se acababan los índices, y con 19 personas y 16 colores ya estaba pasando.
  Ahora la paleta tiene 24, **los 16 primeros en el mismo orden** para que nadie con color
  asignado tuviera que reaprenderlo: cambiaron sólo los 4 que chocaban.
- **El orden de `equipos` no era determinista** y nadie lo había visto. `order by carros desc,
  equipo` no desempata por tipo, así que un equipo con la misma cantidad de carros en dos tipos
  (Pablo Cruz el 20/jul: 1 encerado y 1 express) barajaba sus dos renglones solo. Se descubrió
  porque la comparación contra la línea base marcó una diferencia en un cambio que no tenía
  nada que ver — **dos renglones intercambiados con cara de dato cambiado**.
- **`empleados.iniciales` estaba muerta Y equivocada**: la vista `secadores` la ignoraba y
  recalculaba `iniciales_de()` sobre otro nombre. 3 de 19 no coincidían (Walter tenía guardado
  `WA` y en pantalla salía `WR`). La app siempre leyó la vista.
- **`carros_cancelado_idx` era un índice degenerado**: indexaba `cancelado_en` filtrando
  `where cancelado_en is null`, o sea que sus 318 entradas tenían todas la clave `null`. Se
  cambió por `carros_cola_idx`, parcial y con el predicado idéntico al de `/cola` — verificado
  con `EXPLAIN`: pasa de recorrer la tabla a `Index Scan`, 1 buffer.

**Lo que NO se tocó, con su razón:**

- **`historial_placas`** agrupa toda la tabla. Se midió: **1.6 ms** hoy, y la pregunta "cuáles
  han venido más" **obliga** a agrupar todo. Proyectado a un año son ~200 ms en una pantalla de
  uso esporádico, no como `/cola` que corre cada 3 s. Cambiar el contrato del endpoint costaba
  más de lo que ahorraba.
- **`etapa_efectiva()`**: la usa `avanzar_etapa`. Traduce estados que ya no se generan, pero
  quitarla dejaría pasar un carro sin validar si alguno reapareciera. No se gana nada.
- **La doble llamada a `interpretar_nota`** (una en `nota_de_la_venta` para decidir si un
  descuento se lee como nota, otra en el trigger para leerla). Quitarla obliga a cambiar el
  contrato de `nota_de_la_venta`, que devuelve texto. Son 90 llamadas al día sobre una función
  inmutable; no vale tocar el camino por donde entra el dinero.
- **`tunel`/`por_asignar` en el front**: se quitaron del backend (`DEMORA_SEG`) pero se dejaron
  en `docs/index.html`, donde son defensivos y no dependen del backend.

> 💡 **`detalle_venta()` decide que desanidó bien mirando si hay `products`.** Se comprobó
> contra las 5 devoluciones reales: **todas traen `products`** y el trigger las lee bien. Si
> algún día Zettle mandara una devolución sin ese campo, no cancelaría el carro. No se cambió
> porque funciona con los datos reales, pero queda dicho.

## 12.0 Cierre del 20/jul/2026 — el primer día con datos que significan algo

**86 carros** (vs 55 el 19/jul, +56%): el día más grande hasta ahora. 85 entregados y **1 se
cerró solo** (carro 194, entró 19:44, el supervisor olvidó ese último — se cerró a mano con
`cerrar_pendientes()`, marcado `cerrado_automaticamente`, así que cuenta como lavado pero sus
tiempos ficticios no entran a los promedios). La cola amaneció limpia.

**Lo más importante: la calidad de datos dio un salto y ya se puede confiar en los números.**

- **Nota de caja: 84 de 86 (98%)**, contra 2 de 25 el 19/jul. Las cajeras adoptaron el hábito.
- **Foto 84, placa leída 78 (91%), 6 ilegibles.** 0 placas duplicadas (el bug de la foto mal
  pegada NO se repitió), 0 reembolsos-fantasma, 0 pruebas, 0 tiempos imposibles, 0 cancelados.
- **Línea 1 impecable:** 0 express fuera de la 1, 0 no-express en la 1.
- Reporte del día: espera promedio **43 min**, secado promedio **31 min** (mezcla; completos
  solos **38 min**), **0 rechazos**.

**Equipos (completos, con aspirado), rápidos y con volumen:** Pablo Cruz 11 carros @ 34 min,
Jesús Gil 14 @ 34 min, Saul Ramirez 9 @ 37 min, Luis Luna 10 @ 43 min. Walter Rodríguez es de
hecho el del express: 18 @ 16 min. Equipos de 2 salen a ~20 min.

**Lo que hay que atender (por orden de valor):**

1. 🟡 **El punto 8 (cola virtual) ya está cuantificado y pesa.** De 59 completos, **18 (31%)
   tuvieron a su secador ocupado con otro carro al arrancar**; eso infla el secado individual
   **~4.6 min en promedio, hasta 42 min** en el peor caso (la Land Rover de Pablo salió con
   79 min de "secado" que casi seguro es cola, no trabajo). **Los promedios por persona de
   arriba están inflados por esto**, sobre todo para los que más cargaron (Pablo 11, Luis 10).
   El dueño lo está analizando; aquí está el dato para decidir. Sigue EN PAUSA.
2. 🔵 **"Saul de Anda" sale como "Saul de"** también en el reporte del dueño (no solo la
   grilla). Bug cosmético del nombre corto, pendiente.
3. 🟢 **El olvido de prelavado ya tiene regla** (20 min, exenta a mano): hoy solo 2 casos (la
   Acura de 38 min y la RAM de 19.8 borderline). No es patrón — 2 de 86.

> **El 21/jul es el segundo día de prueba.** El 19/jul se borró (asignaciones al azar); el 20
> ya salió coherente (línea 1 perfecta, patrones que cuadran). Con dos o tres días así de
> limpios, los tiempos por persona empiezan a servir de verdad — en cuanto se decida el punto 8,
> que sin él castiga al que más carros carga.

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

### Sección Clientes: la tabla "Últimos lavados" (30/jul/2026)

La pestaña **Clientes**, antes de escribir, muestra **UNA sola tabla**: los últimos 20 lavados
que van entrando. Sirve para "ver los lavados entrando" y **se actualiza sola** con cada carro.

> ⚠️ **Historia, para no repetir el bucle.** Primero se intentó reusar el libro de lealtad
> (`visitas` → `personas_recientes`, 085), pero ése **solo crece con la caja en vivo o el import
> del ClientNoteTracker**, no con la operación — el dueño reportó *"la lista de las 10 últimas
> visitas no se actualiza"*. Se agregó `carros_recientes` (093) como segunda lista, y al final el
> dueño pidió **quitar la de lealtad y dejar una sola tabla** (094). La distinción sigue
> importando: **`visitas` = lealtad (caja/CNT); `carros` = operación (webhook).** No volver a
> alimentar esta tabla de `visitas`.

- **Fuente:** `carros_recientes(20)` (**migración 094**) sobre la tabla `carros`. Fila **por
  carro** (no agregada por placa), orden por `creado_en desc`. Solo excluye prueba y cancelados.
- **Columnas = las del Historial por placa (Operación) MENOS Visitas, MÁS Ticket al final:**
  Carro · Placa · Cliente · Última vez · Hora de llegada · Secó · **Ticket**.
- **Se llena sola conforme entra la info** (esto es el punto, no un adorno):
  1. **Al cobrar:** descripción de la cajera (tipo+color, "Camioneta Blanca") + **ticket**
     clicable (abre la venta de Zettle vía `ticket_detalle`, que ya lee `ventas.payload` en vivo
     — 088 —, así que los lavados de HOY sí traen ticket aunque no estén en `zettle_compras`).
  2. **Al tomar la foto:** la descripción pasa a marca+submarca+color ("MG RX5 Blanca") y aparece
     la **placa** clicable a su perfil.
  3. **Si la placa liga a lealtad:** el **nombre del cliente** clicable a su perfil.
  4. Los **secadores del carro**, clicables a su perfil.
- **El dueño de lealtad sale de `clientes_de_placas`** — la MISMA fuente que el Historial por
  placa, para no tener dos reglas de "quién es el dueño de esta placa". Lo agrega el Edge Function
  (`/carros-recientes`), no la RPC. Los secadores y el ticket sí los da la RPC (por `carro_id` y
  desde `ventas.payload`, respectivamente).
- **Enlaces:** `cliCablearBotones` cablea `data-placa`→perfil de placa, `data-persona`→perfil de
  cliente, `data-ticket`→modal de ticket, `data-trab`→perfil del secador (este último se agregó
  aquí; antes solo lo cableaba la Operación).
- Verificado en vivo (30/jul): el carro 1092 pasó de "Camioneta Blanca" (recién cobrado) a
  "Audi Q5 Blanca + placa 9XUX799 + secador" cuando el supervisor tomó la foto — la fila se
  completó sola. `carros_recientes` era `093` (dos listas, nombre→placa→omitir); **094** la rehízo
  a esta tabla (default 20, sin exigir nombre/placa, + ticket + secadores).

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
- **Las CTEs del reporte filtran por los carros del rango** (migración `058`, 22/jul/2026).
  Antes `secado` y `equipo_por_carro` agrupaban las tablas **completas** y hasta después hacían
  `left join` contra el día: el 22/jul agrupaba 318 filas de etapas para usar 87. Crece lineal
  con el histórico, y el reporte se llama una vez **por cada día consultado** — con un rango de
  un mes, treinta veces.
- **El `order by` de `equipos` desempata por `tipo`.** Sin eso, un mismo equipo con la misma
  cantidad de carros en dos tipos distintos empata y Postgres baraja los dos renglones a su
  antojo. Si algún día se compara la salida del reporte contra una versión anterior, eso
  aparece como "un dato cambió" cuando sólo se movieron de lugar.
- **El reporte acepta un RANGO de días** (20/jul/2026), con dos casillas como en Zettle.
  `reporte_del_dia` **delega** en `reporte_del_rango(desde, hasta)`: hay **una sola
  implementación** y el día es el caso particular. Escribir una segunda función habría sido el
  mismo error que este proyecto cometió cuatro veces ese día.
  ⚠️ Un rango **no** se arma sumando filas congeladas — ésas son por día y los promedios hay
  que ponderarlos por carro, no promediar promedios. Se calcula al vuelo.

### Un lavado a mano no pasa por el túnel (20/jul/2026)

`asignar_carro` fabricaba 4 min de túnel para **todos** los carros, incluidos los de lavado a
mano. No era sólo una etiqueta falsa: **le robaba 4 minutos al prelavado** para dárselos a una
etapa que nunca ocurrió, así que el prelavado promedio de los lavados a mano salía corto.

Arreglado en la `050`, usando `carros.a_mano` — la misma regla que pinta la banderita cian, no
una copia. Probado con dos carros entrados a la misma hora: el de mano conserva sus 15 min
completos de prelavado; el de túnel los reparte en 11 + 4.

> El desglose de Finalizados muestra el túnel **en su propio renglón** con el valor guardado,
> no con un 4 escrito a mano. Da 4 en todo el flujo nuevo y el valor real en los carros viejos,
> donde el túnel sí se midió (hay de 1, 3, 5 y 8 min). Si cambia la máquina,
> `segundos_de_tunel()` lo cambia en un solo lugar.

### Un carro entregado demasiado rápido no se cuenta (20/jul/2026)

Regla del dueño: hay tiempos que **físicamente no se pueden hacer**, ni con el taller vacío.

| Tipo | Mínimo de pago a entrega |
|---|---|
| Con aspirado (completos, encerados) | **20 min** |
| Express (sin aspirado) | **10 min** |

Textual: *"si hay una venta que se entrega en menos de esos tiempos, muy posiblemente fue un
error o prueba y no debería ser contabilizada"*. Él mismo creó una venta y la entregó en menos
de 10 minutos mientras se familiarizaba con la app.

**Se midió antes de fijar los números**, contra los 40 carros del 19/jul:

```
con aspirado  33 carros   min  2 min   promedio 48 min   max 128 min
express        7 carros   min 13 min   promedio 19 min   max  24 min
```

⚠️ **Por eso son DOS umbrales y no uno.** Los express reales duraron entre 13 y 24 min: un
umbral único de 20 min habría descartado **tres express buenos**. Es el mismo error de comparar
peras con manzanas, pero ahora en los umbrales.

La regla descartó 4 carros, y los cuatro huelen mal por razones independientes — dos de ellos
(70 y 71) son los del apuro de las 18:54 que ya se habían detectado por otro camino, el de la
foto mal pegada, y el 70 es además el que se devolvió un minuto después de entregarse. **Tres
señales distintas apuntando al mismo momento.**

Efecto en los promedios, que muestra cuánto distorsionaban:

```
lavados          40  →  36
espera promedio  42.8 → 46.8 min
secado promedio  32.0 → 35.5 min
```

**No se esconden: se cuentan aparte** (`descartados_por_tiempo`, y sale en la página del dueño
sólo cuando no es cero). Es una heurística, no una certeza — el dueño mismo dijo *"muy
posiblemente"*. Si un día salen ocho, no es que la regla esté mal: es que algo raro pasó ese
día. Mismo criterio que `cerrados_automaticamente`.

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
>
> ✅ **El aviso ya existe (30/jul/2026, migración `095`).** El reporte muestra hasta arriba de
> Operación una **alerta roja** cuando dos+ carros del mismo día local comparten placa, con los
> carros de cada grupo (hora, descripción y ticket clicable) y la placa clicable a su perfil
> —para comparar fotos y cachar el pegado—. Vive en `placas_repetidas_del_rango(desde,hasta)` +
> endpoint `/placas-repetidas`, **aparte del reporte congelado** (solo lectura, funciona para
> cualquier día/rango). NO impide el pegado —eso lo resolverá la cámara fija—, solo lo hace
> visible. El 30/jul cachó 4 casos, incluido `BF-8884-A` pegada a **3 tickets** (25488/25494/
> 25496) y **dos clientes distintos** (Parka Moreno y Petro Gonzales Avila). Cierra el pendiente
> §12 punto 3.

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

### ⚠️ Los datos de secadores del 19/jul se BORRARON (noche del 20/jul)

El dueño lo pidió y dio la razón: *"estaba asignando secadores a lo menso porque no sabía
quiénes eran en realidad"*. Se borraron **68 asignaciones** (13 personas) y **2 rechazos**.

- Los rechazos se borraron **aunque no los pidió**: estaban a nombre de Edgar Reyes, y con
  asignaciones al azar es muy probable que fueran de otra persona. Dejarlos habría marcado un
  error a alguien que quizá ni tocó ese carro — y el `CLAUDE.md` ya dice que el objetivo de los
  rechazos "no es castigar, es saber a quién entrenar".
- **NO se borraron** los carros, las etapas de secado, las líneas, las placas ni las fotos. El
  carro **sí** tardó ese tiempo en secarse: eso es una medición real del taller. Lo que estaba
  mal era **a quién** se le atribuía, no el reloj.
- Por eso el reporte del 19/jul quedó con `equipos: 0` y `rechazos: 0`, pero conserva
  `secado_promedio 35.5 min` sobre 36 carros. Ese promedio anónimo **sí sirve** como línea base.

> **El 21/jul es día de prueba declarado.** Los primeros datos de equipo que van a significar
> algo son los de ese día en adelante.

### Lo siguiente (en este orden) — actualizado al cierre del 22/jul/2026

1. ~~**Decidir el umbral del secado de 0 segundos.**~~ **RESUELTO (24/jul/2026, migración `064`).**
   El dueño fijó **3 min**: un secado < 3 min (imposible) cuenta como vehículo lavado pero **su
   secado no entra a los promedios** (general y por equipo). Matiz respecto a la sugerencia
   original: se saca **solo del secado, NO de la espera** — a diferencia de `cerrado_automaticamente`
   (cuya hora de entrega es fabricada), el olvido SÍ se entregó, así que su espera de pago-a-entrega
   es real y cuenta. Se surface `secados_descartados` en el reporte. Verificado día por día: el
   20/jul (0 casos) quedó idéntico; el 21 sacó 5 y el 22 sacó 3, subiendo el secado 27.4→28.4 min
   justo como estaba previsto. El umbral vive en `secado_min` (180 s) dentro de `reporte_del_rango`.
2. ~~**Decidir el punto 8 (cola virtual).**~~ **RESUELTO (24/jul/2026, migración `065`).** Infla el
   secado del que más carga (le entran más carros encimados) y lo hace ver lento sin serlo. El dueño
   **descartó** tocar el número o pedir un toque más al supervisor (son de la tercera edad y pierden
   la huella del carro tras asignarlo). Escogió la **opción B: solo mostrar contexto.** El reporte
   ahora trae, por equipo y en general, cuántos carros **arrancaron encimados** (al asignarlos, ese
   secador ya traía otro sin entregar) — se saca de la hora de asignación vs. la entrega del otro,
   **sin ninguna acción del supervisor**. Es un conteo sí/no, no una resta, así que **no se va a
   negativo** con el caso de secado en paralelo (carro 109) que hizo pausar la versión que corregía
   el número. Los promedios de secado quedan **idénticos** (verificado día por día); solo se agregan
   campos. La página del dueño muestra "Le entraron encimados: N (X%)" junto a cada equipo, con la
   nota de que un secado alto con muchos encimados es saturación, no lentitud. Ej. real (20/jul):
   Jesús Gil 7 de 14 (50%).
3. ~~**Avisar cuando dos carros del mismo día comparten placa.**~~ **HECHO (30/jul/2026,
   migración `095`).** Alerta roja en el reporte (Operación) con los carros de cada grupo y la
   placa clicable para comparar fotos. El 30/jul cachó 4 casos (uno pegado a 3 tickets y 2
   clientes). Ver §12.1. Sigue subiendo con el volumen (~2-3/día esta semana); la cámara fija
   trasera lo atacaría de raíz.
4. **Ver por qué el 22/jul faltaron fotos de 13:00 a 13:59** (4 carros, 0 fotos) y por qué la
   nota de caja bajó a 92% con 5 huecos en la mañana temprano. Los dos huelen a turno, no a
   bug: se confirma preguntando, no consultando.
5. **Con la analítica ya limpia, leer los tiempos por persona en serio** — en cuanto estén
   resueltos los puntos 1 y 2, que son justo los dos que hoy los distorsionan.

> ✅ Resuelto el 22/jul: el cosmético **"Saul de Anda" → salía "Saul de"** en grilla y reporte
> (migración `056`), junto con toda la limpieza del backend. Ver §11.9.

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

### Lo que se construyó el 20/jul/2026 (tarde) — 10 pedidos del dueño + extras

Todo se hizo con la operación en marcha, cambio por cambio, probando en el navegador (con datos
falsos, sin tocar la API) y con `curl`/`do-raise` contra la base antes de pushear. Lo visual se
verificó midiendo el DOM, no solo mirando la pantalla.

| Cambio | Dónde |
|---|---|
| Foto solo tras asignar; se ve apagada, no desaparece | `docs/index.html` |
| Botón de info (ⓘ) → desglose EN VIVO (secado corriendo) | `053` + `docs/index.html` |
| Corregir preselecciona y **edita** secadores sin reiniciar el reloj | `052` + `/cola` (secador_ids) + `/editar` |
| `datos_de_nota` solo se apaga si el valor cambia | `051` |
| Guiones rojos girando en el botón de Asignar (antes glow) | `docs/index.html` |
| Secadores en la tarjeta; color manual en mayúsculas | `docs/index.html` |
| Asignar abre hasta arriba; se quitó el botón de galería | `docs/index.html` |
| El back del teléfono cierra la pantalla, no sale de la app | `docs/index.html` |
| El reloj de la cola ya no reconstruye la lista (guiones fluidos) | `docs/index.html` |

- **Migraciones `051`–`053`**, todas aplicadas en producción. La `052` absorbe la `051`.
- **`editar_carro` cambió de firma** (agregó `p_secadores`, `p_empleados`): la `052` hace
  `drop function` de la vieja primero, si no quedaban dos y la llamada por nombre era ambigua.
- **Punto 8 (cola virtual del secado) quedó EN PAUSA** por decisión del dueño: la validación
  destapó un caso de secado en paralelo (carro 109 del 20/jul) que sale negativo con la regla
  de "fila". Él lo va a analizar. Ver `PENDIENTES.md` y la consulta `q11` de esa sesión.
- **El rechazo de prueba de Chuy (`rechazos.id=9`) se borró** antes de las 8:30 para que no
  quedara en la fila congelada del reporte. La tabla `rechazos` quedó vacía.

## 13. Decisiones pendientes (llenar con el tiempo)

**Abiertas al 19/jul/2026, en orden de urgencia:**

- ~~**¿Un carro entregado y luego devuelto cuenta como lavado?**~~ **RESUELTO y CONFIRMADO
  por el dueño (20/jul/2026): SÍ cuenta.** Solo se cancela si la devolución llega mientras el
  carro sigue en la cola.

  La razón del dueño es mejor que la que yo había supuesto: *"en los casos en los que hubo
  reembolso pero sí se entregó el carro, es comúnmente porque algo salió mal, y para no quedar
  mal con el cliente le regresamos su dinero, pero el capital humano sí se utilizó"*.

  O sea que una devolución **después** de entregar no es una venta que no ocurrió: es una
  **falla de servicio que se pagó con dinero para no perder al cliente**. El trabajo existió,
  la gente se ocupó, y el reporte debe seguir contándolo.

  > 💡 **Lo que esto destapa, y todavía no está construido:** por la propia descripción del
  > dueño, una devolución sobre un carro ya entregado es una **señal de calidad** — del mismo
  > tipo que un rechazo, pero peor: el rechazo se atrapa antes de que el cliente se vaya, y
  > esto se atrapa cuando ya se fue molesto. Hoy es **invisible**: no cancela el carro, no
  > aparece en el reporte y nadie se entera.
  >
  > El dato ya existe y no hace falta cambiar el modelo: son las filas de `ventas` con
  > `refundsPurchaseUuid` que apuntan a un carro `entregado` y sin cancelar. Faltaría contarlo
  > en el reporte diario, junto a los rechazos.
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

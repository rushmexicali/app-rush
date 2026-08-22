---
name: auditoria-general
description: Auditoría exhaustiva de todo el código del proyecto RUSH — ocho revisiones en paralelo (base de datos, API, funciones de fondo, las tres pantallas, costos y los datos de la operación), de SOLO LECTURA, comprobando lo grave contra producción antes de reportarlo. Úsala cuando el dueño diga "corre la auditoría general", "auditoría completa", "revisa todo el código", "revisión exhaustiva" o algo equivalente.
---

# Auditoría general

Reproduce la auditoría del 19/ago/2026 (46 hallazgos, 20 arreglados ese día). El detalle de
aquélla vive en `CLAUDE.md §11.45` y `§11.50`; la lista con estado, en `PENDIENTES.md`.

---

## Paso 0 — OBLIGATORIO: cuestionar el método antes de correrlo

**No arranques la auditoría sin hacer esto primero.** Es un encargo explícito del dueño
(19/ago/2026): cada vez que se corra, hay que preguntarse si la forma de correrla sigue siendo
la correcta, no repetirla en automático.

Pregúntate, y **dile al dueño lo que concluiste antes de lanzar nada**:

1. **¿Los agentes que voy a usar son los correctos?** Mira qué tipos de agente hay disponibles
   en esta sesión (el listado llega en el system prompt). El reparto de ocho frentes salió del
   tamaño real del código, no de una regla: si un archivo creció mucho o nació uno nuevo, el
   reparto cambia.
2. **¿Salió algo nuevo que convenga usar?** Un agente especializado (revisión de código,
   seguridad), `/code-review ultra` para la rama, o una herramienta que todavía no existía. Si lo
   hay, **propónlo** con lo que cuesta y lo que gana.
   > ⚠️ **La orquestación con `Workflow` y el reparto de modelos YA están decididos** — ver la
   > sección "Los modelos ya están decididos", abajo. No los vuelvas a poner a votación en cada
   > corrida: el dueño escogió fanout + refutadores, y la mezcla Fable/Opus, el 21/ago/2026.
3. **¿Hay una forma más exhaustiva?** Por ejemplo: fanout por dimensión y después un verificador
   independiente por hallazgo que intente **refutarlo**; o un crítico final que pregunte "¿qué
   frente no se revisó?". La auditoría anterior no tuvo pase adversarial y **produjo un juicio
   por escrito sobre dos personas con nombre que resultó falso** (el contador de encimados).
   Ése es el costo de no verificar.

Presenta la recomendación en dos o tres renglones y espera su palabra. Si dice "córrela igual",
se corre igual.

---

## Los modelos ya están decididos — NO se vuelve a preguntar (21/ago/2026)

El dueño lo fijó el 21/ago/2026, después de la corrida de ese día: **todas las auditorías de aquí
en adelante van con esta mezcla.** El Paso 0 sigue cuestionando el método, pero esta parte ya está
resuelta y no se re-litiga cada vez.

| Fase | Modelo | Por qué |
|---|---|---|
| Los frentes que **buscan** | `fable` | Es horizonte largo de verdad: leer 200 KB de `CLAUDE.md`, 3,000 líneas de una pantalla, escribir SQL y cruzarlo contra producción. Ahí salen los hallazgos que no se ven leyendo |
| El **crítico de completitud** | `fable` | Misma clase de trabajo, y su pregunta —"qué falta"— es la más abierta de todas |
| Los **refutadores** | `opus` | Trabajo acotado: abrir una función, comprobar una afirmación, correr una consulta. No necesita frontera, y son ~60 agentes contra 12 |

En el script del `Workflow` es una opción por llamada:

```js
agent(prompt, { model: 'fable', effort: 'xhigh',  phase: 'Buscar' })      // frentes y crítico
agent(prompt, { model: 'opus',  effort: 'medium', phase: 'Refutar' })     // refutadores
```

**Se mezclan dentro de la MISMA corrida.** No hay que partir la auditoría en dos ni parar nada: el
modelo se escoge por agente, no por auditoría.

⚠️ **Con Fable hay que REESCRIBIR los prompts de los frentes, no sólo cambiarle el modelo.** La
documentación de Anthropic advierte que *los prompts escritos para modelos anteriores le salen
demasiado prescriptivos a Fable y le bajan la calidad de salida*. Los prompts de frente que usó la
corrida del 21/ago son exactamente eso: listas largas de "busca esto, después esto, después esto".
Con Fable van al revés — el objetivo, el contexto de por qué importa, y la libertad de decidir
dónde mirar. Las listas detalladas se conservan como **ejemplo de lo que ya salió antes**, no como
el guion que hay que recorrer.

Dos consecuencias prácticas que hay que decirle al dueño al arrancar: Fable cuesta el doble que
Opus ($10/$50 por millón contra $5/$25, precios del 21/ago/2026), y **corre turnos más largos**, así
que la auditoría tarda más en pared aunque encuentre más.

---

## Paso 1 — Los OCHO frentes, en paralelo

Un agente por frente, todos lanzados en el mismo mensaje. **Nada se toca: es de SOLO LECTURA.**
Ningún agente escribe archivos, corre migraciones ni despliega.

| # | Frente | Qué abarca |
|---|---|---|
| 1 | **Base de datos** | Lo que vive en la base (`pg_proc`, `pg_indexes`, `cron.job`, RLS, permisos), no las migraciones históricas — cada migración reemplaza a la anterior, así que **el archivo miente y sólo la base dice la verdad** |
| 2 | **API `app`** | `supabase/functions/app/index.ts` — las ~33 rutas, el candado de acceso, formato de respuestas, manejo de errores |
| 3 | **Funciones de fondo** | `zettle-webhook`, `sincronizar-jibble`, `limpiar-fotos` y los crones que las disparan |
| 4 | **Pantalla del supervisor** | `docs/index.html` + `docs/sw.js` |
| 5 | **Pantalla de la caja** | `docs/caja.html` |
| 6 | **Reporte del dueño** | `docs/reporte.html` |
| 7 | **Costos, transversal** | Anthropic (tokens por foto), Supabase (Storage, invocaciones, CPU de la base), y qué se rompe primero al crecer a 150–200 carros/día |
| 8 | **DATOS DE LA OPERACIÓN** | No el código: los DATOS. ¿Sigue entrando lo que debe entrar? Última visita del CRM, última venta, huecos en la secuencia de `purchaseNumber`, carros sin foto o sin placa por día, colas de trabajo pendiente (`fotos_por_leer`, `imp_ligado_conflictos`, `avisos_del_sistema`, `placa_dudosa`), tablas que crecen sin límite. **Se compara contra los días anteriores: lo que importa es el CAMBIO, no el valor.** |

A cada agente dale, además del frente: leer `CLAUDE.md` completo primero (las decisiones tienen
razón escrita y muchas "rarezas" son deliberadas), y **el patrón de fondo a cazar**, que es lo
que de verdad produce hallazgos:

- **La misma regla escrita en dos lugares**, que divergen en silencio.
- **Un error que se responde como éxito.**
- **Trabajo a medio terminar** que queda inerte sin fallar (desplegado a medias, cron sin agendar,
  secreto sin poner).
- **Un dato viejo que envenena un cálculo** (cancelados, pruebas, cerrados automáticamente).

---

## Paso 2 — Comprobar contra producción lo que se va a reportar

**Un hallazgo que sólo se leyó no se reporta como hecho.** La regla del proyecto es que lo grave
se mide, no se deduce — y va en las dos direcciones: la auditoría anterior encontró bugs reales
que no se veían leyendo, y también estuvo a punto de reportar como sano algo que no lo estaba.

- SQL contra la base real: `bash scripts/releer-fotos/q.sh <archivo.sql>`.
- API en vivo: `curl.exe` (nunca `Invoke-WebRequest` — da 401 falsos en esta máquina).
- Escenarios que escriben: bloque `do $$ … raise` que revierte todo al terminar.
- Marca cada hallazgo con ✔ cuando se comprobó a mano, y déjalo sin marca cuando sólo se leyó.

Y **cuantifica**: "201 de 935 encimados son falsos" mueve una decisión; "el filtro podría estar
mal" no.

---

## Paso 3 — Entregar

1. **Agrupar por consecuencia**, no por archivo: rompen algo hoy / bombas con fecha / seguridad /
   números que no cuadran / backend / estabilidad / costos.
2. **Una sección de lo que se comprobó que está bien**, para no volver a auditarlo. La anterior
   dejó ahí "0 ventas perdidas en 2,690 tickets consecutivos", que fue el hallazgo más valioso.
3. **Orden sugerido de arreglo**, con lo que desbloquea cada uno.
4. **Las decisiones que le tocan al dueño**, separadas de lo que es trabajo mío.
5. Escribir la lista en `PENDIENTES.md` con su estado, y actualizar la memoria
   `auditoria-completa-*`.
6. Ofrecer el informe como Artifact para leerlo fuera de la terminal.

---

## Lo que NO hace esta auditoría

- **No arregla nada por su cuenta.** Encontrar y arreglar en la misma pasada mezcla dos trabajos
  con criterios distintos; el dueño escoge qué entra.
- **No corre con el autolavado abierto si va a desplegar algo.** Auditar sí (es lectura); subir
  arreglos va al cierre, después de las 8 PM (`CLAUDE.md §2`).
- **No re-audita lo que ya está en la lista de comprobado**, salvo que algo cerca haya cambiado.

## Antes de subir cualquier arreglo que salga de aquí

```bash
bash pruebas/correr.sh
```

Y súmale un caso por cada hallazgo que se arregle: ésa es la única parte de la auditoría que
evita que la siguiente encuentre lo mismo.

---

## Lo que la corrida del 20/ago dejó dicho para la siguiente

Escrito el 21/ago/2026, después de arreglar sus hallazgos. Vale más que cualquier hallazgo suelto:

- ✅ **El octavo frente (el código escrito ese mismo día) valió la pena** y se queda: encontró el
  hallazgo más grave de los 53, sobre código propio. La instrucción que lo hizo funcionar fue
  *"no le creas a los comentarios: el autor escribió las dos cosas en la misma hora"*.
- ✅ **El pase adversarial no refutó ninguno de los 8 graves, pero bajó la severidad de 4.** Sin
  él, cuatro números inflados habrían entrado como urgentes. Siguiente paso: que verifique
  también los `media`, que es donde se acumularon los 53.
- 🔴 **Faltaba el frente de DATOS DE LA OPERACIÓN, y ya está arriba.** Los cinco días de CRM
  muerto los cazó el crítico de completitud, no un frente — porque los siete eran superficies de
  código más costos, y ninguno tenía como sujeto los datos.
- ⚠️ **7 duplicados entre frentes.** El reparto por archivo hace que un bug que cruza dos archivos
  se cuente dos veces y con severidades distintas. Al consolidar, agrupar por CAUSA antes que por
  archivo.
- ⚠️ **Frentes flojos:** supervisor (3,069 líneas, 6 hallazgos, ninguno alto — la densidad más
  baja) y costos (4 de 6 hallazgos eran ecos de otros). Al supervisor conviene darle sub-frentes.
- 🔑 **Y uno que sí se equivocó:** reportó que `obtenerStream()` de la caja cae sin aviso a la
  cámara del tablet. **Es falso** — el código dice explícitamente lo contrario y tiene su
  mensaje de error. El respaldo silencioso estaba un nivel más abajo, en `tomarFoto()`. Los
  hallazgos que citan una función hay que **abrirla**, no confiar en el resumen del agente.

---

## Lo que la corrida del 21–22/ago dejó dicho para la siguiente

Primera corrida con `Workflow` y refutadores. 79 hallazgos, 68 veredictos de refutación.

- ✅ **El pase adversarial es lo que hace que esto sirva.** De **18 hallazgos marcados `alta` por
  sus autores, sólo 2 sobrevivieron** — y eran el mismo bug visto desde dos frentes. **9 se
  refutaron por completo.** Segunda corrida seguida en que desinfla más de lo que confirma.
- 🔴 **AL CRÍTICO TAMBIÉN HAY QUE REFUTARLO.** Esta vez quedó fuera del pipeline de refutación y
  **su hallazgo principal salió falso**: dijo que el CRM había recaído «24 h después de arreglarlo,
  la misma falla de los cinco días», cuando el hueco era la **cadencia normal** del import (un lote
  post-cierre) y el mecanismo viejo sí estaba arreglado. Sus mediciones eran correctas y su
  interpretación no — que es exactamente el modo de falla que el pase existe para atajar.
  En el script: meter `critico` al mismo `pipeline` que los frentes.
- 🔴 **FALTA UN FRENTE QUE ABRA EL NAVEGADOR.** Nadie ejecutó una sola pantalla; tres frentes lo
  dijeron de frente. Todos los hallazgos de carrera del front (pantalla atrapada, cronómetro que no
  se apaga, foto que se borra sola, aviso de "sin conexión") son **lectura de código, no
  comportamiento observado**. El proyecto ya tiene la técnica —interceptar `pedirJSON` con datos
  falsos, como el 19/ago— y no se usó.
- 🔑 **Decirle a cada frente que lea `PENDIENTES.md`, no sólo el `CLAUDE.md`.** Varios hallazgos se
  refutaron por estar **ya en la bandeja**, algunos con las mismas palabras. Es trabajo desperdiciado
  en las dos puntas.
- ⚠️ **Los duplicados entre frentes siguen ahí, y el crítico los cazó bien:** el aviso falso de las
  176 fotos huérfanas lo reportaron **cinco frentes**, la guarda de `reporte.html` **tres**, los
  comodines de LIKE **tres**. Vale seguir pidiéndole al crítico el agrupado por causa.
- ⚠️ **El límite de sesión cortó la corrida dos veces.** Se recupera con
  `Workflow({scriptPath, resumeFromRunId})`: los terminados vuelven cacheados y sólo re-corren los
  caídos. Pero **los que van a la mitad se pierden**, así que no sirve parar a media fase. Con ~80
  agentes hay que contar con dos o tres reanudadas.
- 💡 **Lo más valioso salió de mirar donde nadie miraba:** el crítico corrió `pruebas/correr.sh`
  (que ningún frente corrió) y encontró que la prueba del import **no puede fallar**; y abrió los
  `scripts/*.ps1` (que nadie abrió) y encontró que el rescate de una venta perdida no funciona para
  una devolución. Los dos son superficies fuera de los frentes por archivo.

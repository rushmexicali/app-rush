---
name: auditoria-general
description: Auditoría exhaustiva de todo el código del proyecto RUSH — siete revisiones en paralelo (base de datos, API, funciones de fondo, las tres pantallas, costos), de SOLO LECTURA, comprobando lo grave contra producción antes de reportarlo. Úsala cuando el dueño diga "corre la auditoría general", "auditoría completa", "revisa todo el código", "revisión exhaustiva" o algo equivalente.
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
   en esta sesión (el listado llega en el system prompt). El reparto de siete frentes salió del
   tamaño real del código, no de una regla: si un archivo creció mucho o nació uno nuevo, el
   reparto cambia.
2. **¿Salió algo nuevo que convenga usar?** Modelos más capaces, un agente especializado
   (revisión de código, seguridad), `/code-review ultra` para la rama, o una orquestación con
   `Workflow` que permita verificar cada hallazgo de forma adversarial. Si lo hay, **propónlo**
   con lo que cuesta y lo que gana.
3. **¿Hay una forma más exhaustiva?** Por ejemplo: fanout por dimensión y después un verificador
   independiente por hallazgo que intente **refutarlo**; o un crítico final que pregunte "¿qué
   frente no se revisó?". La auditoría anterior no tuvo pase adversarial y **produjo un juicio
   por escrito sobre dos personas con nombre que resultó falso** (el contador de encimados).
   Ése es el costo de no verificar.

Presenta la recomendación en dos o tres renglones y espera su palabra. Si dice "córrela igual",
se corre igual.

---

## Paso 1 — Los siete frentes, en paralelo

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

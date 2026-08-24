# Arnés del front del supervisor — se corre A MANO, en un navegador

```bash
bash pruebas/front-supervisor/armar.sh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File pruebas/front-supervisor/servidor.ps1 -Raiz "<lo que imprimió armar.sh>" -Puerto 8777
# y abrir http://localhost:8777/
```

## Por qué existe

La auditoría del 21–22/ago/2026 declaró su propio límite así: **«nadie ejecutó una sola
pantalla en un navegador»**. Sus cuatro hallazgos del front eran lectura de código, no
comportamiento observado, y por eso quedaron sin arreglar: *hay que probarlos antes*.

Al ejecutarlos (24/ago/2026), **tres eran reales y uno no se reprodujo**. Ninguno de los tres
se veía leyendo el código con cuidado: los tres son carreras que sólo aparecen con el wifi
lento, que es la condición normal del taller.

## Las tres reglas de este arnés

1. **No copia la pantalla: la EXTRAE.** `armar.sh` genera el HTML desde `docs/index.html`
   en cada corrida y agrega **una sola línea** (la que carga `stub.js`), y después comprueba
   con `diff` que ésa sea la única diferencia. Si no coincide, falla. Una copia se
   desincronizaría, que es el patrón #1 del `README.md` de al lado.
2. **Nunca toca la API real.** `stub.js` reemplaza `window.fetch` antes de que corra el
   script de la app. No hay forma de que una prueba mueva un carro de producción.
3. **Tiene que ir por `http://`, no `file://`.** `history.pushState` truena en `file://`, y
   el back del teléfono —que es de lo que se prueba— vive justo ahí. Por eso el `servidor.ps1`.

## Las perillas del `stub.js` (`window.LAB`)

| Perilla | Qué simula |
|---|---|
| `LAB.retraso = 1500` | el wifi del taller: cada respuesta tarda |
| `LAB.colgado = true` | wifi **COLGADO**: la conexión se abre y **nunca** contesta |
| `LAB.falla = true` | el backend responde 500 |
| `LAB.log` | qué rutas se pidieron (para contar subidas de foto) |

> ⚠️ **Colgado y caído no son lo mismo, y ahí vivía un bug.** Caído = `fetch` rechaza de
> inmediato. Colgado = nunca contesta y sólo lo mata el corte de 20 s. Para probar el caído
> hay que reemplazar `window.fetch` por uno que rechace; el `stub.js` no trae perilla porque
> es una línea y conviene que se vea lo que se está simulando.

## Lo medido el 24/ago/2026 — antes y después

| # | Qué | Antes | Después |
|---|---|---|---|
| 1 | Cerrar el desglose antes de que llegue la respuesta | `detalleTimer = 21` con la pantalla en `display:none` | `null` |
| 2 | ⓘ del carro A → atrás → ⓘ del carro B (wifi a 15 s) | **5 repintados del carro A** en la pantalla abierta para B | 1 repintado, del carro correcto |
| 3 | Tres aperturas en vivo en vuelo, luego un desglose **estático** | **8 repintados en 3 s** con `detalleTimer` en `null` (timers inalcanzables) | 2 (los esperados: «Cargando…» + el pintado) |
| 4 | Wifi **colgado**, 85 s, 22 peticiones abortadas | banner **nunca**, `fallosSeguidos` en **0** | banner a los **31 s** |
| 5 | Control: wifi **caído** | banner a los ~12 s | igual (no se tocó) |
| 6 | Control: parpadeo de 2.5 s y después wifi bueno | — | el aviso **no** se enciende (la falla vieja no miente al revés) |
| 7 | «Tomar foto otra vez» sobre un carro que ya tiene foto | **0 subidas**, la foto borrada de la cola | 1 subida |
| 8 | Control: candado #4 (primera foto que ya subió) | 0 subidas, descartada | igual (no se rompió) |
| 9 | 440 pasos fuzzeados (clics reales + back al azar), pila de pantallas | 0 violaciones | 0 violaciones |

## El fuzzer de la pila de pantallas

Es lo que se usó para **descartar** el hallazgo de «el supervisor queda atrapado en
Finalizados». Toca botones al azar y presiona el back del teléfono, comprobando después de
cada paso una invariante:

- **ATRAPADO** — hay una pantalla encima y `cerradores` está vacío: el back no puede cerrarla.
- **BACK-MUERTO** — no hay nada encima pero `cerradores` cree que sí: el back no hace nada.

Sólo toca elementos que de verdad estén **hasta arriba** (se comprueba con
`document.elementFromPoint`), para que un `.click()` equivalga a un dedo. Y sólo presiona
back cuando hay algo que cerrar: con la pila vacía el back sale de la app, que es correcto.

El código del fuzzer está en el historial de la sesión del 24/ago; no se guardó como archivo
porque se pega en la consola y se ajusta según lo que se busque.

> ⚠️ **Esto NO va en `pruebas/correr.sh`.** No hay `node` ni `deno` en esta máquina, así que
> no se puede manejar un navegador sin una persona. Se corre **cuando se toque
> `docs/index.html`**, igual que `respaldo-completo.sh` se corre cuando se toca `/respaldo`.

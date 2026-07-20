# Pendientes por hacer — se trabajan DESPUÉS del cierre (8 PM)

> Este archivo es la bandeja de entrada. Nada de aquí se toca mientras el autolavado esté
> abierto: cualquier despliegue a medio turno le puede tumbar la app al supervisor.
> Cuando algo se hace, se mueve al `CLAUDE.md` con su razón y se borra de aquí.

## Pedidos del dueño (20/jul/2026)

_(pendiente de dictar — se van anotando conforme los diga)_

## Detectado al revisar el día (20/jul/2026, mediodía)

- [ ] **"Saul de Anda" sale como "Saul de" en la grilla.** El nombre corto parte por espacios
      y se queda con la preposición. Es el único de los 18 con el problema; los apellidos
      compuestos (`de`, `del`, `la`) hay que saltarlos al armar `mostrar`.
      Cosmético, pero es un nombre de persona en la pantalla donde el supervisor la escoge.

- [ ] **Verificar el congelado de las 8:30 PM.** Hoy es la primera noche con el horario
      nuevo (`30 3,4 * * *` UTC + guardia de hora local 20). El cron está activo. Mañana:
      `select fecha, congelado_en from reportes_diarios order by fecha desc limit 2`
      y confirmar que existe la fila del 20/jul.

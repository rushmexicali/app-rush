# Volver a leer la foto de un carro (recuperar placa/marca/submarca)

Sirve cuando un carro **tiene foto pero la lectura nunca corrió** — típicamente porque
Anthropic se cayó o tardó, y `/foto` (con razón) no escribe nada cuando no hubo lectura.
Ese caso se ve así en la base:

```sql
select id, foto_path from carros
where foto_path is not null and placa_en is null and not es_prueba;
```

`placa_en` **nulo** = *nunca se intentó*. Con fecha y `placa` vacía = *sí se intentó y no se
pudo* (ésos NO hay que reintentar: la foto no muestra la placa).

Se usó por primera vez el 19/ago/2026 para recuperar 24 carros, 17 de ellos de una caída de
100 minutos el 17/ago. Ver `CLAUDE.md §11.60`.

## Cómo se corre

```bash
bash scripts/releer-fotos/releer.sh <carro_id> <foto_path>              # lee y GUARDA
bash scripts/releer-fotos/releer.sh <carro_id> <foto_path> --solo-leer  # lee y no escribe
```

En lote, con la lista que sale de la consulta de arriba:

```bash
while read -r id path; do bash scripts/releer-fotos/releer.sh "$id" "$path"; done < lista.txt
```

Necesita `.env` con `SUPABASE_URL`, `SUPABASE_SECRET_KEY`, `SUPABASE_ACCESS_TOKEN`,
`SUPABASE_PROJECT_REF` y `ANTHROPIC_API_KEY`. Corre en Git Bash (usa `gawk`, `base64` y
`curl.exe`).

## Las tres reglas que lo hacen fiel a la app (no romperlas)

1. **El prompt NO se copia aquí: se extrae de `supabase/functions/app/index.ts`** en cada
   corrida, del template literal `INSTRUCCION_FOTO`. Si se copiara, habría dos versiones de la
   misma regla y se desincronizarían en silencio — el error que este proyecto ya cometió varias
   veces. `parte1.json` sí repite el modelo y el esquema; **si cambian en el `.ts`, hay que
   cambiarlos aquí.**
2. **Las reglas de aceptación las aplica Postgres sobre la respuesta cruda**, no un parser
   nuevo: placa sólo si `placa_legible`, organización sólo si hubo placa, tipo sólo si es uno de
   los cuatro válidos. Igual que el `.ts`.
3. **Se escribe con `guardar_datos_de_foto`**, la misma RPC del supervisor y de la caja. Ahí
   viven el candado de placa repetida del día (migración `100`) y el ligado placa→cliente.

## Antes de correrlo en lote

- **Valídalo con un carro de control** que ya tenga lectura, con `--solo-leer`, y compara.
- **Después, revisa placas repetidas** de los días tocados:
  `select placas_repetidas_del_rango('<dia>','<dia>');`
- **Si el día ya estaba congelado**, re-congélalo conservando `congelado_en`:
  `update reportes_diarios set datos = reporte_del_dia(fecha) where fecha in (...)`.
  Saca el diff campo por campo antes: lo único que debe cambiar es el bloque `placas`.

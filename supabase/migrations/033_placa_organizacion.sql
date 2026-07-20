-- =====================================================================
-- RUSH Car Wash — de que organizacion es la placa
--
-- En Mexicali circulan muchos autos de procedencia extranjera con placa
-- de ASOCIACION CIVIL (ONAPPAFA, ANAPROMEX, AMLOPAFA, CONDEFA, CODEFA,
-- APROFAM, APROFA, UCD...). No son placas oficiales: cada organizacion
-- imprime la suya, con su nombre y un numero de afiliacion.
--
-- Por que una columna aparte y no pegarlo dentro de "placa":
--
-- 1. El numero es el identificador. Si se guardara "ONAPPAFA 72973", el
--    mismo carro fotografiado otro dia con el letrero tapado se guardaria
--    como "72973" y el historial lo contaria como DOS vehiculos distintos.
--    normalizar_placa() no puede arreglar eso: no sabe que "ONAPPAFA" es
--    un prefijo y no parte del numero.
--
-- 2. Dos organizaciones si pueden repetir numero. Cuando eso pase, esta
--    columna es lo unico que los distingue.
--
-- Se llena SOLA desde la Edge Function `app`, y solo cuando el modelo
-- alcanza a leer el letrero. Queda NULL en:
--   - placas oficiales (mexicanas y de Estados Unidos), que es lo normal
--   - placas de asociacion donde el letrero no se alcanzo a leer
--
-- Ese segundo caso se espera seguido: en la primera foto real que se
-- analizo (carro 68), el nombre de la organizacion estaba tapado por el
-- MARCO del portaplacas — uno de agencia Ford — y no se pudo leer ni
-- ampliando la imagen 14 veces. El numero si se leyo perfecto. Por eso la
-- placa NUNCA depende de esta columna: es dato extra, no requisito.
-- =====================================================================

alter table public.carros
  add column if not exists placa_organizacion text;

comment on column public.carros.placa_organizacion is
  'Asociacion civil que emitio la placa (ONAPPAFA, ANAPROMEX...), si se alcanzo a leer. NULL en placas oficiales.';

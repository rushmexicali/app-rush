// Prueba de `marcarError` — la funcion que hace que un error se vea como error.
//
// NO trae una copia de la funcion: la EXTRAE de
// supabase/functions/app/index.ts en cada corrida y le quita las anotaciones
// de tipo. Si alguien la cambia alla, esta prueba corre la version nueva. Una
// copia seria justo el error que esta prueba existe para atrapar.
//
// Correr:  cscript //E:JScript //Nologo pruebas\marcar-error.js
// Sale con codigo 1 si algo falla, para que se pueda encadenar.

var fso = new ActiveXObject("Scripting.FileSystemObject");
var aqui = fso.GetParentFolderName(WScript.ScriptFullName);
var raiz = fso.GetParentFolderName(aqui);
var rutaTs = fso.BuildPath(raiz, "supabase\\functions\\app\\index.ts");

if (!fso.FileExists(rutaTs)) {
  WScript.Echo("FALLA: no encuentro " + rutaTs);
  WScript.Quit(1);
}

var texto = fso.OpenTextFile(rutaTs, 1).ReadAll();
var m = texto.match(/function marcarError[\s\S]*?\n\}/);
if (!m) {
  WScript.Echo("FALLA: no pude extraer marcarError de index.ts (cambio de forma?)");
  WScript.Quit(1);
}

// Quitar lo que solo entiende TypeScript. Es el mismo despojo que hace el
// empaquetador al desplegar.
var fuente = m[0]
  .replace(/: unknown/g, "")
  .replace(/: number/g, "")
  .replace(/: Record<string, unknown>/g, "")
  .replace(/ as Record<string, unknown>/g, "")
  .replace(/\bconst\b/g, "var")
  .replace(/\blet\b/g, "var");

// El interprete de Windows es viejo y no trae estas dos. Se rellenan AQUI, en
// el arnes, y nunca en el codigo de produccion: Deno si las tiene, y degradar
// el codigo real para acomodar la prueba seria tener el arnes al reves.
if (!Array.isArray) {
  Array.isArray = function (v) { return Object.prototype.toString.call(v) === "[object Array]"; };
}
if (!Object.keys) {
  Object.keys = function (o) {
    var r = [];
    for (var k in o) { if (Object.prototype.hasOwnProperty.call(o, k)) r.push(k); }
    return r;
  };
}

eval(fuente);

var fallos = 0, total = 0;
function caso(nombre, real, esperado) {
  total++;
  var r = ver(real), e = ver(esperado);
  if (r === e) {
    WScript.Echo("  ok    " + nombre);
  } else {
    fallos++;
    WScript.Echo("  FALLA " + nombre + "\n          salio: " + r + "\n          esper: " + e);
  }
}
// JScript no trae JSON, y ademas hay que comparar el ORDEN de las llaves.
function ver(v) {
  if (v === null) return "null";
  if (v === undefined) return "undefined";
  if (typeof v !== "object") return typeof v + ":" + v;
  if (v instanceof Array) {
    var p = [];
    for (var i = 0; i < v.length; i++) p.push(ver(v[i]));
    return "[" + p.join(",") + "]";
  }
  var q = [], k = Object.keys(v);
  for (var j = 0; j < k.length; j++) q.push(k[j] + "=" + ver(v[k[j]]));
  return "{" + q.join(",") + "}";
}

WScript.Echo("marcarError - un error tiene que verse como error");

// --- Lo que HOY no trae la marca y debe empezar a traerla ---------------
caso("500 con mensaje de Postgres (32 rutas)", marcarError({ error: "boom" }, 500), { error: "boom", ok: false });
caso("405 usa POST (14 rutas)",                marcarError({ error: "usa POST" }, 405), { error: "usa POST", ok: false });
caso("404 ruta desconocida",                   marcarError({ error: "ruta desconocida" }, 404), { error: "ruta desconocida", ok: false });
caso("401 codigo incorrecto",                  marcarError({ error: "Codigo incorrecto" }, 401), { error: "Codigo incorrecto", ok: false });
caso("503 sin codigo configurado",             marcarError({ error: "El servidor no tiene codigo configurado" }, 503), { error: "El servidor no tiene codigo configurado", ok: false });
caso("400 falta desde",                        marcarError({ error: "falta desde" }, 400), { error: "falta desde", ok: false });

// --- Lo que ya estaba bien: no se toca ----------------------------------
caso("la ruta ya dijo ok:false",               marcarError({ ok: false, error: "x" }, 400), { ok: false, error: "x" });

// --- Lo bueno NUNCA se marca -------------------------------------------
caso("200 de /cola",                           marcarError({ carros: [] }, 200), { carros: [] });
caso("200 de /foto con ok:true",               marcarError({ ok: true, camino: "a/b" }, 200), { ok: true, camino: "a/b" });
caso("204 y 3xx tampoco",                      marcarError({ algo: 1 }, 302), { algo: 1 });

// --- Formas raras: ni revientan ni cambian ------------------------------
caso("cuerpo nulo con 500",                    marcarError(null, 500), null);
caso("arreglo con 500",                        marcarError([1, 2], 500), [1, 2]);
caso("texto suelto con 500",                   marcarError("boom", 500), "boom");

// --- El caso que obliga a asignar `ok` DESPUES de copiar ----------------
// Si la llave ya venia (aunque fuera indefinida), conserva su POSICION en el
// objeto; lo que importa es que el valor quede en false. El orden de las
// llaves de un JSON no le importa a ninguna de las tres pantallas.
caso("llave ok presente pero indefinida",      marcarError({ ok: undefined, error: "x" }, 500), { ok: false, error: "x" });

WScript.Echo("");
if (fallos === 0) {
  WScript.Echo("TODAS PASARON (" + total + " casos)");
  WScript.Quit(0);
} else {
  WScript.Echo(fallos + " DE " + total + " FALLARON");
  WScript.Quit(1);
}

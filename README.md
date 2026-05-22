# Work Metrics

Genera un dashboard local de rendimiento usando tu usuario de GitHub autenticado con `gh` y los repos Git bajo el directorio indicado. No requiere servidor: genera un HTML autocontenido que se abre directo en el navegador.

## Uso

```powershell
powershell -ExecutionPolicy Bypass -File .\build-dashboard.ps1 -OpenReport
```

Opciones utiles:

```powershell
# Cambiar periodo
powershell -ExecutionPolicy Bypass -File .\build-dashboard.ps1 -Periods "30,90,180,365"

# Cambiar raiz de repositorios
powershell -ExecutionPolicy Bypass -File .\build-dashboard.ps1 -Root C:\source\repos

# Forzar usuario de GitHub
powershell -ExecutionPolicy Bypass -File .\build-dashboard.ps1 -User octocat

# Abrir el reporte HTML al terminar
powershell -ExecutionPolicy Bypass -File .\work-metrics.ps1 -Days 30 -OpenReport
```

## Salidas

- `out/dashboard.html`: dashboard autocontenido.
- `out/work-metrics.md`: ultimo reporte Markdown generado.
- `out/work-metrics.json`: ultimos datos crudos generados.

El directorio `out/` contiene datos reales del usuario y esta ignorado por Git.

## Que mide

- Repositorios locales detectados.
- Commits locales del periodo.
- Lineas agregadas, eliminadas y archivos modificados segun `git log --numstat`.
- Dias activos, primer/ultimo commit local y dia con mas actividad.
- Evolucion diaria, semanal y mensual.
- Racha maxima de dias activos, semanas activas y consistencia.
- Hora pico, porcentaje en horario laboral, commits fuera de horario y commits de fin de semana.
- PRs creados, revisados e involucrados segun GitHub Search.
- PRs mergeados, mediana de horas hasta merge y porcentaje de PRs mergeados en menos de 24h.
- Issues creados, cerrados e involucrados segun GitHub Search.
- Conversaciones comentadas por el usuario.

## Limitaciones

GitHub no expone tiempo trabajado real. Las metricas de tiempo son aproximaciones basadas en actividad observable, como dias con commits y ventana de actividad. Las lineas modificadas pueden incluir archivos generados si el repo los versiona.

Las metricas de equipo, ranking o score no se calculan porque requieren acceso uniforme a todos los repos y a todos los usuarios. Esta herramienta prioriza metricas propias para evitar comparaciones incompletas o sesgadas.

## Seguridad

El script no guarda tokens ni credenciales. Usa `gh` y la sesion autenticada localmente.

No versionar el directorio `out/`: puede incluir usuario, ruta local, nombres de repos, URLs/titulos de PRs e issues, commits y emails de autor. Para publicar la herramienta, trackear solo `work-metrics.ps1`, `README.md` y `.gitignore`.

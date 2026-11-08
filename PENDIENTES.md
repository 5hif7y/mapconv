# Pendientes por prioridad (estado 10 nov)

Cobertura: 85,05 % interno (4.531.036.947 B) / **90,93 %** incluyendo mips
streamed. `mapconv` = b5fb97a. Sin motor no queda nada bloqueado por código.

## P0 — Correctitud visual (antes de seguir con cobertura)

1. **Geometría de props**: los 275 `.mdl` pesan 1,6–2,7 KB. Verificar `.vvd`
   (vértices) y `.vtx` (índices); `build_map.sh` descarta hoy los errores de
   `studiomdl` con `|| true`, así que un modelo vacío pasaría inadvertido.
2. **UVs de props**: las superficies suaves/checker apuntan a magnificación
   extrema; revisar `uaxis`/`vaxis` (escala 2.54 cm/unidad) contra la textura.
3. **Skybox**: caras de cubemap de 64² y orientación 2D; decidir si se corrige
   el mapeo o se usa un `sky_day01_01` neutro del VPK.

## P1 — Cobertura de bytes (objetivo 90 % interno)

4. **`StaticMeshComponent`** (709 MB, 1,9 %): sin `StaticMeshComponent.cpp` en
   el SDK. Vías: obtener esa fuente (o UDK equivalente) o una muestra de otro
   build 576; sin eso, no se escribe lector. Es el único bloque que impide el
   90 % interno (faltan ~266 MB).
5. **`Level`** (3,2 MB): `UnLevel.cpp` disponible; hoy se consumen 12 B.
6. **`BrushComponent`** (5,3 MB) y **`SpeedTree`** (12,6 MB): bloqueados por
   tipos ausentes (`FCachedPhysBrushData`) y licencia.

## P2 — Assets y formatos

7. **Materiales de partículas** (5 ausentes) y blend modes UE3
   (aditivo/translúcido) → shader VMT correcto.
8. **Test de regresión LZO multi-bloque** con un slice real de `_art` o un
   fixture sintético de ≥2 bloques.
9. **Documentar** en `docs/formats/ue3-package.md` el layout del chunk
   comprimido (tabla de bloques contigua + streams) y el fix de hoy.

## P3 — Infraestructura e informe

10. `build_map.sh`: no silenciar `studiomdl`; reportar fallos y contar `.vvd`.
11. Harness: guardar fixtures `(pos, ang)` por mapa y comparar capturas.
12. Actualizar `REPORT.md` (cobertura, LZO multi-bloque, estado visual).

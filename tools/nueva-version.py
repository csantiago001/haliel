#!/usr/bin/env python3
"""Marca una versión nueva de Haliel antes de publicar.

Actualiza el mismo número en index.html (APP_VERSION y meta), sw.js y version.json.
Las páginas abiertas comparan su número con version.json cada minuto y se recargan solas.

Uso:  python3 tools/nueva-version.py            → AAAA.MM.DD.N (N sube si ya hubo publicación hoy)
      python3 tools/nueva-version.py 2026.11.01.1
"""
import datetime, json, pathlib, re, sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent
actual = json.loads((RAIZ / 'version.json').read_text())['version'] if (RAIZ / 'version.json').exists() else ''
if len(sys.argv) > 1:
    nueva = sys.argv[1]
else:
    hoy = datetime.date.today().strftime('%Y.%m.%d')
    n = int(actual.rsplit('.', 1)[1]) + 1 if actual.startswith(hoy + '.') else 1
    nueva = f'{hoy}.{n}'

def cambiar(archivo, patron, reemplazo):
    p = RAIZ / archivo
    texto = p.read_bytes().decode('utf-8')
    nuevo, cuantos = re.subn(patron, reemplazo, texto)
    if not cuantos:
        sys.exit(f'No se encontró la versión en {archivo}')
    p.write_bytes(nuevo.encode('utf-8'))

cambiar('index.html', r"const APP_VERSION = '[^']*'", f"const APP_VERSION = '{nueva}'")
cambiar('index.html', r'<meta name="haliel-version" content="[^"]*"/>', f'<meta name="haliel-version" content="{nueva}"/>')
cambiar('sw.js', r"const VERSION = '[^']*'", f"const VERSION = 'haliel-{nueva}'")
(RAIZ / 'version.json').write_text(json.dumps({'version': nueva}) + '\n')
print(f'{actual or "(sin versión)"} → {nueva}')

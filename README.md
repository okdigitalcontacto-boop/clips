# Clips

**© 2026 OK Digital. Todos los derechos reservados.**

Clips saca los mejores momentos de un vídeo de YouTube y te los da montados. Los recorta en frases completas, los pone en vertical siguiendo la cara de quien habla y les añade subtítulos palabra a palabra, título de gancho y música de fondo. Hay versión para **Mac** (Swift/SwiftUI) y para **Windows** (Python con ventana WebView2). Las dos hacen lo mismo y se ven igual.

## Descargar para Windows

1. En [Releases](../../releases), descarga `Clips-Windows-x64.zip` y descomprímelo.
2. Abre `Clips.exe`. Si sale «Windows protegió su PC», pulsa **Más información** → **Ejecutar de todas formas**. Sale porque la app no está firmada.
3. Pulsa el engranaje → **Clave de Gemini** → pega la clave → **Probar**.

Requisitos: Windows 10 u 11 de 64 bits. yt-dlp, ffmpeg y Deno ya vienen dentro, en la carpeta `bin`.

## Clave de Gemini (gratis)

1. Entra en https://aistudio.google.com/apikey con tu cuenta de Google.
2. Pulsa **Create API key** y copia la clave.
3. Pégala en los Ajustes de Clips (⌘, en Mac; Ctrl+, en Windows).

La clave se guarda solo en tu equipo y nunca va en este repositorio.

## Cómo se usa

1. Copia el enlace de un vídeo de YouTube y abre Clips: lo pega solo. También puedes arrastrarlo a la ventana.
2. Elige:
   - cuántos clips y su duración;
   - horizontal o vertical;
   - qué añadir: subtítulos, título al inicio y música en Calma o Energía;
   - qué buscar: Automático, Tensión, Humor, Aprendizaje, Emoción o Polémica.
3. Opcional: escribe en **Notas** lo que quieras, por ejemplo «10 en orden cronológico» o «está en 5 partes, uno de cada». Las notas mandan sobre el número de clips y el orden.
4. Pulsa **Sacar clips** (⌘↩ / Ctrl+Intro). Esc cancela.
5. Cuando un clip está listo puedes:
   - verlo;
   - retocar el inicio y el final medio segundo cada vez y volver a montarlo;
   - copiar su texto para redes;
   - pulsar **Subir**: se abre la página de subida de YouTube, Instagram o TikTok, el texto queda copiado y el archivo aparece en la carpeta para arrastrarlo.

Los clips se guardan en `Películas/Clips` (Mac) o en `Vídeos\Clips` (Windows). La carpeta se puede cambiar en Ajustes.

## Cómo funciona

- **Texto:** salen de YouTube los subtítulos con el tiempo de cada palabra. Si el vídeo no tiene, Gemini transcribe el audio.
- **Elección en varias pasadas con Gemini:**
  1. Candidatos.
  2. Revisión con contexto: el inicio se entiende solo, el final remata, es una sola situación y el título es cierto.
  3. Corte en frases completas, hecho en código.
  4. Verificación final, con hasta 2 rondas de corrección. Solo se entrega lo que pasa.
- **Notas:** Gemini las convierte en un plan. El código hace cumplir el número, el orden y que haya uno de cada parte.
- **Cámara:** sigue caras y, si no caben todas, a quien mueve la boca. Va con inercia y sin temblar. En los cambios de plano solo salta si hace falta. Si no hay a quien seguir, muestra el plano entero sobre un fondo difuminado.
- **Subtítulos:** Gemini corrige el texto palabra a palabra y el código agrupa las líneas. La palabra que se dice lleva una pastilla coral.
- **Audio:** la música la compone la app para cada clip, sin derechos de terceros, o usa tu carpeta de canciones. Baja sola cuando se habla. El volumen final queda en -14 LUFS.
- **Modelos:** `gemini-3.8-flash`. Si está saturado, entran los siguientes de reserva.

## Estructura

```
mac/        App de Mac (Swift/SwiftUI, AVFoundation, Vision)
  build.sh  ./mac/build.sh  →  ~/Desktop/Clips.app   (macOS 14+, brew install yt-dlp ffmpeg)
windows/    App de Windows (Python 3.12)
  clips/    core.py (Gemini y elección de momentos), render.py (cámara, subtítulos, montaje),
            music.py (compositor), app.py (orquestador y ventana), util.py, selftest.py
  ui/       Interfaz (HTML/CSS/JS, sin dependencias externas)
  assets/   Icono, fuentes Inter y Nunito (OFL), modelo de caras YuNet (MIT)
  clips.spec, build.ps1, requirements.txt
.github/workflows/windows.yml   Compila Clips.exe en Windows, lo prueba y lo publica
```

### Compilar Windows

En GitHub se hace solo: cada `push` a `main` deja `Clips-Windows-x64.zip` en la pestaña **Actions**, y cada etiqueta `vX.Y.Z` lo publica en **Releases**. En un PC con Windows y Python 3.12: `powershell -ExecutionPolicy Bypass -File windows/build.ps1`.

Pruebas:

```
Clips.exe --selftest --log prueba.txt           # sin internet: herramientas + montaje de punta a punta
Clips.exe --test <enlace> [nº] [--horizontal] [--sin-subtitulos] [--dur 0|1|2] [--notas "texto"] --log salida.txt
```

En el Mac se puede probar la versión de Windows con `python windows/main.py` (necesita las mismas bibliotecas y `brew install yt-dlp ffmpeg deno`).

## Licencia

Software propietario. © 2026 OK Digital. Todos los derechos reservados. Consulta [LICENSE](LICENSE). Los componentes de terceros tienen su propia licencia: consulta [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

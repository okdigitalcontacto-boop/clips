# Clips

App de Mac que saca los mejores momentos de un vídeo de YouTube y te los da montados: recortados en frases completas, en vertical siguiendo la cara y con subtítulos palabra a palabra.

## Cómo se usa

1. Copia el enlace de un vídeo de YouTube y abre Clips (lo pega solo) o arrástralo a la ventana.
2. Elige cuántos clips, la duración, horizontal o vertical, qué añadir (subtítulos, título al inicio, música en Calma o Energía) y qué buscar (Automático, Tensión, Humor…).
   Opcional: escribe en **Notas** lo que quieras, por ejemplo «saca 10 en orden cronológico», «está estructurado en 5 partes, uno de cada parte» o «solo cuando habla de dinero». Las notas mandan sobre el número de clips.
3. Pulsa **Sacar clips** (⌘↩). Cancelar: **Esc**.
4. Los clips van apareciendo en la cuadrícula y en la línea de tiempo del vídeo. Clic para verlo, retocar inicio y final (medio segundo cada vez) y volver a montarlo. Puedes arrastrar cualquier clip a otra app o al Finder.
5. Se guardan en `Películas/Clips/<título del vídeo>/` (se cambia en Ajustes, ⌘,).

## Clave de Gemini (gratis)

1. Entra en https://aistudio.google.com/apikey con tu cuenta de Google.
2. Pulsa **Create API key** y copia la clave.
3. En Clips: **Ajustes (⌘,) → Clave de Gemini**, pégala y pulsa **Probar**.

## Cómo funciona

- `yt-dlp -J` lee el vídeo; el texto con tiempos sale de los subtítulos de YouTube (los automáticos traen el tiempo de cada palabra). Si no hay subtítulos, Gemini transcribe el audio.
- Notas: Gemini las convierte en un plan (número, orden, partes con su inicio y final, otras reglas). El código hace cumplir número, orden y partes: la parte de cada clip la decide dónde cae (al menos el 80 % dentro; si cruza a otra parte, fuera) y se queda el mejor de cada una. Si una parte se queda sin clip, se busca otra vez solo en ella. Las demás reglas van a cada pasada y la verificación final comprueba que se cumplen. Si al final falta alguna parte, se avisa de cuál.
- Elección de momentos en varias pasadas (Gemini):
  1. Candidatos (los pedidos + 5 de reserva) con la transcripción, capítulos y la curva de "lo más repetido".
  2. Revisión clip a clip con 45 s de contexto antes y 30 s después: una sola situación, inicio que se entiende solo, final con remate, título y texto ciertos; corrige inicio y final palabra a palabra o descarta.
  3. Seguro en código: inicio y final en frases completas (puntuación o pausas); si no cabe en la duración (+30 %), fuera.
  4. Verificación final con lo de justo antes y justo después; lo que falla vuelve al editor con el problema concreto (hasta 2 rondas). Solo se entrega lo que pasa; si pasan menos de los pedidos, se avisa.
- Subtítulos: Gemini corrige palabra a palabra (mal oído, mayúsculas, tildes, signos, muletillas) y el código agrupa las líneas siempre igual (frases, comas, pausas; nunca acaban en "a/de/que…"; no parte nombres ni cifras).
- Calidad de imagen: en vertical se descarga 1440p cuando existe (el recorte 9:16 gana un 33 % de detalle) y se escala con Lanczos + enfoque suave.
- Modelos: `gemini-3.8-flash`; si está saturado o tarda más de 40 s entra el siguiente (`3.6`, `3.5`, `3.5-flash-lite`), con hasta 3 rondas de reintento.
- Solo se descarga el trozo de cada clip (más 6 s de margen), 3 a la vez.
- Música: Clips compone un tema distinto para cada clip (acordes, bajo, batería suave y arpegio; sin derechos de terceros) o usa tus canciones si eliges carpeta en Ajustes. Baja sola cuando se habla (~14 dB bajo la voz) y sube en las pausas (~9 dB), con entrada y salida suaves.
- Título de gancho: tarjeta blanca arriba los primeros 3 s.
- Volumen final a -14 LUFS (TikTok, Reels, Shorts), medido en dos pasadas.
- El montaje es nativo (AVFoundation + Core Image, fotograma a fotograma): recorte exacto, subtítulos y título dibujados como imagen.
- Cámara: sigue caras (el grupo si cabe; si no, a quien mueve la boca) y personas, con inercia y sin temblar; salta al instante en los cambios de plano (detectados con ±6 centésimas). Planos sin nadie a quien seguir (dibujos, pantallas) o con grupos de 3+ que no caben: plano entero sobre fondo difuminado. Zoom lento dentro de cada plano y golpe de zoom en los momentos más fuertes del audio.
- Antes se usaban capas de Core Animation para el texto, pero con la ventana animándose no se pintaban (por eso no salían subtítulos al usar la app).

## Requisitos

- macOS 14 o posterior.
- `brew install yt-dlp ffmpeg`. Si YouTube cambia algo, la app ofrece **Actualizar yt-dlp** (`brew upgrade yt-dlp`).

## Compilar

```
./build.sh            # deja Clips.app en el Escritorio
```

Pruebas sin ventana:

```
Clips.app/Contents/MacOS/Clips --test <enlace> [nº clips] [--horizontal] [--sin-subtitulos] [--dur 0|1|2] [--notas "texto"]
Clips.app/Contents/MacOS/Clips --test <enlace> 3 --cancelar   # cancela en plena descarga y mide cuánto tarda en pararse
Clips.app/Contents/MacOS/Clips --detail-test                    # abre el detalle de un clip en una ventana real (antes se caía)
Clips.app/Contents/MacOS/Clips --snapshot salida.png [--dark] [--running]   # captura de la interfaz con datos de muestra
```

## Archivos

- `Core.swift`: yt-dlp, transcripción, Gemini, elección y ajuste de momentos.
- `Render.swift`: descarga por trozos, seguimiento de cara, subtítulos y exportación.
- `Music.swift`: compositor de música de fondo y ajuste final de volumen.
- `Sound.swift`: sonidos sintetizados (sin archivos) y toques hápticos.
- `App.swift`: orquestador, estado y modos de prueba.
- `UI.swift`: interfaz SwiftUI.
- `icon.swift`: genera el icono.

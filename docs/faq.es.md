[English](faq.md) | [简体中文](faq.zh-CN.md) | [繁體中文](faq.zh-TW.md) | [日本語](faq.ja.md) | **Español** | [Français](faq.fr.md) | [Русский](faq.ru.md)

# Preguntas frecuentes

### ¿Por qué macOS bloquea el primer arranque?

La app usa un certificado autofirmado, sin firma Developer ID ni notarización de Apple. Permítela una vez en Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente, o ejecuta `xattr -d com.apple.quarantine /Applications/Bowerbird.app`.

### ¿Por qué pide Accesibilidad?

Para pulsar ⌘V en la app de la que vienes cuando pulsas Retorno. Lo pide la primera vez que pegas. Sin ese permiso, Retorno copia y pegas tú.

### He concedido Accesibilidad, pero Retorno no pega.

El permiso va ligado a la firma de la app, y el interruptor puede aparecer activado aunque corresponda a una firma antigua. En Ajustes del Sistema → Privacidad y seguridad → Accesibilidad, elimina Bowerbird con «−» y vuelve a añadirla con «+».

### He retirado Accesibilidad, pero la app sigue diciendo que está concedido.

macOS no avisa a las apps que están abiertas. Cierra Bowerbird y vuelve a abrirla.

### ¿Necesita Grabación de pantalla o Acceso total al disco?

No. Las imágenes vienen del portapapeles y de los archivos solo se guarda la ruta.

### ¿Se conecta a internet?

No. Sin telemetría, sin comprobación de actualizaciones, sin sincronización.

### ¿Dónde están mis datos?

En `~/Library/Application Support/Bowerbird/`: una base de datos SQLite y archivos de imagen, sin cifrar. Los ajustes están en `defaults`, en `app.bowerbird.mac`.

### ¿Cómo lo borro todo?

Ajustes → Historial → Borrar → Todo elimina el historial; los elementos fijados tienen su propio botón Borrar en la fila de abajo. «Borrar al salir», en la misma pestaña, lo hace cada vez que cierras la app; los fijados se quedan. Para no dejar rastro, cierra la app y ejecuta:

```sh
rm -rf ~/Library/Application\ Support/Bowerbird
defaults delete app.bowerbird.mac
```

### ¿Qué no se registra nunca?

- Lo que un gestor de contraseñas marca como contraseña.
- Lo que se copia desde una app de la lista de ignoradas. 1Password, Bitwarden y Acceso a Llaveros están en ella por omisión.
- El texto que coincide con uno de tus patrones de exclusión.
- Lo que se copia mientras el registro está en pausa.

### ¿Cuánto tiempo se conserva el historial?

El texto y los archivos 30 días, las imágenes 7. Se cambia en Ajustes → Historial. Los elementos fijados se conservan siempre.

### ¿Por qué no aparecen mis capturas de pantalla?

Por omisión, macOS guarda la captura como archivo en el escritorio y no la pone en el portapapeles, así que Bowerbird no la ve. Pulsa ⌃⇧⌘4 para copiar la captura al portapapeles, o pulsa ⇧⌘5, abre Opciones y elige Portapapeles en «Guardar en».

### ¿Ve lo que copio en el iPhone o el iPad?

El texto y las imágenes, si la opción de Ajustes → Historial está activada. Los archivos no.

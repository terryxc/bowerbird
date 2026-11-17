[English](faq.md) | [简体中文](faq.zh-CN.md) | [繁體中文](faq.zh-TW.md) | [日本語](faq.ja.md) | [Español](faq.es.md) | **Français** | [Русский](faq.ru.md)

# Questions fréquentes

### Pourquoi macOS bloque-t-il le premier lancement ?

L’app utilise un certificat autosigné, sans signature Developer ID ni notarisation Apple. Autorisez-la une fois dans Réglages Système → Confidentialité et sécurité → Ouvrir quand même, ou exécutez `xattr -d com.apple.quarantine /Applications/Bowerbird.app`.

### Pourquoi demande-t-elle l’autorisation Accessibilité ?

Pour appuyer sur ⌘V dans l’app d’où vous venez quand vous appuyez sur Retour. Elle la demande la première fois que vous collez. Sans elle, Retour copie et vous collez vous-même.

### J’ai accordé Accessibilité, mais Retour ne colle pas.

L’autorisation est liée à la signature de l’app, et le commutateur peut sembler activé alors qu’il correspond à une ancienne signature. Dans Réglages Système → Confidentialité et sécurité → Accessibilité, supprimez Bowerbird avec « − » et rajoutez-la avec « + ».

### J’ai retiré Accessibilité, mais l’app indique toujours qu’elle est accordée.

macOS ne prévient pas les apps en cours d’exécution. Quittez Bowerbird et rouvrez-la.

### Faut-il Enregistrement de l’écran ou Accès complet au disque ?

Non. Les images viennent du presse-papiers, et seuls les chemins des fichiers sont enregistrés.

### Se connecte-t-elle à Internet ?

Non. Pas de télémétrie, pas de recherche de mises à jour, pas de synchronisation.

### Où sont mes données ?

Dans `~/Library/Application Support/Bowerbird/` : une base SQLite et des fichiers image, non chiffrés. Les réglages sont dans `defaults`, sous `app.bowerbird.mac`.

### Comment tout supprimer ?

Réglages → Historique → Effacer → Tout supprime l’historique ; les éléments épinglés ont leur propre bouton Effacer, sur la ligne du dessous. « Effacer en quittant », dans le même onglet, le fait à chaque fermeture de l’app ; les éléments épinglés restent. Pour ne laisser aucune trace, quittez l’app et exécutez :

```sh
rm -rf ~/Library/Application\ Support/Bowerbird
defaults delete app.bowerbird.mac
```

### Qu’est-ce qui n’est jamais enregistré ?

- Ce qu’un gestionnaire de mots de passe marque comme mot de passe.
- Ce qui est copié depuis une app de la liste des apps ignorées. 1Password, Bitwarden et Trousseaux d’accès y figurent par défaut.
- Le texte qui correspond à l’un de vos motifs à ignorer.
- Ce qui est copié pendant que l’enregistrement est en pause.

### Combien de temps l’historique est-il conservé ?

Le texte et les fichiers 30 jours, les images 7 jours. Cela se règle dans Réglages → Historique. Les éléments épinglés sont conservés indéfiniment.

### Pourquoi mes captures d’écran n’apparaissent-elles pas ?

Par défaut, macOS enregistre la capture dans un fichier sur le bureau et ne la place pas dans le presse-papiers ; Bowerbird ne la voit donc pas. Appuyez sur ⌃⇧⌘4 pour copier la capture dans le presse-papiers, ou appuyez sur ⇧⌘5, ouvrez Options et choisissez Presse-papiers sous « Enregistrer sous ».

### Voit-elle ce que je copie sur mon iPhone ou mon iPad ?

Le texte et les images, si l’option est activée dans Réglages → Historique. Pas les fichiers.

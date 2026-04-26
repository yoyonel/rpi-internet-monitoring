# Quality Score Indicators — Pastilles de qualité connexion

## Objectif

Fournir un indicateur visuel **at-a-glance** de la qualité de la connexion internet pour chaque métrique (Download, Upload, Ping) sur le dashboard GitHub Pages.

Chaque stat card affiche une **pastille à gradient de couleur continu** (vert → jaune → orange → rouge) calculée à partir d'un score composite qui combine deux dimensions :

1. **Performance** — la valeur absolue de la métrique est-elle bonne ?
2. **Stabilité** — les mesures sont-elles régulières dans le temps ?

## Deux dimensions orthogonales

### Performance (valeur absolue)

Évalue si la médiane des mesures sur la plage temporelle sélectionnée atteint les seuils attendus pour une connexion fibre 1 Gbps.

**Score performance** $p \in [0, 1]$ (0 = nominal, 1 = critique) :

Pour Download et Upload (plus = mieux) :

$$p = \text{clamp}\left(\frac{\text{seuil\_bon} - \text{médiane}}{\text{seuil\_bon} - \text{seuil\_mauvais}},\ 0,\ 1\right)$$

Pour Ping (moins = mieux, échelle inversée) :

$$p = \text{clamp}\left(\frac{\text{médiane} - \text{seuil\_bon}}{\text{seuil\_mauvais} - \text{seuil\_bon}},\ 0,\ 1\right)$$

### Stabilité (dispersion)

Évalue la régularité des mesures via le **coefficient de variation (CV)**.

**Score stabilité** $s \in [0, 1]$ (0 = parfaitement stable, 1 = très instable) :

$$s = \text{clamp}\left(\frac{CV - CV_{\text{bon}}}{CV_{\text{mauvais}} - CV_{\text{bon}}},\ 0,\ 1\right)$$

## Score composite

Les deux dimensions sont combinées avec une pondération qui privilégie la stabilité :

$$\text{score} = 0.3 \times p + 0.7 \times s$$

Le score final (0 = critique, 1 = parfait) est affiché en pourcentage : $\text{qualité} = 1 - \text{score}$.

### Justification de la pondération 30/70

La stabilité est pondérée plus fortement que la performance brute car :

- Une connexion rapide mais erratique est moins fiable qu'une connexion modérée mais constante
- Les variations de débit impactent davantage l'expérience utilisateur (streaming, visio) que le débit crête
- La performance pure est déjà visible via la valeur médiane affichée ; la pastille apporte une information complémentaire sur la _fiabilité_

## Seuils configurés

### Performance

| Métrique | Seuil vert (bon) | Seuil rouge (mauvais) | Direction     |
| -------- | ---------------- | --------------------- | ------------- |
| Download | ≥ 800 Mb/s       | ≤ 500 Mb/s            | Plus = mieux  |
| Upload   | ≥ 500 Mb/s       | ≤ 200 Mb/s            | Plus = mieux  |
| Ping     | ≤ 20 ms          | ≥ 50 ms               | Moins = mieux |

Ces seuils sont calibrés pour une **connexion fibre 1 Gbps** (Free/Orange). Ils devraient être ajustés si le type de connexion change.

### Stabilité (CV)

| Seuil            | CV           | Signification           |
| ---------------- | ------------ | ----------------------- |
| Vert (parfait)   | ≤ 0.05 (5%)  | Variation négligeable   |
| Rouge (instable) | ≥ 0.25 (25%) | Variation significative |

Ces seuils sont **universels** et indépendants de la métrique : un CV de 5% signifie la même chose que la valeur soit en Mb/s ou en ms.

## Mapping couleur (gradient HSL)

Le score composite est converti en teinte (hue) sur l'espace colorimétrique HSL :

$$\text{hue} = 120 \times (1 - \text{score})$$

$$\text{couleur} = \text{hsl}(\text{hue},\ 85\%,\ 50\%)$$

| Score | Hue  | Couleur résultante |
| ----- | ---- | ------------------ |
| 0.00  | 120° | Vert vif           |
| 0.25  | 90°  | Vert-jaune         |
| 0.50  | 60°  | Jaune              |
| 0.75  | 30°  | Orange             |
| 1.00  | 0°   | Rouge              |

L'avantage du gradient continu vs 3 paliers discrets : les nuances intermédiaires donnent un signal plus fin sans avoir à lire les chiffres.

## Outils statistiques utilisés

### Médiane

Valeur centrale d'un jeu de données trié. Plus robuste que la moyenne face aux outliers.

- Pour $n$ impair : $\text{med} = x_{\lfloor n/2 \rfloor}$
- Pour $n$ pair : $\text{med} = \frac{x_{n/2 - 1} + x_{n/2}}{2}$

Référence : [Wikipedia — Median](https://en.wikipedia.org/wiki/Median)

### Écart-type (σ) et variance

Mesure de dispersion des valeurs autour de la moyenne. On utilise la variance **corrigée** (diviseur $n - 1$, estimateur de Bessel) pour un échantillon :

$$\sigma = \sqrt{\frac{1}{n-1} \sum_{i=1}^{n} (x_i - \bar{x})^2}$$

Référence : [Wikipedia — Standard deviation](https://en.wikipedia.org/wiki/Standard_deviation#Corrected_sample_standard_deviation)

### Coefficient de variation (CV)

Rapport de l'écart-type sur la moyenne, exprimé en ratio (ou en %) :

$$CV = \frac{\sigma}{\bar{x}}$$

**Pourquoi le CV et pas l'écart-type seul ?**

Le CV est adimensionnel et permet de comparer la variabilité entre des métriques d'échelles différentes :

- Download σ = 5 Mb/s sur μ = 940 Mb/s → CV = 0.5% (très stable)
- Ping σ = 2 ms sur μ = 12 ms → CV = 16.7% (moyennement stable)

Sans le CV, on comparerait des pommes et des oranges.

Référence : [Wikipedia — Coefficient of variation](https://en.wikipedia.org/wiki/Coefficient_of_variation)

### Fonction clamp

Sature une valeur dans l'intervalle $[0, 1]$ :

$$\text{clamp}(x, 0, 1) = \max(0, \min(1, x))$$

Utilisée pour normaliser les scores intermédiaires avant la combinaison pondérée.

### Espace colorimétrique HSL

Hue-Saturation-Lightness — permet de faire varier uniquement la teinte (hue) pour créer un gradient perceptuellement linéaire du vert au rouge.

- Hue 120° = vert
- Hue 60° = jaune
- Hue 0° = rouge

Référence : [MDN — HSL](https://developer.mozilla.org/en-US/docs/Web/CSS/color_value/hsl)

## Tooltip détaillé

Au clic sur la pastille, un tooltip affiche le détail du calcul :

```
Excellent (100%)
Performance      100%
  médiane 941.8 Mb/s (vert ≥ 800, rouge ≤ 500)
Stabilité        100%
  CV = 0.006 (σ = 5.6 Mb/s, vert ≤ 5%, rouge ≥ 25%)
Pondération      30/70
  perf × 0.3 + stab × 0.7
```

### Labels de qualité

| Score  | Label     |
| ------ | --------- |
| ≥ 70%  | Excellent |
| 40–70% | Correct   |
| 20–40% | Dégradé   |
| < 20%  | Critique  |

## Pastille de synchronisation (navbar)

En complément des pastilles de qualité, une pastille dans la navbar indique la fraîcheur des données :

| Couleur | Condition        | Signification                             |
| ------- | ---------------- | ----------------------------------------- |
| Vert    | Données < 10 min | Pipeline de synchro RPi → GitHub Pages OK |
| Orange  | 10–20 min        | Synchro possiblement ratée (1 cycle)      |
| Rouge   | > 20 min         | Synchro en échec (2+ cycles ratés)        |

Le calcul compare le timestamp ISO 8601 injecté par `render-template.py` (`__LAST_UPDATE_ISO__`) avec `Date.now()` côté navigateur.

## Implémentation

- **`gh-pages/app.js`** — Fonctions `qualityScore()` et `qualityTooltipHtml()`, seuils dans `QUALITY_THRESHOLDS`
- **`gh-pages/style.css`** — Classes `.q-dot`, `.q-tip`, `.q-tip-grid`
- **`scripts/render-template.py`** — Placeholder `__LAST_UPDATE_ISO__` pour la pastille sync

### Paramètre de simulation

Le paramètre URL `?simAge=<minutes>` permet de simuler un âge de données pour tester la pastille de synchronisation sans attendre un vrai délai.

## Évolutions possibles

- Rendre les seuils configurables via un fichier JSON ou des variables d'environnement
- Ajouter un historique du score de qualité (trend sur 7j/30j)
- Alerter (via le système d'alertes existant) si le score passe sous un seuil configurable

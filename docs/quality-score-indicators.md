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

Évalue la régularité des mesures via l'**écart interquartile normalisé (IQR/médiane)**.

L'IQR (Interquartile Range = Q3 − Q1) mesure la largeur des 50% centraux des données. Normalisé par la médiane, il devient un ratio adimensionnel comparable entre métriques d'échelles différentes.

**Score stabilité** $s \in [0, 1]$ (0 = parfaitement stable, 1 = très instable) :

$$s = \text{clamp}\left(\frac{\text{IQR}/\text{médiane} - R_{\text{bon}}}{R_{\text{mauvais}} - R_{\text{bon}}},\ 0,\ 1\right)$$

#### Pourquoi l'IQR et pas le coefficient de variation (CV) ?

Le CV ($\sigma / \bar{x}$) est **extrêmement sensible aux outliers** car l'écart-type dépend du carré des écarts. En pratique, un seul point aberrant (ex : un speedtest à 38 Mb/s sur 4275 mesures à ~940 Mb/s) peut faire exploser σ et donc le CV, donnant un faux diagnostic d'instabilité.

Exemple réel sur 30 jours de Download :

| Métrique            | CV (σ/μ)                                | IQR/médiane                  |
| ------------------- | --------------------------------------- | ---------------------------- |
| Download (4275 pts) | **34.3%** ❌ (σ=276 à cause d'outliers) | **2.7%** ✅ (Q1=920, Q3=945) |
| Upload (4275 pts)   | ~15%                                    | **~25%** (Q1≈550, Q3≈720)    |

L'IQR est un estimateur **robuste** de la dispersion : il ignore les 25% les plus bas et les 25% les plus hauts, ne gardant que la masse centrale. C'est le concept d'[intervalle de confiance](https://fr.wikipedia.org/wiki/Intervalle_de_confiance) appliqué aux quartiles.

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

### Stabilité (IQR normalisé)

| Seuil            | IQR/médiane  | Signification                                |
| ---------------- | ------------ | -------------------------------------------- |
| Vert (parfait)   | ≤ 0.05 (5%)  | 50% centraux concentrés (très régulier)      |
| Rouge (instable) | ≥ 0.30 (30%) | 50% centraux dispersés (connexion erratique) |

Ces seuils sont **universels** et indépendants de la métrique. Un IQR/médiane de 5% signifie que les 50% centraux des mesures tiennent dans ±2.5% de la médiane.

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

### Quartiles et écart interquartile (IQR)

Les **quartiles** divisent un jeu de données trié en 4 parts égales :

- **Q1** (25e percentile) : 25% des données sont inférieures
- **Q2** (médiane) : 50%
- **Q3** (75e percentile) : 75% des données sont inférieures

L'**écart interquartile (IQR)** mesure la dispersion des 50% centraux :

$$IQR = Q3 - Q1$$

C'est un estimateur **robuste** : contrairement à l'écart-type, il est insensible aux outliers car il ignore les 25% extrêmes de chaque côté.

Référence : [Wikipedia — Interquartile range](https://en.wikipedia.org/wiki/%C3%89cart_interquartile)

### IQR normalisé (Quartile Coefficient of Dispersion)

Pour comparer la dispersion entre métriques d'échelles différentes (Mb/s vs ms), on normalise l'IQR par la médiane :

$$\text{IQR normalisé} = \frac{Q3 - Q1}{\text{médiane}}$$

C'est l'analogue robuste du coefficient de variation (CV = σ/μ), parfois appelé **Quartile Coefficient of Dispersion** dans la littérature.

Référence : [Wikipedia — Quartile coefficient of dispersion](https://en.wikipedia.org/wiki/Quartile_coefficient_of_dispersion)

### Intervalle de confiance et robustesse

L'IQR correspond à l'**intervalle de confiance à 50%** de la distribution empirique : il contient la moitié des observations centrales. Cette approche est directement liée au concept d'[intervalle de confiance](https://fr.wikipedia.org/wiki/Intervalle_de_confiance).

En statistique robuste, on privilégie les estimateurs basés sur les quantiles (médiane, IQR) plutôt que sur les moments (moyenne, écart-type) dès que la distribution peut contenir des outliers — ce qui est systématiquement le cas des mesures réseau (coupures, congestion temporaire, erreurs de mesure).

Référence : [Wikipedia — Robust statistics](https://en.wikipedia.org/wiki/Robust_statistics)

### Pourquoi pas le CV (σ/μ) ? — Leçon apprise

Le coefficient de variation a été utilisé dans la v1 mais s'est avéré inadapté :

$$CV = \frac{\sigma}{\bar{x}}$$

L'écart-type $\sigma$ dépend du **carré** des écarts à la moyenne. Un seul outlier (ex : 38 Mb/s sur 4275 mesures à ~940 Mb/s) contribue $(940-38)^2 = 813\,604$ à la variance, gonflant σ de 5.6 à 276 Mb/s et le CV de 0.6% à 34%. Le diagnostic passait de "Excellent" à "Dégradé" à cause d'un seul point.

L'IQR, ne regardant que Q1-Q3, est totalement insensible à ce type d'aberration.

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
  IQR/méd = 2.7% (Q1=920.3, Q3=945.1, IQR=24.8 Mb/s)
  vert ≤ 5%, rouge ≥ 30%
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

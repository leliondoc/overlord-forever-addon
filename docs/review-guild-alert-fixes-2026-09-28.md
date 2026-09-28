# Contre-vérification des corrections d'alerte de guilde

Revue en lecture seule de l'état local du 28 septembre 2026, après les corrections
Claude. Les constats précédents ne doivent pas être lus comme tous encore présents.

## Corrections confirmées

- Les observations des deux factions alimentent désormais la détection ; seuls
  les ennemis voient la notification. Un raid Horde authentifié peut maintenant
  déclencher un GW depuis un client Horde. Les propres kills du client ont aussi
  un hook dans `BroadcastKill`.
- Les guildes sont distinguées par faction et nom.
- La référence de compteur est liée à la semaine de score. Le blocage des nouveaux
  petits totaux après reset est corrigé.
- Une référence de plus de cinq minutes n'alimente plus un delta récent, et les
  doublons ne prolongent plus sa durée de vie.
- L'option est revérifiée avant l'envoi différé.
- Le tag de guilde absent ne reprend plus automatiquement le cache du classement.
- La simulation restaure exactement le réglage, y compris `nil`.

Les événements réels observés dans les cinq dernières minutes et le délai
anti-spam peuvent légitimement traverser une frontière hebdomadaire. Leur seule
conservation au reset n'est pas un défaut : c'est le total de score de référence
qui doit changer de semaine.

## Points encore ouverts

### P2 — Un faux GW peut toujours supprimer la production d'une vraie alerte

`GuildKillAlert.lua`, branche `if faction == myFaction` dans
`OnReceiveNetworkAlert`, écrit `guild.detectedAt = now` sans observation de kills.
La liste de transports autorisés bloque un WHISPER brut, mais ne valide pas
l'annonce reçue par CHANNEL ou par relais.

Reproduction par les vrais `Sync:OnAddonMessage` et `Sync:OnReceiveKill` :

1. Cinq auteurs Horde authentifiés, totaux 1 puis 4, produisent normalement un GW.
2. Après remise à zéro, un auteur inconnu envoie un GW Horde par CHANNEL.
3. Les mêmes vingt kills réels ne planifient plus aucun GW pendant le cooldown.

Un faux GW Alliance reçu par ce même chemin affiche également une fausse alerte
chez le client Horde. Claude mentionne cette possibilité dans son bilan ; le
contre-exemple supplémentaire est la suppression du détecteur de la faction
productrice, malgré la protection du détecteur ennemi.

Ne pas laisser une annonce distante non corroborée changer le compteur ou le
cooldown de détection locale. Contrôler le transport ne prouve pas les kills.

### P2 — Changer de guilde peut attribuer les anciens kills à la nouvelle

`OnLiveKill` abandonne les K sans guilde avant de mettre à jour la référence du
total. Cette référence ne contient pas non plus l'identité de guilde.

Reproduction pour cinq joueurs : guilde A au total 1, sans guilde au total 4,
puis guilde B au total 5. Le détecteur crédite quatre kills chacun à B et annonce
vingt kills, alors qu'un seul kill par joueur est intervenu chez B.

Garder la référence du total à jour pour tous les K authentifiés et réinitialiser
le delta attribuable lorsqu'une appartenance change.

### P2 — L'objectif flottant reste inchangé

`ZoneIndicator.lua:661` bloque toujours le rafraîchissement périodique pour une
cible `available`. Un autre objectif devenu plus proche n'est pas resélectionné.
Ce constat concerne l'état du dépôt ; il n'attribue pas l'origine du code à Claude.

### Limite secondaire — Le cooldown après reload ne couvre pas un deuxième GW

La clé persistante contient le timestamp exact du GW. Elle bloque la copie exacte,
mais la même guilde avec un timestamp T+1 peut être affichée juste après `/reload`.
Le test actuel couvre seulement le même timestamp. Pour conserver dix minutes
d'anti-spam après reload, persister aussi le dernier affichage par faction/guilde.

## Validation

**46 fichiers de tests Lua réussissent sur 47.** Le seul échec se trouve à
`tests/forever_guild_kill_alert.test.lua:296` : une recherche littérale dans
`Sync.lua` dépend de l'indentation et des fins de ligne. Le vrai dispatcher passe
bien `sender, channel`. Remplacer cette assertion par une vérification à
l'exécution évitera un blocage de CI sans cause fonctionnelle.

Les reproductions supplémentaires ci-dessus passent et confirment les défauts.
Aucun code de production n'a été modifié pendant cette contre-vérification.

## Adéquation au besoin : une guilde ennemie dangereuse à un endroit

Le chemin observation locale → pont Battle.net → notification de la faction
ennemie est adapté. Deux propriétés supplémentaires sont nécessaires :

- Agréger par guilde, faction et lieu, puis par shard lorsqu'il est connu. Le code
  actuel cumule toute la guilde et choisit ensuite le lieu le plus fréquent ; il
  peut donc présenter comme un raid local des activités dispersées.
- Distinguer activité PvP et victimes uniques. Les K transportent les crédits
  individuels de victoires honorables, pas les identifiants des victimes. Leur
  somme ne permet pas d'annoncer un nombre de personnes distinctes tuées.

Un GW produit par un addon reste une déclaration d'un client. Les contrôles de
source, de fraîcheur, de lieu et la corroboration par des sources indépendantes
réduisent les faux signalements ; ils ne fournissent pas une preuve serveur des
combats. Des noms de joueurs ajoutés au payload ne constituent pas une preuve.
Le module doit préserver les observations locales même quand un GW distant arrive.

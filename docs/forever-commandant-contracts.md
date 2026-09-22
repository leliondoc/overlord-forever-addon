# Commandant et Contrats sur Forever

Portage des modules de l'installation Retail Overlord 9.9.39, le 22 septembre
2026. Les modules sont chargés par le TOC et initialisés par les étapes de login,
avec préparation du registre des contrats et du registre COD avant Sync.

## Adaptations

- Commandant : suppression du prérequis de communauté à la prise et à la
  restauration du rôle. Les contrôles de chef de groupe, front, faction,
  campagne, mort et libération restent actifs.
- Réception Commandant : les paquets relayés conservent l'auteur initial et
  utilisent le contexte validé de BetaNetwork à la place du roster de communauté.
  Comme pour les autres données beta, les auteurs précédents sont attestés par
  le bridge, sans authentification cryptographique de bout en bout.
- Contrats : identité complète `Prénom Nom` au lieu de `Joueur-Royaume`.
  La région et la campagne sont validées par le protocole. Aucun royaume fictif
  n'est ajouté et aucun prénom seul n'est accepté comme preuve de victime.
- Relais : GE/GP/GX/GD/GM et BQ/BR/PB/PK/MK/PX/PP/PM autorisés dans les enveloppes
  BetaNetwork. Le BR de requête de contrat reste distinct du BR extérieur de
  transport Battle.net. Une file de relais pleine ne consomme pas immédiatement
  les réponses ciblées des contrats ; les réessais restent bornés à deux minutes.
- Cartes, minimap, nameplates et panneau Contrats : modules Retail réutilisés
  avec les points d'entrée déjà présents dans l'interface Forever.

## Vérification de l'API

Les sources Blizzard extraites de la branche **forever**, et non de la branche
`classic_beta`, ont été consultées :

- [MailFrame.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_MailFrame/MailFrame.lua)
  utilise `GetSendMailItem`, `GetInboxHeaderInfo`, `SetSendMailMoney`,
  `SetSendMailCOD`, `MoneyInputFrame_GetCopper`, `SendMailRadioButton_OnClick`,
  les champs `SendMailNameEditBox`/`SendMailMoney` et `MAIL_SEND_SUCCESS`.
- [UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua),
  [MapDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/MapDocumentation.lua)
  et [NamePlateDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/NamePlateDocumentation.lua)
  fournissent les familles d'API utilisées par le rôle et ses marqueurs.

La préparation du paiement vérifie également la présence des API et champs de
courrier sur le client en cours. L'addon ne déclenche pas `SendMail` : le joueur
vérifie le destinataire complet et valide l'envoi dans l'interface Blizzard.
Le paiement direct n'est enregistré qu'après l'événement de succès.

## Tests et limites

Tests Lua 5.1 : cycle de Commandant, réception GE/GX/PB via Battle.net,
transmission de toutes les nouvelles familles sur trois relais, conservation
de l'auteur, preuves PK/MK dans les deux ordres, refus des fausses preuves,
COD/paiement direct, doublons, reset de campagne et recharge des contrats.
Le test de courrier contrôle le destinataire complet, le montant, l'absence
d'envoi automatique et le refus quand l'API nécessaire manque.

Ces tests simulent le client ; ils ne prouvent pas la distribution d'or par le
serveur. Des joueurs ont signalé un routage de courrier incorrect entre noms
partageant le même prénom dans la bêta :
[signalement du 20 septembre](https://us.forums.blizzard.com/en/wow/t/bad-email-bug/2355953).
Ce défaut serveur ne peut pas être corrigé par l'addon. La validation réelle
reste à faire avec deux personnages aux noms complets distincts : contrat,
kill, preuve reçue, approbation, courrier manuel et réception effective.

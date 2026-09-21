# Audit Forever — 21 septembre 2026

Référence comparée : installation locale Overlord Retail 9.9.39, ainsi que le
commit initial du port Forever 1.0.0. L'installation Retail n'a pas été modifiée.

## Cause des captures perdues

La sauvegarde du compte contient bien la capture Alliance de la Vallée des Rois.
Une sauvegarde de secours contient également les annonces déjà vues. Le client
bêta peut écrire ces données sans les recharger :
[reproduction sur le forum Blizzard](https://eu.forums.blizzard.com/en/wow/t/addon-savedvariables-never-load-on-160169893/629799).

Le script `tools/Repair-ForeverSavedVariables.ps1` installe un pont local vers le
fichier courant, chargé après les modules de l'addon. Il préserve les fichiers
WTF et copie les sauvegardes dans `_local`. Une jonction de dossier permet de
suivre les remplacements du fichier par WoW ; une copie fixe ne le permettrait pas.

## Nettoyage effectué

- Suppression de l'attente arbitraire de 30 secondes et du blocage des annonces
  sur les installations neuves.
- Suppression de la réapplication des anciennes captures depuis l'affichage de
  la carte et depuis la sauvegarde : elle pouvait annuler une attaque, une
  neutralisation ou un reset légitime.
- Suppression des contournements de reset et des attestations de campagne
  artificielles ; conservation des règles de campagne et de convergence Retail.
- Suppression du second cache d'affichage des captures et des lectures de
  drapeaux de pop-up dans des chaînes sans format défini.
- Suppression des catalogues de royaumes, recherches de royaumes connectés et
  migrations de reclassement FR/DE devenues inactives.
- Région courante NA/EU déterminée par l'API, avec repli sur la session précédente
  seulement si nécessaire. Aucun royaume ni langue ne détermine une région.
- Validation des whispers corrigée pour les noms accentués et cyrilliques.

Conservés : identités « Prénom Nom », compatibilité des anciens tags FR/DE vers
EU, séparation NA/EU, cartes et fronts Forever, adaptations des fortins et
avant-postes, interface des modules disponibles, Hall of Fame des donateurs,
annonces Forever et corrections de domination en solo.

## Validation et publication

Retour en jeu : les annonces restent vues après `/reload` et la capture de la
Vallée des Rois est conservée en passant au guerrier. Un second problème a été
isolé dans le classement : un premier bucket vide sans `campaignStart` n'était
pas attesté avant les premières captures. Le retour au garde-fou Retail lors
du nettoyage supprimait ensuite ces scores sans preuve de campagne au login.
L'initialisation publie maintenant le bucket vide avant son attestation, sans
fabriquer de reset ni accepter des scores anciens non vérifiés. Un test exécute
la capture physique, la sauvegarde, le login d'un autre personnage et la lecture
du classement. La récupération du point déjà supprimé utilise la sauvegarde
locale conservée ; elle reste dans `_local`, hors du paquet public.

- Les 37 fichiers de production passent l'analyse syntaxique Lua 5.1.
- Les tests exécutent les modules réels : capture entre personnages, pop-up
  one-shot, attaque, neutralisation, expiration et vrai reset hebdomadaire,
  identités et séparation régionale.
- Les tests Windows vérifient la rotation du fichier, l'ordre de chargement,
  la réinstallation, la désactivation et la sélection du compte.
- La suite de capture existante et les 12 contrôles Node passent.
- Le pipeline public retire le bloc TOC local et exclut `_local` des archives.

La bêta nécessite encore le contournement chez les utilisateurs affectés.
Avant publication, vérifier en jeu une capture, `/reload`, un autre personnage
et un redémarrage complet, puis la synchronisation entre deux joueurs.
La compatibilité du client final devra être validée à sa disponibilité, avec
son numéro d'interface. Le fonctionnement natif des SavedVariables reste en place.

# pandaConquest

pandaConquest est un addon pour le client OctoWoW (1.12.1, Lua 5.0), consacré aux achievements communautaires PvE.

L'objectif est de permettre à chaque joueur de débloquer des achievements personnalisés, suivre sa progression, consulter celle des autres utilisateurs et participer à des classements par personnage ou campagne. L'addon doit fonctionner localement sans service externe. Le partage P2P en jeu et une synchronisation cloud facultative pourront compléter ce fonctionnement lorsque leurs contraintes auront été validées.

## État actuel

Le projet est en **phase 0 : validation du runtime** sur OctoWoW. Un socle expérimental chargeable est présent avec une SavedVariable bornée, des captures brutes de `CHAT_MSG_ADDON` et `CHAT_MSG_CHANNEL`, et les commandes `/pc p2p`. Le code respecte Lua 5.0 et les limites documentées du client 1.12.1 :

- messages d'addon bornés à 255 octets préfixe compris, sur PARTY, RAID, GUILD et BATTLEGROUND seulement ;
- canal hors groupe `PandaConquest` rejoint automatiquement, avec envoi sans action utilisateur via `SendChatMessage` et trafic masqué des fenêtres de discussion (`/pc p2p channelshow` pour l'afficher) ;
- enveloppe complète du canal bornée à 255 octets ;
- détection exacte de la monture et du camouflage avec les DLL nampower ou VanillaHelpers d'OctoWoW, avec repli sur les icônes de buffs.

Aucune campagne à deux clients n'a encore été menée sur OctoWoW : transports, portée du canal entre zones et entre factions, débit, reconnexion et fragmentation restent à mesurer. L'état et la procédure se trouvent dans [Tests P2P](docs/p2p-testing.md#état-de-référence-pour-octowow).

Le leaderboard complet, le protocole distribué avancé et l'application compagnon ne doivent pas être développés avant ces validations.

Un premier socle cartographique est également disponible : les POI peuvent être enregistrés comme points ou groupes de coordonnées, puis rendus en zones grises (neutres), rouges (Horde), bleues (Alliance), jaunes (ressources) ou avec une couleur RGB personnalisée, avec l'icône de leur type au centre. Le contrat est décrit dans [POI et zones sur la carte](docs/map-pois.md).

## Principes essentiels

- Le MVP concerne le PvE, pas le contrôle territorial ni le PvP, sauf une exception : la capture des avant-postes `OUTPOST` ([conception](docs/capture.md), décision 0012).
- Chaque personnage est une identité distincte : `personnage@royaume`.
- Le fonctionnement hors ligne est obligatoire.
- L'application compagnon et le cloud Cloudflare restent facultatifs ([décision 0030](docs/decisions/0030-cloudflare-cloud-baseline.md)).
- Les premières progressions sont monotones : booléen, compteur croissant ou palier.
- Les données P2P ou cloud ne constituent pas une preuve du serveur.
- Les capacités réseau ne doivent pas être supposées avant un test reproductible avec deux clients.

## Installation

Le dossier `pandaConquest` doit être placé dans :

```text
C:\Games\Wow-Octo\Interface\AddOns\pandaConquest
```

### Prérequis : nampower pour les terrains de chasse

La capture des terrains de chasse (`HUNTING_GROUNDS`, [décision 0026](docs/decisions/0026-hunting-grounds-capture.md)) **exige nampower**. Seul son événement `UNIT_DIED` fournit l'identifiant des créatures tuées ; le client 1.12 standard ne le donne pas, et aucun repli n'existe.

- Lancer le jeu avec **le lanceur Octo**, qui charge les DLL nampower, VanillaHelpers et UnitXP_SP3. Un lancement direct de `WoW.exe` ne les charge pas.
- Sans nampower, les victimes ne sont pas comptées et le HUD du terrain affiche « nampower not detected: launch the game with the Octo launcher ».
- Vérification en jeu : `/pc hunt` doit lister des fonctions nampower (`GetNampowerVersion`, `GetUnitGUID`, `GetUnitField`) et son compteur `deaths=` augmente quand une créature meurt à proximité.
- Les avant-postes (`OUTPOST`) et les achievements n'en dépendent pas : nampower ne rend que la détection exacte de la monture et du camouflage plus précise, avec repli sur les icônes de buffs.

Le client attendu utilise l'interface `11200`. Après installation ou modification, activer l'addon puis faire `/reload` ; un **nouveau fichier Lua** ajouté au `.toc` n'est chargé qu'après un redémarrage complet du client. Les commandes de départ sont :

```text
/pc p2p status
/pc p2p hello PARTY
/pc p2p ping PARTY
/pc p2p channelsend TEST-P2P
/pc p2p log
/pc map
```

Un appel d'envoi accepté ou un événement enregistré sans erreur ne prouve pas la livraison. La validation exige deux clients et la procédure de [tests P2P](docs/p2p-testing.md).

## Documentation

- [Vision](docs/vision.md)
- [Architecture](docs/architecture.md)
- [Modèle de données](docs/data-model.md)
- [Achievements](docs/achievements.md)
- [POI et zones sur la carte](docs/map-pois.md)
- [Capture des POI](docs/capture.md)
- [Protocole P2P](docs/p2p-protocol.md)
- [Tests P2P](docs/p2p-testing.md)
- [Sécurité](docs/security.md)
- [Application compagnon](docs/companion.md)
- [Feuille de route](docs/roadmap.md)
- [Décisions d'architecture](docs/decisions/README.md)
- [Journal des modifications](CHANGELOG.md)

## Travail assisté par agent

Les agents doivent commencer par [AGENTS.md](AGENTS.md), qui renvoie vers [CLAUDE.md](CLAUDE.md). Les recherches dans le projet passent par l'index autonome situé dans `C:\Games\Wow-Octo\#Addons-dev\diagnostics\pandaconquest-index`.

Après toute modification de l'addon, documentation comprise :

```powershell
python -B "C:\Games\Wow-Octo\#Addons-dev\diagnostics\pandaconquest-index\pandaconquest_index.py" build
python -B "C:\Games\Wow-Octo\#Addons-dev\diagnostics\pandaconquest-index\pandaconquest_index.py" status
```

`status` doit renvoyer le code de sortie 0 (`[UP_TO_DATE]`). Les vérifications Lua 5.0 à lancer avant sont décrites dans [CLAUDE.md](CLAUDE.md).

Overlord est une référence d'architecture distribuée, pas une base à porter littéralement. Son index se trouve dans `C:\Games\Wow-Octo\#Addons-dev\diagnostics\overlord-index`.
